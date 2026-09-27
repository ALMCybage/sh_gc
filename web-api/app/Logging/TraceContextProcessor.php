<?php

namespace App\Logging;

use App\Tenancy\TenantManager;
use Illuminate\Support\Str;
use Monolog\Processor\ProcessorInterface;

/**
 * Stamps the tenant and the Google trace id onto every log record.
 *
 * Doing it in a processor rather than at each call site means it cannot be
 * forgotten - and the trace id is what lets you take one incident and see the
 * nginx access log, the Laravel request and the Go worker's execution of the
 * resulting job as a single trace in Cloud Logging.
 */
class TraceContextProcessor implements ProcessorInterface
{
    /**
     * @param  array<string, mixed>  $record
     * @return array<string, mixed>
     */
    public function __invoke(array $record): array
    {
        $record['context']['service'] = 'web-api';
        $record['context']['pod'] = gethostname();

        if (! isset($record['context']['tenant_id'])) {
            $tenant = app()->bound(TenantManager::class)
                ? app(TenantManager::class)->current()
                : null;

            if ($tenant) {
                $record['context']['tenant_id'] = $tenant->id;
            }
        }

        if (! isset($record['context']['trace_id']) && $this->traceId()) {
            $record['context']['trace_id'] = $this->traceId();
        }

        return $record;
    }

    private function traceId(): ?string
    {
        // Not available in console commands, and request() would boot the HTTP
        // kernel unnecessarily there.
        if (! app()->runningInConsole() && app()->bound('request')) {
            $header = request()->header('X-Cloud-Trace-Context');

            return $header ? Str::before((string) $header, '/') : null;
        }

        return null;
    }
}
