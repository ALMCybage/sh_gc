/**
 * Mirrors App\Auth\Ability on the server.
 *
 * The client never decides authorisation - it receives the caller's resolved
 * ability list from /api/v1/auth/user and uses it only to hide controls the API
 * would refuse. Keeping the names in one place stops a typo silently disabling a
 * feature: `can('payrol.run')` would just always be false.
 */
export const Ability = {
  PayrollRun: 'payroll.run',
  PayrollView: 'payroll.view',
  SalesImport: 'sales.import',
  SalesView: 'sales.view',
  EmployeesView: 'employees.view',
  EmployeesViewCompensation: 'employees.view-compensation',
  AuditView: 'audit.view',
  UsersManage: 'users.manage',
} as const

export type AbilityName = (typeof Ability)[keyof typeof Ability]

export const RoleLabel: Record<string, string> = {
  owner: 'Owner',
  admin: 'Admin',
  operator: 'Operator',
  viewer: 'Viewer',
}
