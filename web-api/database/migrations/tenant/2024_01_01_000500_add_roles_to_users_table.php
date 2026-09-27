<?php

use App\Auth\Role;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('users', function (Blueprint $table) {
            // Deliberately the least-privileged role by default: a user row created
            // by any future code path that forgets to set one gets read-only
            // access rather than the ability to run payroll.
            $table->string('role', 20)->default(Role::DEFAULT)->after('email');

            // Deactivation without deletion. Gate::before revokes every ability
            // immediately, without waiting for the session to expire.
            $table->boolean('is_active')->default(true)->after('role');

            $table->index(['role', 'is_active']);
        });
    }

    public function down(): void
    {
        Schema::table('users', function (Blueprint $table) {
            $table->dropIndex(['role', 'is_active']);
            $table->dropColumn(['role', 'is_active']);
        });
    }
};
