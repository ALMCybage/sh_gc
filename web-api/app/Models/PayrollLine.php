<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Relations\BelongsTo;

class PayrollLine extends TenantModel
{
    protected $table = 'payroll_lines';

    protected $fillable = [
        'payroll_run_id',
        'employee_id',
        'gross_amount',
        'tax_amount',
        'commission_amount',
        'net_amount',
    ];

    protected $casts = [
        'gross_amount' => 'decimal:2',
        'tax_amount' => 'decimal:2',
        'commission_amount' => 'decimal:2',
        'net_amount' => 'decimal:2',
    ];

    public function run(): BelongsTo
    {
        return $this->belongsTo(PayrollRun::class, 'payroll_run_id');
    }

    public function employee(): BelongsTo
    {
        return $this->belongsTo(Employee::class);
    }
}
