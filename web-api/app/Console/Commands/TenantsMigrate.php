<?php

namespace App\Console\Commands;

use App\Tenancy\Tenant;
use App\Tenancy\TenantManager;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Config;
use Illuminate\Support\Facades\DB;
use Throwable;

/**
 * Runs the tenant migration set against every tenant schema in the shared
 * Cloud SQL instance. Intended to run as a Kubernetes Job (or an initContainer)
 * before a new web/worker revision rolls out.
 */
class TenantsMigrate extends Command
{
    protected $signature = 'tenants:migrate
        {--tenant=* : Limit to specific tenant ids}
        {--fresh : Drop all tables first (never do this in production)}
        {--seed : Run the tenant seeder afterwards}
        {--create-schema=1 : CREATE DATABASE IF NOT EXISTS before migrating}';

    protected $description = 'Migrate the per-tenant MySQL schemas';

    public function handle(TenantManager $tenants): int
    {
        $selected = (array) $this->option('tenant');
        $targets = $selected
            ? array_map(fn (string $id) => $tenants->findOrFail($id), $selected)
            : array_values($tenants->all());

        if ($targets === []) {
            $this->components->warn('No tenants configured.');

            return self::SUCCESS;
        }

        $failed = 0;

        foreach ($targets as $tenant) {
            $this->components->info("Tenant [{$tenant->id}] -> schema [{$tenant->database}]");

            try {
                if ($this->option('create-schema')) {
                    $this->createSchema($tenant);
                }

                $tenants->runFor($tenant, fn () => $this->migrate($tenant));
            } catch (Throwable $e) {
                $failed++;
                $this->components->error("  {$tenant->id}: {$e->getMessage()}");
            }
        }

        return $failed === 0 ? self::SUCCESS : self::FAILURE;
    }

    private function migrate(Tenant $tenant): void
    {
        $connection = Config::get('tenancy.runtime_connection', 'tenant');

        $command = $this->option('fresh') ? 'migrate:fresh' : 'migrate';

        Artisan::call($command, [
            '--database' => $connection,
            '--path' => 'database/migrations/tenant',
            '--realpath' => false,
            '--force' => true,
        ], $this->getOutput());

        if ($this->option('seed')) {
            Artisan::call('db:seed', [
                '--database' => $connection,
                '--class' => 'TenantSeeder',
                '--force' => true,
            ], $this->getOutput());
        }
    }

    /**
     * Connect to information_schema (always present) so we can issue the
     * CREATE DATABASE for a schema that does not exist yet.
     */
    private function createSchema(Tenant $tenant): void
    {
        $template = Config::get('tenancy.template_connection', 'mysql');
        $settings = Config::get("database.connections.{$template}");
        $settings['database'] = 'information_schema';

        Config::set('database.connections.__schema_admin', $settings);
        DB::purge('__schema_admin');

        DB::connection('__schema_admin')->statement(sprintf(
            'CREATE DATABASE IF NOT EXISTS `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci',
            str_replace('`', '', $tenant->database),
        ));

        DB::purge('__schema_admin');
    }
}
