<?php

namespace Database\Seeders;

use App\Auth\Role;
use App\Models\Employee;
use App\Models\User;
use App\Tenancy\TenantManager;
use Illuminate\Database\Seeder;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Str;

/**
 * Seeds a demo workforce and one user per role into whichever tenant schema is
 * currently bound. Run through `php artisan tenants:migrate --seed`.
 */
class TenantSeeder extends Seeder
{
    public function run(): void
    {
        $this->seedUsers();
        $this->seedEmployees();
    }

    /**
     * One user per role, so the authorisation matrix can actually be exercised.
     * Emails are namespaced by tenant id: it makes it obvious in a demo that
     * acme's users cannot sign in to whiteknight, because the users table lives
     * inside the tenant schema and the row simply is not there.
     */
    private function seedUsers(): void
    {
        $tenant = app(TenantManager::class)->currentOrFail();

        $users = [
            ['role' => Role::OWNER, 'local' => 'owner'],
            ['role' => Role::ADMIN, 'local' => 'admin'],
            ['role' => Role::OPERATOR, 'local' => 'operator'],
            ['role' => Role::VIEWER, 'local' => 'viewer'],
        ];

        foreach ($users as $definition) {
            $email = "{$definition['local']}@{$tenant->id}.test";

            if (User::query()->where('email', $email)->exists()) {
                continue;
            }

            User::query()->create([
                'name' => $tenant->name.' '.Str::title($definition['local']),
                'email' => $email,
                'password' => Hash::make('password'),
                'role' => $definition['role'],
                'is_active' => true,
            ]);

            $this->command?->line("  seeded {$email} ({$definition['role']})");
        }
    }

    private function seedEmployees(): void
    {
        if (Employee::query()->exists()) {
            $this->command?->line('  employees already seeded, skipping');

            return;
        }

        $departments = ['Sales', 'Engineering', 'Support', 'Finance'];
        $employees = [];

        for ($i = 1; $i <= 25; $i++) {
            $department = $departments[$i % count($departments)];

            $employees[] = [
                'employee_code' => sprintf('EMP-%04d', $i),
                'first_name' => 'Employee'.$i,
                'last_name' => Str::upper(Str::random(5)),
                'email' => sprintf('employee%02d@example.test', $i),
                'department' => $department,
                'base_salary' => 45000 + ($i * 1300),
                'commission_rate' => $department === 'Sales' ? 0.0450 : 0.0000,
                'is_active' => $i % 11 !== 0,
                'created_at' => now(),
                'updated_at' => now(),
            ];
        }

        Employee::query()->insert($employees);

        $this->command?->line('  seeded '.count($employees).' employees');
    }
}
