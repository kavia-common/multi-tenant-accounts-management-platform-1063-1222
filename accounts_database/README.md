# Accounts Database (PostgreSQL) - Migrations & Seeding

This package contains Knex-based migrations and seed scripts for the Multi-Tenant Accounts Management Platform. It provisions all core tables, indexes, and Row Level Security (RLS) using PostgreSQL policies to enforce tenant isolation via `current_setting('app.current_tenant')`.

## Schema Overview

Tables created:
- organizations
- users
- roles
- permissions
- role_permissions
- user_roles
- password_resets
- audit_logs

Indexes:
- users(tenant_id)
- roles(tenant_id)
- user_roles(tenant_id)
- audit_logs(tenant_id), audit_logs(created_at)
- password_resets(token)

RLS is enabled on:
- organizations (id = current_setting('app.current_tenant')::uuid)
- users (tenant_id = current_setting('app.current_tenant')::uuid)
- roles (tenant_id = current_setting('app.current_tenant')::uuid)
- user_roles (tenant_id = current_setting('app.current_tenant')::uuid)
- password_resets (tenant derived via subselect from users)
- audit_logs (tenant_id = current_setting('app.current_tenant')::uuid)

All policies use `current_setting('app.current_tenant')` for tenant isolation.

## Requirements

- Node.js (for Knex CLI)
- PostgreSQL accessible network-wise
- Set environment variables (copy `.env.example` to `.env` and fill values)

## Configure

1. Copy `.env.example` to `.env` and set either:
   - `DATABASE_URL=postgres://USER:PASSWORD@HOST:PORT/DBNAME`, or
   - individual `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`.

2. Install deps:
   ```
   npm install
   ```

## Run Migrations

```
npm run db:migrate
```

To rollback all migrations:
```
npm run db:rollback
```

## Seeding

Seeds will:
- Create a sample organization
- Insert standard roles (Admin, Manager, Sales Rep, Viewer) for that organization
- Insert baseline permissions
- Map role permissions

Run:
```
npm run db:seed
```

Note: The seed script sets `app.current_tenant` to the seed organization UUID so the RLS policies allow inserts.

## Important: RLS Tenant Context

Your application must set the tenant context per DB session/connection:

- SQL:
  ```
  SET app.current_tenant = '<tenant-uuid>';
  ```
- With Knex (Node.js):
  ```js
  await knex.raw("SELECT set_config('app.current_tenant', ?, true)", [tenantUuid]);
  ```

This is required for all SELECT/INSERT/UPDATE/DELETE on RLS-protected tables.

## Tips

- Permissions are global (no tenant_id), roles are tenant-scoped.
- Roles have a uniqueness constraint per tenant: `(tenant_id, name)`.
- Seed can be rerun safely thanks to `ON CONFLICT DO NOTHING` semantics.
