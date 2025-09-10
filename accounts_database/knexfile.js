require('dotenv').config();

module.exports = {
  client: 'pg',
  connection: process.env.DATABASE_URL || {
    host: process.env.PGHOST || 'localhost',
    port: process.env.PGPORT ? parseInt(process.env.PGPORT, 10) : 5432,
    database: process.env.PGDATABASE || 'accounts_db',
    user: process.env.PGUSER || 'postgres',
    password: process.env.PGPASSWORD || ''
  },
  pool: { min: 0, max: 10 },
  migrations: {
    directory: './migrations',
    tableName: 'knex_migrations'
  },
  seeds: {
    directory: './seeds'
  }
};
