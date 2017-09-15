require_relative "migration"

module CassandraSchema
  class Migrator
    attr_reader :connection, :current_version

    def initialize(connection:, migrations:, logger: Logger.new(STDOUT))
      @connection = connection
      @logger     = logger
      @migrations = migrations

      generate_migrator_schema!

      @current_version = get_current_version || init_versioning
    end

    def migrate(target = nil)
      target ||= @migrations.keys.max || 0

      @logger.info "Running migrations..."

      if target == current_version || @migrations.empty?
        @logger.info "Nothing to migrate."
        return
      end

      begin
        if target > current_version
          # excludes current version's up
          (current_version + 1).upto(target) do |next_version|
            migrate_to(next_version, :up)
          end
        else
          # includes current version's :down
          # excludes target version's :down
          current_version.downto(target + 1) do |version|
            migrate_to(version, :down)
          end
        end

        @logger.info "Current version: #{current_version}"
        @logger.info "Done!"
      rescue => ex
        @logger.info "Failed migrating all files. Current schema version: #{@current_version}"
      end
    end

    private

    def generate_migrator_schema!
      result = @connection.execute <<~CQL
        CREATE TABLE IF NOT EXISTS schema_information (
          name VARCHAR,
          value VARCHAR,
          PRIMARY KEY (name)
        );
      CQL
    end

    def get_current_version
      result = @connection.execute <<~CQL
        SELECT value FROM schema_information WHERE name = 'version'
      CQL

      result.rows.any? && result.rows.first["value"].to_i
    end

    def init_versioning
      @connection.execute <<~CQL
        INSERT INTO schema_information(name, value) VALUES('version', '0')
      CQL

      0
    end

    def update_version(target)
      @connection.execute(
        <<~CQL,
          UPDATE schema_information SET value = ? WHERE name = 'version'
        CQL
        arguments: [target.to_s]
      )

      @current_version = target
    end

    def migrate_to(target, direction)
      new_version = direction == :up ? target : target - 1
      @logger.info "Migrating to version #{new_version}"

      unless @migrations[target]
        @logger.info "Missing migration with version #{target}"
        fail
      end

      # Get commands list
      commands = @migrations.fetch(target).commands.fetch(direction)
      index    = 0

      commands.each do |command|
        unless execute_command(command)
          message = "Failed migrating to version #{target}."

          if index > 0
            message += " Recovering..."

            #recover
            recover_commands = @migrations
              .fetch(target)
              .commands
              .fetch(direction == :up ? :down : :up)
              .last(index)

            results = recover_commands.map { |cmd| execute_command(cmd) }

            message += results.all? ? "Ok." : "Failed."
          end

          @logger.info message

          fail
        end

        index += 1
      end

      update_version(new_version)
    end

    def execute_command(command)
      begin
        @connection.execute command
        true
      rescue => ex
        @logger.error ex.message
        false
      end
    end

  end
end
