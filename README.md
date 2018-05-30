# Cassandra Schema [![CircleCI](https://circleci.com/gh/tarolandia/cassandra-schema/tree/master.svg?style=svg)](https://circleci.com/gh/tarolandia/cassandra-schema/tree/master)

Simple reversible schema migrations for cassandra.

## Changelog

### Version `0.4.0`

- Add `query_delay` option to configure sleep time between schema changes. Default `0`.
- Add `lock_retry` option to retry migration if schema is locked. Default `[]`

### Version `0.3.0`

- Add `query_timeout` option for running migration commands. Default 30 seconds.
- Log relevant exception message when running migrations

### Version `0.2.0`

- Refactor `schema_information` queries to use LWT and `:quorum` consistency level
- Implement a simple locking system to prevent concurrent migrations

## Usage

CassandraSchema uses a DSL via the `CassandraSchema.migration(version)` method. A migration must have an `up` block with the changes you want to apply to the schema, and a `down` block reversing the change made by `up`.

Use `execute` inside `up` and `down` to run the queries that will modify the schema.


Here is an example of a migration file:

```cql
require "cassandra-schema"

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
```

## Running Migrations

Once you defined your migrations, you can use `CassandraSchema::Migrator` to run them.

```ruby
require "cassandra-schema/migrator"

migrator = CassandraSchema::Migrator.new(
  connection: CONN, # any connection object implementing `execute` method
  migrations: CassandraSchema.migrations, # list of migrations
  logger: Logger.new, # any logger object implementing `info` and `error` methods
  options: {}, # additional configuration
)
```

Migrate to lastest version:

```ruby
migrator.migrate
```

Migrate to certain version:

```ruby
migrator.migrate(2)
```

CassandraSchema tracks which migrations you have already run.


### Options

name | default | description | example
---- | ------- | ----------- | -------
lock | true    | whether the Migrator must lock the schema before running migrations |
lock_timeout | 30 | number of seconds for auto-unlocking schema |
lock_retry | [] | array of retries. The size of the array is the max number of retries. Each item of the array is the number of seconds to wait until the next retry. | [1, 1, 2, 3, 5, 8]
query_timeout | 30 | number of seconds after which to time out the command if it hasn’t completed |
query_delay | 0 | number of millisenconds to wait after each schema change |

## Installation

You can install it using rubygems.

```
gem install cassandra-schema
```

## How to collaborate

If you find a bug or want to collaborate with the code, you can:

* Report issues trhough the issue tracker
* Fork the repository into your own account and submit a Pull Request

## Credits

These people have donated time to reviewing and improving this gem:

* [Ary Borenszweig](https://github.com/asterite)
* [Joe Eli McIlvain](https://github.com/jemc)
* [Lucas Tolchinsky](https://github.com/tonchis)
* [Matías Flores](https://github.com/matflores)

## Copyright

MIT License

Copyright (c) 2017 Lautaro Orazi

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
