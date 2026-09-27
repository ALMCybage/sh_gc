<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Relations\BelongsTo;

class SalesRecord extends TenantModel
{
    protected $table = 'sales_records';

    protected $fillable = [
        'request_id',
        'external_id',
        'employee_id',
        'rep_email',
        'product',
        'amount',
        'currency',
        'sold_at',
    ];

    protected $casts = [
        'amount' => 'decimal:2',
        'sold_at' => 'datetime',
    ];

    public function employee(): BelongsTo
    {
        return $this->belongsTo(Employee::class);
    }
}
