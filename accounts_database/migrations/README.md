# Accounts Database Migrations (PostgreSQL)

This folder contains SQL migration scripts for the multi-tenant Accounts Management Platform. The schema enforces strict tenant isolation using PostgreSQL Row-Level Security (RLS) on tenant-scoped tables. All queries must run with a tenant context set via a session parameter.

## Files

1. `001_init_schema.sql`
   - Creates base tables: `organizations`, `users`, `roles`, `permissions`, `role_permissions`, `user_roles`, `password_resets`, `audit_logs`.
   - Creates helper function `app_current_tenant()` used by RLS.
   - Enables RLS and defines policies to scope access by `tenant_id`.
   - Adds performance indexes and JSONB GIN index on organization metadata.
   - Installs `uuid-ossp` and `pgcrypto` extensions if available.

2. `002_seed_roles_permissions.sql`
   - Seeds a minimum set of permissions.
   - Provides `seed_standard_roles_for_tenant(tenant_id)` to create standard roles (Admin, Manager, Sales Rep, Viewer) and assign default permissions.
   - Adds a trigger to automatically seed roles after a new `organizations` row is inserted.

3. `003_rls_usage_helpers.sql`
   - Provides optional helper functions `set_app_tenant(uuid)` and `clear_app_tenant()` to manage the `app.current_tenant` GUC for the current session/transaction.

## Applying Migrations

If you do not use a migration tool, apply the scripts in order:

```bash
# Use the connection string from accounts_database/db_connection.txt
# Example (from repository root):
psql postgresql://appuser:dbuser123@localhost:5000/myapp -f accounts_database/migrations/001_init_schema.sql
psql postgresql://appuser:dbuser123@localhost:5000/myapp -f accounts_database/migrations/002_seed_roles_permissions.sql
psql postgresql://appuser:dbuser123@localhost:5000/myapp -f accounts_database/migrations/003_rls_usage_helpers.sql
```

If you use a migration tool (e.g., Flyway, Liquibase, Prisma, Knex), configure it to run these SQL files in lexicographical order.

## Tenant Isolation (RLS)

- The schema relies on `current_setting('app.current_tenant', true)` to determine the active tenant.
- The backend must set the tenant for each request (prefer within a transaction):

```sql
BEGIN;
SET LOCAL app.current_tenant = '<tenant-uuid>';
-- perform queries here; RLS will allow only rows with matching tenant_id
COMMIT;
```

- Helper functions provided (optional):
  - `SELECT set_app_tenant('<tenant-uuid>'::uuid);`
  - `SELECT clear_app_tenant();`

RLS is enabled on:
- `users`, `roles`, `user_roles`, `audit_logs`, `password_resets`
- `permissions` and `role_permissions` also have RLS; permissions are globally readable, while role_permissions are restricted via the role’s tenant.

Important: Always verify that application roles do not bypass RLS (avoid superuser/owner roles for app connections). Grant only needed privileges and maintain least privilege.

## Indexes

Created for performance:
- `users(tenant_id)`, unique `(tenant_id, email)`
- `roles(tenant_id)`, unique `(tenant_id, name)`
- `user_roles(tenant_id)`
- `audit_logs(tenant_id)`, `audit_logs(created_at)`
- `password_resets(user_id)`, `password_resets(expires_at)`
- `organizations USING GIN (metadata)`

These support common access patterns and filters for tenant-scoped queries and audit log retrieval.

## Seeding Standard Roles and Permissions

- Baseline permissions are inserted by `002_seed_roles_permissions.sql`.
- Standard roles (Admin, Manager, Sales Rep, Viewer) are automatically created for every new organization via a trigger.
- If you need to seed for an existing tenant manually:

```sql
SELECT seed_standard_roles_for_tenant('<tenant-uuid>'::uuid);
```

## Security & Compliance Notes

- Encryption at rest and in transit is managed by infrastructure (e.g., AWS RDS):
  - Enable storage-level encryption (AES-256) for RDS.
  - Require TLS connections (sslmode=require) for clients.
  - Manage keys using AWS KMS with rotation policies.
- Do not store secrets in SQL or source code. Use environment variables or a secrets manager (AWS Secrets Manager / HashiCorp Vault).
- Ensure the application database user:
  - Is NOT a superuser.
  - Does NOT own the tables if you want stronger separation (ownership can be kept to a migration/admin role).
  - Has only the required privileges (SELECT/INSERT/UPDATE/DELETE) on tables and no rights to `ALTER POLICY` or `DISABLE RLS`.
- Audit logs table is tenant-scoped and RLS-protected; for tamper-evidence, back-end services should additionally forward logs to immutable storage (e.g., WORM/S3 Object Lock) or chain hashes at the application layer.

## Operational Guidance

- Set `SET LOCAL app.current_tenant = '<uuid>'` per-request transaction in the backend connection before issuing queries or let your ORM support session-level settings.
- Test RLS by attempting cross-tenant access; queries should return 0 rows and `INSERT/UPDATE/DELETE` should fail the `WITH CHECK` policy.
- Backups and DR:
  - Use RDS automated backups and point-in-time recovery.
  - Regularly test restore processes in a staging environment.

## Troubleshooting

- If queries return no rows unexpectedly, verify that `app.current_tenant` is set in the current transaction and matches the data `tenant_id`.
- If you receive “permission denied for relation ...”, confirm the application role has the expected privileges and RLS policies are correct.
- For large audit log queries, ensure the client supplies suitable filters (tenant_id, created_at range) to leverage indexes.

