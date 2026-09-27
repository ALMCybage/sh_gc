<?php

namespace App\Auth;

/**
 * Every authorisation decision in the application, named once.
 *
 * Routes reference these through the `can:` middleware and the SPA receives the
 * caller's list from /api/v1/auth/user, so the UI hides what the API would refuse
 * rather than guessing from a role name.
 */
final class Ability
{
    /** Trigger a payroll calculation. The money-moving action. */
    public const PAYROLL_RUN = 'payroll.run';

    /** Read payroll runs and their lines. */
    public const PAYROLL_VIEW = 'payroll.view';

    /** Submit a sales import. */
    public const SALES_IMPORT = 'sales.import';

    /** Read committed sales records. */
    public const SALES_VIEW = 'sales.view';

    /** List employees. */
    public const EMPLOYEES_VIEW = 'employees.view';

    /**
     * See salary and commission rate.
     *
     * Separate from EMPLOYEES_VIEW on purpose: "who works here" and "what they
     * are paid" are different sensitivities, and an operator needs the first
     * without the second.
     */
    public const EMPLOYEES_VIEW_COMPENSATION = 'employees.view-compensation';

    /** Read the tenant's audit log. */
    public const AUDIT_VIEW = 'audit.view';

    /** Create and modify users within the tenant. */
    public const USERS_MANAGE = 'users.manage';

    public const ALL = [
        self::PAYROLL_RUN,
        self::PAYROLL_VIEW,
        self::SALES_IMPORT,
        self::SALES_VIEW,
        self::EMPLOYEES_VIEW,
        self::EMPLOYEES_VIEW_COMPENSATION,
        self::AUDIT_VIEW,
        self::USERS_MANAGE,
    ];
}
