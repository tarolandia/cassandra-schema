require "minitest/autorun"
require "mocha/setup"

require_relative "support/connections"
require_relative "../lib/cassandra-schema/migrator"

class FakeLogger
  attr_reader :stdout

  def initialize
    @stdout = []
  end

  def info(value)
    @stdout << value
  end

  def error(value)
    @stdout << value
  end
end

CONN = Connections::Cassandra.create_with_retries
CONN.execute <<~CQL
  CREATE KEYSPACE IF NOT EXISTS cassandra_schema_migrator
  WITH REPLICATION = { 'class' : 'SimpleStrategy', 'replication_factor' : 1 };
CQL

CONN.execute "USE cassandra_schema_migrator"

describe "CassandraSchema::Migrator" do
  before do
    CONN.execute "DROP TABLE IF EXISTS schema_information"
    CONN.execute "DROP MATERIALIZED VIEW IF EXISTS table_by_description"
    CONN.execute "DROP TABLE IF EXISTS table_by_name"

    CassandraSchema.reset_migrations!

    CassandraSchema.migration(1) do
      up do
        execute <<~CQL
          CREATE TABLE table_by_name (
            id uuid,
            name text,
            description text,
            PRIMARY KEY (id, name)
          ) WITH CLUSTERING ORDER BY (name ASC)
        CQL

        execute <<~CQL
          CREATE MATERIALIZED VIEW table_by_description AS
            SELECT
              id,
              name,
              description
            FROM table_by_name
            WHERE id IS NOT NULL
              AND name IS NOT NULL
              AND description IS NOT NULL
            PRIMARY KEY (id, description, name)
            WITH CLUSTERING ORDER BY (description ASC, name ASC)
        CQL
      end

      down do
        execute "DROP MATERIALIZED VIEW table_by_description"
        execute "DROP TABLE table_by_name"
      end
    end

    CassandraSchema.migration(2) do
      up do
        execute "ALTER TABLE table_by_name ADD email text"
        execute "ALTER TABLE table_by_name ADD alt_email text"
      end

      down do
        execute "DROP MATERIALIZED VIEW table_by_description"

        execute "ALTER TABLE table_by_name DROP alt_email"
        execute "ALTER TABLE table_by_name DROP email"

        execute <<~CQL
          CREATE MATERIALIZED VIEW table_by_description AS
            SELECT
              id,
              name,
              description
            FROM table_by_name
            WHERE id IS NOT NULL
              AND name IS NOT NULL
              AND description IS NOT NULL
            PRIMARY KEY (id, description, name)
            WITH CLUSTERING ORDER BY (description ASC, name ASC)
        CQL
      end
    end

    @fake_logger = FakeLogger.new
  end

  it "initializes schema_information table if not exists" do
    CassandraSchema::Migrator.new(
      connection: CONN,
      migrations: {},
      logger: @fake_logger,
    )

    result = CONN.execute "SELECT value FROM schema_information WHERE name = 'version'"

    assert result.rows.first.fetch("value")
  end

  describe "migrating up" do
    it "migrates to last version" do
      migrator = CassandraSchema::Migrator.new(
        connection: CONN,
        migrations: CassandraSchema.migrations,
        logger: @fake_logger,
      )

      migrator.migrate

      assert_equal 2, migrator.current_version
    end

    it "migrates to target version" do
      migrator = CassandraSchema::Migrator.new(
        connection: CONN,
        migrations: CassandraSchema.migrations,
        logger: @fake_logger,
      )

      migrator.migrate(1)

      assert_equal 1, migrator.current_version
    end

    it "fails if there is a missing version" do
      CassandraSchema.migration(4) do
        up do
          execute "ALTER TABLE users DROP email"
        end

        down do
          execute "ALTER TABLE users ADD email text"
        end
      end

      migrator = CassandraSchema::Migrator.new(
        connection: CONN,
        migrations: CassandraSchema.migrations,
        logger: @fake_logger,
      )

      migrator.migrate
      assert_equal "Failed migrating all files. Current schema version: 2", @fake_logger.stdout.pop
      assert_equal "Missing migration with version 3", @fake_logger.stdout.pop
    end

    it "fails if another migration is running" do
      migrator_a = CassandraSchema::Migrator.new(
        connection: CONN,
        migrations: CassandraSchema.migrations,
        logger: @fake_logger,
      )

      thr = Thread.new do
        migrator_a.migrate
      end

      logger_b   = FakeLogger.new
      migrator_b = CassandraSchema::Migrator.new(
        connection: CONN,
        migrations: CassandraSchema.migrations,
        logger: logger_b,
      )

      migrator_b.migrate

      assert_equal "Can't run migrations. Schema is locked.", logger_b.stdout.pop

      thr.join

      migrator_b.migrate

      assert_equal "Nothing to migrate.", logger_b.stdout.pop
    end

    it "retries if schema is locked" do
      migrator = CassandraSchema::Migrator.new(
        connection: CONN,
        migrations: CassandraSchema.migrations,
        logger:     @fake_logger,
        options:    { lock_retry: [1, 1, 2, 3] },
      )

      migrator.expects(:lock_schema).times(4).returns(false, false, false, true)

      migrator.migrate

      assert_equal "Schema is locked; retrying in 1 seconds", @fake_logger.stdout.shift
      assert_equal "Schema is locked; retrying in 1 seconds", @fake_logger.stdout.shift
      assert_equal "Schema is locked; retrying in 2 seconds", @fake_logger.stdout.shift
      assert_equal "Running migrations...", @fake_logger.stdout.shift

      assert_equal 2, migrator.current_version
    end

    it "fails if schema is locked after retring" do
      migrator = CassandraSchema::Migrator.new(
        connection: CONN,
        migrations: CassandraSchema.migrations,
        logger:     @fake_logger,
        options:    { lock_retry: [1, 1] },
      )

      migrator.expects(:lock_schema).times(3).returns(false, false, false)

      migrator.migrate

      assert_equal "Schema is locked; retrying in 1 seconds", @fake_logger.stdout.shift
      assert_equal "Schema is locked; retrying in 1 seconds", @fake_logger.stdout.shift
      assert_equal "Can't run migrations. Schema is locked.", @fake_logger.stdout.shift
    end

    it "runs commands with custom timeout" do
      migrator = CassandraSchema::Migrator.new(
        connection: CONN,
        migrations: CassandraSchema.migrations,
        logger:     @fake_logger,
        options:   { query_timeout: 45 },
      )

      migrator.expects(:execute_command).times(4).with(anything, { timeout: 45 }).returns(true)

      migrator.expects(:lock_schema).returns(true)
      migrator.expects(:get_current_version).returns(0)
      migrator.expects(:update_version).times(2)
      migrator.expects(:renew_lock).times(2)
      migrator.expects(:unlock_schema)

      migrator.migrate
    end

    it "runs commands with custom delay" do
      migrator = CassandraSchema::Migrator.new(
        connection: CONN,
        migrations: CassandraSchema.migrations,
        logger:     @fake_logger,
        options:    {
          query_delay: 500,
        },
      )

      migrator.expects(:delay).times(4).with(0.5)

      migrator.expects(:lock_schema).returns(true)
      migrator.expects(:get_current_version).returns(0)
      migrator.expects(:update_version).times(2)
      migrator.expects(:renew_lock).times(2)

      migrator.migrate
    end
  end

  describe "migrating down" do
    before do
      @migrator = CassandraSchema::Migrator.new(
        connection: CONN,
        migrations: CassandraSchema.migrations,
        logger: @fake_logger,
      )
      # Start on version 2
      @migrator.migrate
    end

    it "migrates to target version" do
      logger   = FakeLogger.new
      migrator = CassandraSchema::Migrator.new(
        connection: CONN,
        migrations: CassandraSchema.migrations,
        logger: logger,
      )
      migrator.migrate(1)

      assert_equal 1, migrator.current_version
    end
  end
end
