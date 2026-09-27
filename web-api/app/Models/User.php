<?php

namespace App\Models;

use App\Auth\Role;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Foundation\Auth\User as Authenticatable;
use Illuminate\Notifications\Notifiable;
use Laravel\Sanctum\HasApiTokens;

/**
 * Users live inside the tenant schema, not in a shared table.
 *
 * Binding to the "tenant" connection means the auth provider queries whichever
 * schema ResolveTenant selected for this request, so acme.sequifi.com can never
 * authenticate a whiteknight user even if the credentials happen to match.
 */
class User extends Authenticatable
{
    use HasApiTokens, HasFactory, Notifiable;

    protected $connection = 'tenant';

    /**
     * @var array<int, string>
     */
    protected $fillable = [
        'name',
        'email',
        'password',
        'role',
        'is_active',
    ];

    /**
     * @var array<int, string>
     */
    protected $hidden = [
        'password',
        'remember_token',
    ];

    /**
     * @var array<string, string>
     */
    protected $casts = [
        'email_verified_at' => 'datetime',
        'is_active' => 'boolean',
    ];

    /** @return array<int, string> */
    public function abilities(): array
    {
        return $this->is_active === false ? [] : Role::abilitiesFor($this->role);
    }

    public function hasAbility(string $ability): bool
    {
        return in_array($ability, $this->abilities(), true);
    }
}
