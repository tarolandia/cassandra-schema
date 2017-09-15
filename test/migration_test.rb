require "minitest/autorun"

require_relative "../lib/cassandra-schema/migration"

describe "CassandraSchema::Migration" do
  before do
    @migration = CassandraSchema::Migration.new
  end

  it "returns empty commands hash" do
    assert_equal(
      {
        up:   [],
        down: [],
      },
      @migration.commands
    )
  end

  it "sets :up commands" do
    commands = ["CQL command 1", "CQL command 2"]
    @migration.set_commands(:up, commands)

    assert_equal commands, @migration.commands.fetch(:up)
  end

  it "sets :down commands" do
    commands = ["CQL command 1", "CQL command 2"]
    @migration.set_commands(:down, commands)

    assert_equal commands, @migration.commands.fetch(:down)
  end
end
