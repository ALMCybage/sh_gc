<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * Append-only record of who did what.
     *
     * Payroll is financial data, so "the system calculated 50,341.53" is not a
     * sufficient record - somebody authorised that run, and an auditor will ask
     * who. The worker records which pod did the arithmetic; this records which
     * human asked for it.
     *
     * Lives in the tenant schema so a tenant's audit trail is isolated with the
     * rest of its data and is included in that tenant's export or deletion.
     */
    public function up(): void
    {
        Schema::create('audit_logs', function (Blueprint $table) {
            $table->id();

            // Not a foreign key to users: the trail must survive the user row
            // being deleted, which is the exact moment it matters most.
            $table->unsignedBigInteger('actor_id')->nullable();
            $table->string('actor_email', 190)->nullable();
            $table->string('actor_role', 20)->nullable();

            $table->string('action', 64);
            $table->string('subject_type', 64)->nullable();
            $table->string('subject_id', 64)->nullable();

            // Correlates the audit entry with the async request and its logs.
            $table->uuid('request_id')->nullable()->index();
            $table->string('trace_id', 128)->nullable();

            $table->string('ip', 45)->nullable();
            $table->string('user_agent', 255)->nullable();
            $table->string('outcome', 16)->default('success');

            // Request parameters, minus anything sensitive. Never the payload.
            $table->json('context')->nullable();

            $table->timestamp('created_at')->useCurrent();

            $table->index(['action', 'created_at']);
            $table->index(['actor_id', 'created_at']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('audit_logs');
    }
};
