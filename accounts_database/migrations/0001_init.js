'use strict';

/**
 * Initial schema for multi-tenant accounts management platform.
 * Includes tables: organizations, users, roles, permissions, role_permissions,
 * user_roles, password_resets, audit_logs.
 * Adds indexes and enforces Row Level Security (RLS) with tenant isolation using
 * current_setting('app.current_tenant').
 */

exports.up = async function up(knex) {
  // 1) Core tables
  await knex.schema.createTable('organizations', (table) => {
    table.uuid('id').primary();
    table.string('name', 128).notNullable();
    table.jsonb('metadata');
    table.timestamp('created_at', { useTz: true }).notNullable().defaultTo(knex.fn.now());
    table.timestamp('updated_at', { useTz: true });
  });

  await knex.schema.createTable('users', (table) => {
    table.uuid('id').primary();
    table.uuid('tenant_id').notNullable().references('id').inTable('organizations').onDelete('CASCADE');
    table.string('email', 255).notNullable().unique();
    table.string('password_hash', 255).notNullable();
    table.boolean('is_active').notNullable().defaultTo(false);
    table.boolean('is_email_verified').notNullable().defaultTo(false);
    table.boolean('mfa_enabled').notNullable().defaultTo(false);
    table.timestamp('created_at', { useTz: true }).notNullable().defaultTo(knex.fn.now());
    table.timestamp('updated_at', { useTz: true });
  });

  await knex.schema.createTable('roles', (table) => {
    table.uuid('id').primary();
    table.uuid('tenant_id').notNullable().references('id').inTable('organizations').onDelete('CASCADE');
    table.string('name', 64).notNullable();
    table.text('description');
    table.boolean('is_standard').notNullable().defaultTo(false);
    table.timestamp('created_at', { useTz: true }).notNullable().defaultTo(knex.fn.now());
    // Helpful uniqueness within tenant to prevent duplicates
    table.unique(['tenant_id', 'name'], 'uq_roles_tenant_name');
  });

  await knex.schema.createTable('permissions', (table) => {
    table.uuid('id').primary();
    table.string('name', 64).notNullable();
    table.text('description');
    table.unique(['name'], 'uq_permissions_name');
  });

  await knex.schema.createTable('role_permissions', (table) => {
    table.uuid('role_id').notNullable().references('id').inTable('roles').onDelete('CASCADE');
    table.uuid('permission_id').notNullable().references('id').inTable('permissions').onDelete('CASCADE');
    table.primary(['role_id', 'permission_id']);
  });

  await knex.schema.createTable('user_roles', (table) => {
    table.uuid('user_id').notNullable().references('id').inTable('users').onDelete('CASCADE');
    table.uuid('role_id').notNullable().references('id').inTable('roles').onDelete('CASCADE');
    table.uuid('tenant_id').notNullable().references('id').inTable('organizations').onDelete('CASCADE');
    table.primary(['user_id', 'role_id', 'tenant_id']);
  });

  await knex.schema.createTable('password_resets', (table) => {
    table.uuid('id').primary();
    table.uuid('user_id').notNullable().references('id').inTable('users').onDelete('CASCADE');
    table.string('token', 255).notNullable();
    table.timestamp('expires_at', { useTz: true }).notNullable();
    table.boolean('used').notNullable().defaultTo(false);
    table.timestamp('created_at', { useTz: true }).notNullable().defaultTo(knex.fn.now());
    table.index(['token'], 'idx_password_resets_token');
  });

  await knex.schema.createTable('audit_logs', (table) => {
    table.uuid('id').primary();
    table.uuid('tenant_id').notNullable().references('id').inTable('organizations').onDelete('CASCADE');
    table.uuid('actor_id').notNullable(); // kept generic
    table.string('event_type', 128).notNullable();
    table.jsonb('event_data');
    table.timestamp('created_at', { useTz: true }).notNullable().defaultTo(knex.fn.now());
  });

  // 2) Indexes for performance
  await knex.schema.alterTable('users', (table) => {
    table.index(['tenant_id'], 'idx_users_tenant_id');
  });
  await knex.schema.alterTable('roles', (table) => {
    table.index(['tenant_id'], 'idx_roles_tenant_id');
  });
  await knex.schema.alterTable('user_roles', (table) => {
    table.index(['tenant_id'], 'idx_user_roles_tenant_id');
  });
  await knex.schema.alterTable('audit_logs', (table) => {
    table.index(['tenant_id'], 'idx_audit_logs_tenant_id');
    table.index(['created_at'], 'idx_audit_logs_created_at');
  });

  // 3) Row Level Security (RLS) and policies
  // Organizations - restrict to current tenant (id equals current tenant id)
  await knex.schema.raw(`ALTER TABLE organizations ENABLE ROW LEVEL SECURITY`);
  await knex.schema.raw(`ALTER TABLE organizations FORCE ROW LEVEL SECURITY`);
  await knex.schema.raw(`
    CREATE POLICY orgs_tenant_isolation ON organizations
      FOR ALL
      USING (id = current_setting('app.current_tenant')::uuid)
      WITH CHECK (id = current_setting('app.current_tenant')::uuid)
  `);

  // Users - same tenant
  await knex.schema.raw(`ALTER TABLE users ENABLE ROW LEVEL SECURITY`);
  await knex.schema.raw(`ALTER TABLE users FORCE ROW LEVEL SECURITY`);
  await knex.schema.raw(`
    CREATE POLICY users_tenant_isolation ON users
      FOR ALL
      USING (tenant_id = current_setting('app.current_tenant')::uuid)
      WITH CHECK (tenant_id = current_setting('app.current_tenant')::uuid)
  `);

  // Roles - same tenant
  await knex.schema.raw(`ALTER TABLE roles ENABLE ROW LEVEL SECURITY`);
  await knex.schema.raw(`ALTER TABLE roles FORCE ROW LEVEL SECURITY`);
  await knex.schema.raw(`
    CREATE POLICY roles_tenant_isolation ON roles
      FOR ALL
      USING (tenant_id = current_setting('app.current_tenant')::uuid)
      WITH CHECK (tenant_id = current_setting('app.current_tenant')::uuid)
  `);

  // User Roles - same tenant
  await knex.schema.raw(`ALTER TABLE user_roles ENABLE ROW LEVEL SECURITY`);
  await knex.schema.raw(`ALTER TABLE user_roles FORCE ROW LEVEL SECURITY`);
  await knex.schema.raw(`
    CREATE POLICY user_roles_tenant_isolation ON user_roles
      FOR ALL
      USING (tenant_id = current_setting('app.current_tenant')::uuid)
      WITH CHECK (tenant_id = current_setting('app.current_tenant')::uuid)
  `);

  // Password resets - tenant derived from user
  await knex.schema.raw(`ALTER TABLE password_resets ENABLE ROW LEVEL SECURITY`);
  await knex.schema.raw(`ALTER TABLE password_resets FORCE ROW LEVEL SECURITY`);
  await knex.schema.raw(`
    CREATE POLICY password_resets_tenant_isolation ON password_resets
      FOR ALL
      USING (
        EXISTS (
          SELECT 1 FROM users u
          WHERE u.id = password_resets.user_id
            AND u.tenant_id = current_setting('app.current_tenant')::uuid
        )
      )
      WITH CHECK (
        EXISTS (
          SELECT 1 FROM users u
          WHERE u.id = password_resets.user_id
            AND u.tenant_id = current_setting('app.current_tenant')::uuid
        )
      )
  `);

  // Audit logs - same tenant
  await knex.schema.raw(`ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY`);
  await knex.schema.raw(`ALTER TABLE audit_logs FORCE ROW LEVEL SECURITY`);
  await knex.schema.raw(`
    CREATE POLICY audit_logs_tenant_isolation ON audit_logs
      FOR ALL
      USING (tenant_id = current_setting('app.current_tenant')::uuid)
      WITH CHECK (tenant_id = current_setting('app.current_tenant')::uuid)
  `);
};

exports.down = async function down(knex) {
  // Drop in reverse order of dependencies
  await knex.schema.dropTableIfExists('audit_logs');
  await knex.schema.dropTableIfExists('password_resets');
  await knex.schema.dropTableIfExists('user_roles');
  await knex.schema.dropTableIfExists('role_permissions');
  await knex.schema.dropTableIfExists('permissions');
  await knex.schema.dropTableIfExists('roles');
  await knex.schema.dropTableIfExists('users');
  await knex.schema.dropTableIfExists('organizations');
};
