-- 001_init_schema.sql
-- Purpose: Create base objects for multi-tenant accounts DB with row-level security (RLS).
-- Notes:
-- - This file is idempotent where possible (uses IF NOT EXISTS)
-- - Do NOT hardcode secrets. Use environment variables / RDS parameter groups for TLS and encryption.
-- - Encryption at rest/in-transit is handled by RDS configuration, not by this SQL.

-- Extensions commonly useful
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Organizations (tenants)
CREATE TABLE IF NOT EXISTS organizations (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name VARCHAR(128) NOT NULL UNIQUE,
  metadata JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ
);

-- Users
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  email VARCHAR(255) NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT FALSE,
  is_email_verified BOOLEAN NOT NULL DEFAULT FALSE,
  mfa_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ
);
-- Enforce uniqueness of email per tenant (same email can exist in multiple tenants)
CREATE UNIQUE INDEX IF NOT EXISTS ux_users_tenant_email ON users(tenant_id, email);

-- Roles (tenant-scoped). Standard roles (Admin, Manager, Sales Rep, Viewer) will be flagged via is_standard=TRUE
CREATE TABLE IF NOT EXISTS roles (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name VARCHAR(64) NOT NULL,
  description TEXT,
  is_standard BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, name)
);

-- Permissions (global list, not tenant-scoped)
CREATE TABLE IF NOT EXISTS permissions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name VARCHAR(64) NOT NULL UNIQUE,
  description TEXT
);

-- Role-Permissions (join, tenant is derivable via role)
CREATE TABLE IF NOT EXISTS role_permissions (
  role_id UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  permission_id UUID NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
  PRIMARY KEY (role_id, permission_id)
);

-- User-Roles (assignment per tenant)
CREATE TABLE IF NOT EXISTS user_roles (
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role_id UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  tenant_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  PRIMARY KEY (user_id, role_id, tenant_id),
  -- Guard against mismatched tenant references
  CONSTRAINT user_roles_role_tenant_fk CHECK (
    tenant_id = (SELECT r.tenant_id FROM roles r WHERE r.id = role_id)
  ),
  CONSTRAINT user_roles_user_tenant_fk CHECK (
    tenant_id = (SELECT u.tenant_id FROM users u WHERE u.id = user_id)
  )
);

-- Password reset tokens (per user)
CREATE TABLE IF NOT EXISTS password_resets (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token VARCHAR(255) NOT NULL UNIQUE,
  expires_at TIMESTAMPTZ NOT NULL,
  used BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Audit logs (tenant scoped)
CREATE TABLE IF NOT EXISTS audit_logs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  actor_id UUID,
  event_type VARCHAR(128) NOT NULL,
  event_data JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Helpful GIN indexes for JSONB where filtering is common
CREATE INDEX IF NOT EXISTS idx_orgs_metadata_gin ON organizations USING GIN (metadata);

-- Performance indexes
CREATE INDEX IF NOT EXISTS idx_users_tenant_id ON users(tenant_id);
CREATE INDEX IF NOT EXISTS idx_roles_tenant_id ON roles(tenant_id);
CREATE INDEX IF NOT EXISTS idx_user_roles_tenant_id ON user_roles(tenant_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_tenant_id ON audit_logs(tenant_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at ON audit_logs(created_at);
CREATE INDEX IF NOT EXISTS idx_password_resets_user_id ON password_resets(user_id);
CREATE INDEX IF NOT EXISTS idx_password_resets_expires_at ON password_resets(expires_at);

-- Tenant-context machinery:
-- All RLS policies will rely on current_setting('app.current_tenant', true)
-- Add a helper function to fetch the current tenant_id as UUID safely
CREATE OR REPLACE FUNCTION app_current_tenant() RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v TEXT;
BEGIN
  v := current_setting('app.current_tenant', true);
  IF v IS NULL OR v = '' THEN
    RETURN NULL;
  END IF;
  BEGIN
    RETURN v::uuid;
  EXCEPTION WHEN others THEN
    RETURN NULL;
  END;
END;
$$;

-- Enable RLS on tenant-scoped tables
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;

-- RLS Policies:
-- Users: rows visible only if tenant matches app_current_tenant()
DROP POLICY IF EXISTS rls_users_tenant_isolation ON users;
CREATE POLICY rls_users_tenant_isolation ON users
USING (tenant_id = app_current_tenant())
WITH CHECK (tenant_id = app_current_tenant());

-- Roles
DROP POLICY IF EXISTS rls_roles_tenant_isolation ON roles;
CREATE POLICY rls_roles_tenant_isolation ON roles
USING (tenant_id = app_current_tenant())
WITH CHECK (tenant_id = app_current_tenant());

-- User roles
DROP POLICY IF EXISTS rls_user_roles_tenant_isolation ON user_roles;
CREATE POLICY rls_user_roles_tenant_isolation ON user_roles
USING (tenant_id = app_current_tenant())
WITH CHECK (tenant_id = app_current_tenant());

-- Audit logs
DROP POLICY IF EXISTS rls_audit_logs_tenant_isolation ON audit_logs;
CREATE POLICY rls_audit_logs_tenant_isolation ON audit_logs
USING (tenant_id = app_current_tenant())
WITH CHECK (tenant_id = app_current_tenant());

-- Password resets: scope by underlying user's tenant_id via a subquery
ALTER TABLE password_resets ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS rls_password_resets_tenant_isolation ON password_resets;
CREATE POLICY rls_password_resets_tenant_isolation ON password_resets
USING (
  EXISTS (
    SELECT 1 FROM users u
    WHERE u.id = password_resets.user_id
      AND u.tenant_id = app_current_tenant()
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM users u
    WHERE u.id = password_resets.user_id
      AND u.tenant_id = app_current_tenant()
  )
);

-- Permissions and role_permissions are not tenant-scoped data by themselves. However,
-- exposure occurs via roles in a tenant. To be safe, we can allow read to all but
-- writes are controlled by backend. If you prefer full RLS, define policies tied via joins.
ALTER TABLE permissions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS rls_permissions_read_all ON permissions;
CREATE POLICY rls_permissions_read_all ON permissions
FOR SELECT USING (true);
-- writes guarded by backend, or add stricter policies if needed
DROP POLICY IF EXISTS rls_permissions_no_write ON permissions;
CREATE POLICY rls_permissions_no_write ON permissions
FOR ALL
TO PUBLIC
USING (true)
WITH CHECK (false);

ALTER TABLE role_permissions ENABLE ROW LEVEL SECURITY;
-- allow SELECT only when the role belongs to current tenant
DROP POLICY IF EXISTS rls_role_permissions_select ON role_permissions;
CREATE POLICY rls_role_permissions_select ON role_permissions
FOR SELECT USING (
  EXISTS (SELECT 1 FROM roles r WHERE r.id = role_permissions.role_id AND r.tenant_id = app_current_tenant())
);
-- allow INSERT/UPDATE/DELETE only if role in current tenant
DROP POLICY IF EXISTS rls_role_permissions_modify ON role_permissions;
CREATE POLICY rls_role_permissions_modify ON role_permissions
FOR ALL USING (
  EXISTS (SELECT 1 FROM roles r WHERE r.id = role_permissions.role_id AND r.tenant_id = app_current_tenant())
)
WITH CHECK (
  EXISTS (SELECT 1 FROM roles r WHERE r.id = role_permissions.role_id AND r.tenant_id = app_current_tenant())
);

-- Helpful comment:
COMMENT ON FUNCTION app_current_tenant() IS 'Returns current tenant UUID from app.current_tenant GUC; returns NULL if not set/invalid. Used by RLS policies.';
