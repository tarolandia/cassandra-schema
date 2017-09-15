require "minitest/autorun"

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
        execute "ALTER TABLE table_by_name DROP alt_email"
        execute "ALTER TABLE table_by_name DROP email"
      end
    end

    @fake_logger = FakeLogger.new
  end

  it "initializes schema_information table if not exists" do
    migrator = CassandraSchema::Migrator.new(
      connection: CONN,
      migrations: {},
      logger: @fake_logger,
    )

    assert_equal 0, migrator.current_version
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
      @migrator.migrate(1)
      assert_equal 1, @migrator.current_version
    end
  end
end
