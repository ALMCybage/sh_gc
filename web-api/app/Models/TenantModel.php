<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

/**
 * Base class for everything that lives inside a tenant schema.
 *
 * The "tenant" connection is reconfigured per request by
 * App\Tenancy\TenantManager, so binding to it here means a model can never
 * accidentally read from the wrong tenant's database.
 */
abstract class TenantModel extends Model
{
    protected $connection = 'tenant';
}
