<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * Attribution on the result row itself.
     *
     * The audit_logs entry records the request; these columns put the requester on
     * the payroll run, so anyone reading the run does not have to join to find out
     * who authorised it. Denormalised on purpose - an auditor reads runs, not logs.
     *
     * Additive and nullable, so the previous revision keeps working during a
     * rollout and existing rows do not need backfilling.
     */
    public function up(): void
    {
        Schema::table('payroll_runs', function (Blueprint $table) {
            $table->unsignedBigInteger('requested_by_id')->nullable()->after('request_id');
            $table->string('requested_by_email', 190)->nullable()->after('requested_by_id');
        });

        Schema::table('sales_records', function (Blueprint $table) {
            $table->string('imported_by_email', 190)->nullable()->after('request_id');
        });
    }

    public function down(): void
    {
        Schema::table('payroll_runs', function (Blueprint $table) {
            $table->dropColumn(['requested_by_id', 'requested_by_email']);
        });

        Schema::table('sales_records', function (Blueprint $table) {
            $table->dropColumn('imported_by_email');
        });
    }
};
