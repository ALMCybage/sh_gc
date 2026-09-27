<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('sales_records', function (Blueprint $table) {
            $table->id();
            $table->uuid('request_id')->index();
            // external_id is the source system's row id: unique so replayed
            // Pub/Sub messages upsert instead of duplicating revenue.
            $table->string('external_id', 64)->unique();
            $table->foreignId('employee_id')->nullable()->constrained('employees')->nullOnDelete();
            $table->string('rep_email', 190)->nullable();
            $table->string('product', 120)->nullable();
            $table->decimal('amount', 12, 2)->default(0);
            $table->char('currency', 3)->default('USD');
            $table->timestamp('sold_at')->nullable();
            $table->timestamps();

            $table->index(['sold_at', 'employee_id']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('sales_records');
    }
};
