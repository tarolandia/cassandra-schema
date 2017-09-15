require "cassandra"
require "lz4-ruby"

module Connections
  def self.create_with_retries(mod, *args)
    waits = [1, 1, 2, 3, 5, 8, 13, 21, 34, 55]
    begin
      Connections::Cassandra.create(*args)

    rescue *mod::CONNECTION_ERRORS
      wait = waits.shift
      fail "Gave up on connecting to #{mod}" if wait.nil?

      puts "Couldn't connect to #{mod}; retrying in #{wait} seconds"
      sleep wait
      retry
    end
  end

  module Cassandra
    DEFAULT_USERNAME    = ENV.fetch("CASSANDRA_USERNAME")
    DEFAULT_PASSWORD    = ENV.fetch("CASSANDRA_PASSWORD")
    DEFAULT_HOSTS       = ENV.fetch("CASSANDRA_HOSTS").strip.split(" ")
    DEFAULT_PORT        = ENV.fetch("CASSANDRA_PORT", "9042").to_i
    DEFAULT_COMPRESSION = :lz4

    CONNECTION_ERRORS = [::Cassandra::Errors::NoHostsAvailable]

    class << self
      attr_accessor :current
    end

    def self.create(options = {})
      options = {
        username:    DEFAULT_USERNAME,
        password:    DEFAULT_PASSWORD,
        hosts:       DEFAULT_HOSTS,
        port:        DEFAULT_PORT,
        compression: DEFAULT_COMPRESSION,
      }.merge(options)

      keyspace = options.delete(:keyspace)

      ::Cassandra.cluster(options).connect(keyspace)
    end

    def self.create_with_retries(*args)
      Connections.create_with_retries(self, *args)
    end
  end
end
