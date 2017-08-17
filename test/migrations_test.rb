require "minitest/autorun"

require_relative "../lib/cassandra_schema/migration"

describe "CassandraSchema" do
  before do
    CassandraSchema.reset_migrations!

    CassandraSchema.migration(1) do; end
    CassandraSchema.migration(2) do; end
  end

  it "registers migrations" do
    assert_equal 2, CassandraSchema.migrations.size

    CassandraSchema.migrations.each_with_index do |(version, migration), index|
      assert_equal index + 1, version
      assert_instance_of CassandraSchema::Migration, migration
    end
  end

  it "resets migrations" do
    CassandraSchema.reset_migrations!

    assert_equal 0, CassandraSchema.migrations.size
  end

  it "fails adding migration with the same version number" do
    assert_raises(RuntimeError, "Migration version 2 is already registered") do
      CassandraSchema.migration(2) do; end
    end
  end

  describe "DSL" do
    it "generates migration with up and down commands" do
      CassandraSchema.migration(3) do
        up do
          execute "CQL command 1"
          execute "CQL command 2"
        end

        down do
          execute "CQL revert command 2"
          execute "CQL revert command 1"
        end
      end

      migration = CassandraSchema.migrations[3]

      assert migration
      assert_equal(
        {
          up:   ["CQL command 1", "CQL command 2"],
          down: ["CQL revert command 2", "CQL revert command 1"],
        },
        migration.commands
      )
    end
  end
end
