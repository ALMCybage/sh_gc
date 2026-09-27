<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('employees', function (Blueprint $table) {
            $table->id();
            $table->string('employee_code', 32)->unique();
            $table->string('first_name', 80);
            $table->string('last_name', 80);
            $table->string('email', 190)->unique();
            $table->string('department', 80)->nullable();
            $table->decimal('base_salary', 12, 2)->default(0);
            $table->decimal('commission_rate', 6, 4)->default(0);
            $table->boolean('is_active')->default(true);
            $table->timestamps();

            $table->index(['is_active', 'department']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('employees');
    }
};
