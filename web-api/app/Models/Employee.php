<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Relations\HasMany;

class Employee extends TenantModel
{
    protected $table = 'employees';

    protected $fillable = [
        'employee_code',
        'first_name',
        'last_name',
        'email',
        'department',
        'base_salary',
        'commission_rate',
        'is_active',
    ];

    protected $casts = [
        'base_salary' => 'decimal:2',
        'commission_rate' => 'decimal:4',
        'is_active' => 'boolean',
    ];

    public function payrollLines(): HasMany
    {
        return $this->hasMany(PayrollLine::class);
    }

    public function salesRecords(): HasMany
    {
        return $this->hasMany(SalesRecord::class);
    }

    public function getFullNameAttribute(): string
    {
        return trim($this->first_name.' '.$this->last_name);
    }
}
