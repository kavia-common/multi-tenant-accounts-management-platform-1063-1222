-- 002_seed_roles_permissions.sql
-- Purpose: Seed baseline permissions and provide helper to seed standard roles per tenant.

-- Baseline permissions (idempotent upsert by name)
WITH p(name, description) AS (
  VALUES
    ('org:read', 'Read organization data'),
    ('org:write', 'Create/Update/Delete organization data'),
    ('user:read', 'Read users in organization'),
    ('user:write', 'Create/Update/Delete users in organization'),
    ('role:read', 'Read roles and permissions'),
    ('role:write', 'Create/Update/Delete roles and permissions'),
    ('audit:read', 'Read audit logs'),
    ('audit:export', 'Export audit logs'),
    ('dashboard:view', 'View dashboard data')
)
INSERT INTO permissions (name, description)
SELECT name, description FROM p
ON CONFLICT (name) DO UPDATE SET description = EXCLUDED.description;

-- Helper function to create standard roles (Admin, Manager, Sales Rep, Viewer) per tenant with default permissions.
CREATE OR REPLACE FUNCTION seed_standard_roles_for_tenant(p_tenant_id UUID)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_admin UUID;
  v_manager UUID;
  v_sales UUID;
  v_viewer UUID;
BEGIN
  -- Admin
  INSERT INTO roles (tenant_id, name, description, is_standard)
  VALUES (p_tenant_id, 'Admin', 'Full admin access for the organization', TRUE)
  ON CONFLICT (tenant_id, name) DO NOTHING
  RETURNING id INTO v_admin;

  IF v_admin IS NULL THEN
    SELECT id INTO v_admin FROM roles WHERE tenant_id = p_tenant_id AND name = 'Admin';
  END IF;

  -- Manager
  INSERT INTO roles (tenant_id, name, description, is_standard)
  VALUES (p_tenant_id, 'Manager', 'Manage users and view reports', TRUE)
  ON CONFLICT (tenant_id, name) DO NOTHING
  RETURNING id INTO v_manager;

  IF v_manager IS NULL THEN
    SELECT id INTO v_manager FROM roles WHERE tenant_id = p_tenant_id AND name = 'Manager';
  END IF;

  -- Sales Rep
  INSERT INTO roles (tenant_id, name, description, is_standard)
  VALUES (p_tenant_id, 'Sales Rep', 'Access sales workflows and dashboard', TRUE)
  ON CONFLICT (tenant_id, name) DO NOTHING
  RETURNING id INTO v_sales;

  IF v_sales IS NULL THEN
    SELECT id INTO v_sales FROM roles WHERE tenant_id = p_tenant_id AND name = 'Sales Rep';
  END IF;

  -- Viewer
  INSERT INTO roles (tenant_id, name, description, is_standard)
  VALUES (p_tenant_id, 'Viewer', 'Read-only access', TRUE)
  ON CONFLICT (tenant_id, name) DO NOTHING
  RETURNING id INTO v_viewer;

  IF v_viewer IS NULL THEN
    SELECT id INTO v_viewer FROM roles WHERE tenant_id = p_tenant_id AND name = 'Viewer';
  END IF;

  -- Map permissions to roles
  -- Admin: all permissions
  INSERT INTO role_permissions (role_id, permission_id)
  SELECT v_admin, p.id FROM permissions p
  ON CONFLICT DO NOTHING;

  -- Manager: org:read, user:read, user:write, role:read, dashboard:view, audit:read
  INSERT INTO role_permissions (role_id, permission_id)
  SELECT v_manager, p.id
  FROM permissions p
  WHERE p.name IN ('org:read','user:read','user:write','role:read','dashboard:view','audit:read')
  ON CONFLICT DO NOTHING;

  -- Sales Rep: dashboard:view, user:read
  INSERT INTO role_permissions (role_id, permission_id)
  SELECT v_sales, p.id
  FROM permissions p
  WHERE p.name IN ('dashboard:view','user:read')
  ON CONFLICT DO NOTHING;

  -- Viewer: org:read, user:read, role:read, dashboard:view
  INSERT INTO role_permissions (role_id, permission_id)
  SELECT v_viewer, p.id
  FROM permissions p
  WHERE p.name IN ('org:read','user:read','role:read','dashboard:view')
  ON CONFLICT DO NOTHING;
END;
$$;

-- Optional: trigger to auto-seed standard roles when a new organization is created.
-- Uses SECURITY DEFINER to bypass RLS during seeding strictly for this operation.
CREATE OR REPLACE FUNCTION trg_seed_roles_on_org_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  PERFORM seed_standard_roles_for_tenant(NEW.id);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS seed_roles_after_org_insert ON organizations;
CREATE TRIGGER seed_roles_after_org_insert
AFTER INSERT ON organizations
FOR EACH ROW
EXECUTE FUNCTION trg_seed_roles_on_org_insert();
