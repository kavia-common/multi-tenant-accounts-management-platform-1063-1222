-- 003_rls_usage_helpers.sql
-- Purpose: Helpers to make it easier for application sessions to set/reset tenant context for RLS.
-- NOTE:
-- - The backend must set `SET LOCAL app.current_tenant = '<tenant-uuid>';` per request/transaction.
-- - Do not expose these to end users; they are for application connections only.

CREATE OR REPLACE FUNCTION set_app_tenant(p_tenant UUID)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  -- SET LOCAL affects current transaction only; recommended to call per request within a transaction.
  PERFORM set_config('app.current_tenant', COALESCE(p_tenant::text,''), true);
END;
$$;

CREATE OR REPLACE FUNCTION clear_app_tenant()
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM set_config('app.current_tenant', '', true);
END;
$$;
