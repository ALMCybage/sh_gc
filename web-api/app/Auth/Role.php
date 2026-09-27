<?php

namespace App\Auth;

/**
 * Roles are per tenant, because the users table lives inside the tenant schema.
 * The same person in two tenants is two rows and may hold different roles.
 *
 * Kept as a small fixed set rather than a permissions table: payroll has a narrow
 * set of genuinely distinct duties, and a fixed enum makes the authorisation
 * rules readable and testable. Swap to a permissions table when the set of
 * abilities starts varying per tenant.
 */
final class Role
{
    /** Full control, including managing other users. */
    public const OWNER = 'owner';

    /** Can run payroll and import sales. The operational role. */
    public const ADMIN = 'admin';

    /** Can import sales and read everything, but cannot run payroll. */
    public const OPERATOR = 'operator';

    /** Read-only. Cannot trigger any async work. */
    public const VIEWER = 'viewer';

    public const ALL = [self::OWNER, self::ADMIN, self::OPERATOR, self::VIEWER];

    public const DEFAULT = self::VIEWER;

    /**
     * Abilities granted to each role.
     *
     * Written as an explicit matrix rather than inheritance so a reviewer can see
     * exactly what a role can do without walking a hierarchy. Note payroll.run is
     * deliberately narrower than sales.import: running payroll moves money.
     *
     * @var array<string, array<int, string>>
     */
    public const ABILITIES = [
        self::OWNER => [
            Ability::PAYROLL_RUN,
            Ability::PAYROLL_VIEW,
            Ability::SALES_IMPORT,
            Ability::SALES_VIEW,
            Ability::EMPLOYEES_VIEW,
            Ability::EMPLOYEES_VIEW_COMPENSATION,
            Ability::AUDIT_VIEW,
            Ability::USERS_MANAGE,
        ],
        self::ADMIN => [
            Ability::PAYROLL_RUN,
            Ability::PAYROLL_VIEW,
            Ability::SALES_IMPORT,
            Ability::SALES_VIEW,
            Ability::EMPLOYEES_VIEW,
            Ability::EMPLOYEES_VIEW_COMPENSATION,
            Ability::AUDIT_VIEW,
        ],
        self::OPERATOR => [
            Ability::PAYROLL_VIEW,
            Ability::SALES_IMPORT,
            Ability::SALES_VIEW,
            Ability::EMPLOYEES_VIEW,
        ],
        self::VIEWER => [
            Ability::PAYROLL_VIEW,
            Ability::SALES_VIEW,
            Ability::EMPLOYEES_VIEW,
        ],
    ];

    /** @return array<int, string> */
    public static function abilitiesFor(?string $role): array
    {
        return self::ABILITIES[$role] ?? [];
    }

    public static function isValid(?string $role): bool
    {
        return in_array($role, self::ALL, true);
    }
}
