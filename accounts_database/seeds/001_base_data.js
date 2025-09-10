'use strict';

/**
 * Seed base data:
 *  - One sample organization
 *  - Standard roles (Admin, Manager, Sales Rep, Viewer) for that org
 *  - A baseline set of permissions
 *  - Role-permission mappings (Admin gets all)
 *
 * RLS note: We set the session variable app.current_tenant to the sample org ID
 * to comply with the RLS policies during INSERTs.
 */

exports.seed = async function seed(knex) {
  const { randomUUID } = require('crypto');

  const orgId = randomUUID();

  const permissions = [
    { id: randomUUID(), name: 'org.read', description: 'Read organization metadata' },
    { id: randomUUID(), name: 'org.write', description: 'Update organization metadata' },
    { id: randomUUID(), name: 'user.read', description: 'Read users' },
    { id: randomUUID(), name: 'user.write', description: 'Create/update users' },
    { id: randomUUID(), name: 'user.invite', description: 'Invite users' },
    { id: randomUUID(), name: 'roles.read', description: 'Read roles' },
    { id: randomUUID(), name: 'roles.write', description: 'Create/update roles' },
    { id: randomUUID(), name: 'audit.read', description: 'Read audit logs' },
    { id: randomUUID(), name: 'audit.export', description: 'Export audit logs' },
    { id: randomUUID(), name: 'dashboard.view', description: 'View dashboard' }
  ];

  const roles = [
    { id: randomUUID(), tenant_id: orgId, name: 'Admin', description: 'Full access', is_standard: true },
    { id: randomUUID(), tenant_id: orgId, name: 'Manager', description: 'Manage team and org settings', is_standard: true },
    { id: randomUUID(), tenant_id: orgId, name: 'Sales Rep', description: 'Sales related access', is_standard: true },
    { id: randomUUID(), tenant_id: orgId, name: 'Viewer', description: 'Read-only access', is_standard: true }
  ];

  // Role-permission mapping helper by name
  const map = {
    Admin: permissions.map((p) => p.name),
    Manager: ['org.read', 'org.write', 'user.read', 'user.invite', 'roles.read', 'roles.write', 'audit.read', 'dashboard.view'],
    'Sales Rep': ['user.read', 'dashboard.view'],
    Viewer: ['dashboard.view']
  };

  await knex.transaction(async (trx) => {
    // Set current tenant for RLS checks
    await trx.raw(`SELECT set_config('app.current_tenant', ?, true)`, [orgId]);

    // Insert sample organization (RLS requires id to match current tenant)
    await trx('organizations')
      .insert({
        id: orgId,
        name: 'Sample Organization',
        metadata: { plan: 'trial', createdBySeed: true }
      });

    // Insert permissions (global)
    await trx('permissions')
      .insert(permissions)
      .onConflict('name')
      .ignore();

    // Insert roles for sample organization
    await trx('roles')
      .insert(roles)
      .onConflict(['tenant_id', 'name'])
      .ignore();

    // Build role_permissions rows
    const dbPerms = await trx('permissions').select(['id', 'name']);
    const nameToPerm = new Map(dbPerms.map((p) => [p.name, p.id]));

    const dbRoles = await trx('roles').where({ tenant_id: orgId }).select(['id', 'name']);
    const nameToRole = new Map(dbRoles.map((r) => [r.name, r.id]));

    const rolePermRows = [];
    for (const [roleName, permNames] of Object.entries(map)) {
      const roleId = nameToRole.get(roleName);
      if (!roleId) continue;
      for (const permName of permNames) {
        const permId = nameToPerm.get(permName);
        if (permId) {
          rolePermRows.push({ role_id: roleId, permission_id: permId });
        }
      }
    }

    if (rolePermRows.length > 0) {
      await trx('role_permissions')
        .insert(rolePermRows)
        .onConflict(['role_id', 'permission_id'])
        .ignore();
    }
  });
};
