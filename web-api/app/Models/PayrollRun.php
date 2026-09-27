<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Relations\HasMany;

class PayrollRun extends TenantModel
{
    protected $table = 'payroll_runs';

    protected $fillable = [
        'request_id',
        'period_start',
        'period_end',
        'status',
        'employee_count',
        'gross_total',
        'net_total',
        'tax_total',
        'commission_total',
        'currency',
        'processed_by',
        'duration_ms',
        'notes',
    ];

    protected $casts = [
        'period_start' => 'date',
        'period_end' => 'date',
        'gross_total' => 'decimal:2',
        'net_total' => 'decimal:2',
        'tax_total' => 'decimal:2',
        'commission_total' => 'decimal:2',
    ];

    public function lines(): HasMany
    {
        return $this->hasMany(PayrollLine::class);
    }
}
