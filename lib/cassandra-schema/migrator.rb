require_relative "migration"

module CassandraSchema
  class Migrator
    attr_reader :connection, :current_version, :options

    DEFAULT_OPTIONS = {
      lock:          true,
      lock_timeout:  30,
      lock_retry:    [],
      query_timeout: 30,
      query_delay:   0,
    }

    def initialize(connection:, migrations:, logger: Logger.new(STDOUT), options: {})
      @connection = connection
      @logger     = logger
      @migrations = migrations
      @options    = DEFAULT_OPTIONS.merge(options)

      generate_migrator_schema!
    end

    def migrate(target = nil)
      lock_retry = @options.fetch(:lock_retry).dup

      begin
        raise if @options.fetch(:lock) && !lock_schema
      rescue
        if wait = lock_retry.shift
          @logger.info "Schema is locked; retrying in #{wait} seconds"
          sleep wait
          retry
        end

        @logger.info "Can't run migrations. Schema is locked."
        return
      end

      @current_version = get_current_version

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
            renew_lock if @options.fetch(:lock)
          end
        else
          # includes current version's :down
          # excludes target version's :down
          current_version.downto(target + 1) do |version|
            migrate_to(version, :down)
            renew_lock if @options.fetch(:lock)
          end
        end

        @logger.info "Current version: #{current_version}"
        @logger.info "Done!"
      rescue => ex
        @logger.error ex.message if ex.message && !ex.message.empty?
        @logger.info "Failed migrating all files. Current schema version: #{@current_version}"
      ensure
        unlock_schema if @options.fetch(:lock)
      end
    end

    private

    def generate_migrator_schema!
      @connection.execute(
        <<~CQL,
          CREATE TABLE IF NOT EXISTS schema_information (
            name VARCHAR,
            value VARCHAR,
            PRIMARY KEY (name)
          );
        CQL
        consistency: :quorum
      )

      @connection.execute(
        <<~CQL,
          INSERT INTO schema_information(name, value)
          VALUES('version', '0')
          IF NOT EXISTS
        CQL
        consistency: :quorum
      )
    end

    def get_current_version
      result = @connection.execute(
        <<~CQL,
          SELECT value FROM schema_information WHERE name = 'version'
        CQL
        consistency: :quorum
      )

      unless result.rows.any?
        @logger.info "Can't load current schema version."
        fail
      end

      result.rows.first["value"].to_i
    end

    def update_version(target)
      @connection.execute(
        <<~CQL,
          UPDATE schema_information SET value = ? WHERE name = 'version'
        CQL
        arguments: [target.to_s],
        consistency: :quorum
      )

      @current_version = target
    end

    def lock_schema
      result = @connection.execute(
        <<~CQL,
          INSERT INTO schema_information(name, value)
          VALUES('lock', '1')
          IF NOT EXISTS
          USING TTL #{@options.fetch(:lock_timeout)}
        CQL
        consistency: :quorum
      )

      result.rows.first.fetch("[applied]")
    end

    def renew_lock
      @connection.execute(
        <<~CQL,
          UPDATE schema_information
          USING TTL #{@options.fetch(:lock_timeout)}
          SET value = '1'
          WHERE name = 'lock'
        CQL
        consistency: :quorum
      )
    end

    def unlock_schema
      @connection.execute(
        <<~CQL,
          DELETE FROM schema_information WHERE name = 'lock' IF EXISTS;
        CQL
        consistency: :quorum
      )
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
        unless execute_command(command, timeout: @options.fetch(:query_timeout))
          message = "Failed migrating to version #{target}."

          if index > 0
            message += " Recovering..."

            #recover
            recover_commands = @migrations
              .fetch(target)
              .commands
              .fetch(direction == :up ? :down : :up)
              .last(index)

            results = recover_commands.map { |cmd|
              execute_command(cmd, timeout: @options.fetch(:query_timeout))
            }

            message += results.all? ? "Ok." : "Failed."
          end

          @logger.info message

          fail
        end

        index += 1
      end

      update_version(new_version)
    end

    def execute_command(command, options)
      query_delay = @options.fetch(:query_delay)

      begin
        @connection.execute command, options

        # There is a Cassandra bug, where schema changes executed in quick succession
        # can result in internal corruption:
        #
        # https://stackoverflow.com/questions/29030661/creating-new-table-with-cqlsh-on-existing-keyspace-column-family-id-mismatch#answer
        # https://issues.apache.org/jira/browse/CASSANDRA-5025
        delay(query_delay / 1000.0) if query_delay > 0

        true
      rescue => ex
        @logger.error ex.message
        false
      end
    end

    private def delay(delay_time)
      sleep(delay_time)
    end
  end
end
