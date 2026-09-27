<?php

namespace App\Providers;

use App\Auth\Ability;
use App\Auth\Role;
use App\Models\User;
use Illuminate\Foundation\Support\Providers\AuthServiceProvider as ServiceProvider;
use Illuminate\Support\Facades\Gate;

class AuthServiceProvider extends ServiceProvider
{
    /**
     * @var array<class-string, class-string>
     */
    protected $policies = [];

    public function boot(): void
    {
        $this->registerPolicies();

        /*
         * One gate per ability, driven off the role matrix. Routes then use
         * `can:payroll.run` and the check is identical everywhere - there is no
         * second place where "is this user an admin?" gets decided differently.
         */
        foreach (Ability::ALL as $ability) {
            Gate::define($ability, function (User $user) use ($ability) {
                return in_array($ability, Role::abilitiesFor($user->role), true);
            });
        }

        /*
         * A deactivated user keeps a valid session until it expires, so the check
         * belongs here rather than only at login. `before` short-circuits every
         * gate, so one flag revokes everything immediately.
         */
        Gate::before(function (User $user) {
            if ($user->is_active === false) {
                return false;
            }

            return null; // fall through to the specific gate
        });
    }
}
