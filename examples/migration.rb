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
