module CassandraSchema
  @@migrations = {}

  def self.migrations
    @@migrations
  end

  def self.reset_migrations!
    @@migrations = {}
  end

  def self.migration(version, &block)
    fail "Migration version #{version} is already registered" if @@migrations[version]

    @@migrations[version] = MigrationDSL.new(&block).migration
  end

  class MigrationDSL
    attr_reader :migration

    def initialize(&block)
      @migration = Migration.new
      instance_eval(&block)
    end

    def up(&block)
      @buffer = []
      @migration.set_commands(:up, block.call)
    end

    def down(&block)
      @buffer = []
      @migration.set_commands(:down, block.call)
    end

    def execute(command)
      @buffer << command
    end
  end

  class Migration
    def commands
      @commands ||= {
        up:   [],
        down: [],
      }
    end

    def set_commands(key, _commands)
      commands[key] = _commands
    end
  end
end
