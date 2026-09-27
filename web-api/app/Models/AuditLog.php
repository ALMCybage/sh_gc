<?php

namespace App\Models;

class AuditLog extends TenantModel
{
    protected $table = 'audit_logs';

    /** Append-only: there is no updated_at, and rows are never modified. */
    public $timestamps = false;

    protected $fillable = [
        'actor_id',
        'actor_email',
        'actor_role',
        'action',
        'subject_type',
        'subject_id',
        'request_id',
        'trace_id',
        'ip',
        'user_agent',
        'outcome',
        'context',
    ];

    protected $casts = [
        'context' => 'array',
        'created_at' => 'datetime',
    ];
}
