<?php

namespace App\Console\Commands;

use App\Tenancy\TenantManager;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Throwable;

class TenantsList extends Command
{
    protected $signature = 'tenants:list {--check-db : Attempt a connection to each tenant schema}';

    protected $description = 'Show the tenant registry and, optionally, schema connectivity';

    public function handle(TenantManager $tenants): int
    {
        $rows = [];

        foreach ($tenants->all() as $tenant) {
            $status = '-';

            if ($this->option('check-db')) {
                $status = $tenants->runFor($tenant, function () use ($tenants) {
                    try {
                        DB::connection($tenants->connectionName())->getPdo();

                        return 'ok';
                    } catch (Throwable $e) {
                        return 'FAIL: '.Str::limit($e->getMessage(), 60);
                    }
                });
            }

            $rows[] = [$tenant->id, $tenant->name, $tenant->domain ?? '-', $tenant->database, $status];
        }

        $this->table(['id', 'name', 'domain', 'schema', 'db'], $rows);

        return self::SUCCESS;
    }
}
