<?php

namespace App\Logging;

use Monolog\Formatter\NormalizerFormatter;
use Monolog\Logger;

/**
 * Emits JSON in the shape Cloud Logging actually understands.
 *
 * THE BUG THIS FIXES
 * Monolog's stock JsonFormatter writes {"level_name":"ERROR","level":400,
 * "message":"..."}. Cloud Logging looks for a top-level "severity" field and
 * ignores "level_name" entirely, so every line - including fatals - was ingested
 * at DEFAULT severity. You could not filter for errors, and severity-based alert
 * policies had nothing to fire on.
 *
 * The special fields Cloud Logging promotes out of a structured payload:
 *   severity                             -> the log level
 *   message                              -> the summary line in the UI
 *   logging.googleapis.com/trace         -> groups entries into one trace
 *   logging.googleapis.com/spanId        -> span within that trace
 *   logging.googleapis.com/sourceLocation-> file/line
 *
 * Everything else stays in jsonPayload and is queryable, which is where the tenant
 * id and request id end up.
 */
class CloudLoggingFormatter extends NormalizerFormatter
{
    /**
     * Monolog level -> Cloud Logging severity.
     *
     * Note Monolog has no CRITICAL/ALERT/EMERGENCY equivalents in Cloud Logging's
     * lower bands, so they map upward: an EMERGENCY should page, and EMERGENCY is
     * the highest severity Cloud Logging accepts.
     */
    private const SEVERITY = [
        Logger::DEBUG => 'DEBUG',
        Logger::INFO => 'INFO',
        Logger::NOTICE => 'NOTICE',
        Logger::WARNING => 'WARNING',
        Logger::ERROR => 'ERROR',
        Logger::CRITICAL => 'CRITICAL',
        Logger::ALERT => 'ALERT',
        Logger::EMERGENCY => 'EMERGENCY',
    ];

    public function __construct(private readonly ?string $projectId = null)
    {
        // RFC3339 with microseconds: Cloud Logging parses it as the entry
        // timestamp, so log ordering survives a burst inside the same second.
        parent::__construct('Y-m-d\TH:i:s.uP');
    }

    /**
     * @param  array<string, mixed>  $record
     */
    public function format(array $record): string
    {
        /** @var array<string, mixed> $normalised */
        $normalised = parent::format($record);

        $payload = [
            'severity' => self::SEVERITY[$record['level']] ?? 'DEFAULT',
            'message' => $normalised['message'] ?? '',
            'time' => $normalised['datetime'] ?? null,
            'channel' => $normalised['channel'] ?? null,
        ];

        $context = (array) ($normalised['context'] ?? []);
        $extra = (array) ($normalised['extra'] ?? []);

        // Context is merged to the top level rather than nested, so a query is
        // jsonPayload.tenant_id="acme" instead of jsonPayload.context.tenant_id.
        $payload += $context;

        if ($extra !== []) {
            $payload['extra'] = $extra;
        }

        // Pull the trace out of the payload into the field that makes Cloud
        // Logging group the web request and the worker's execution together.
        if ($this->projectId && ! empty($context['trace_id'])) {
            $payload['logging.googleapis.com/trace'] =
                sprintf('projects/%s/traces/%s', $this->projectId, $context['trace_id']);
        }

        if (! empty($context['exception']) && is_array($context['exception'])) {
            $exception = $context['exception'];

            $payload['logging.googleapis.com/sourceLocation'] = array_filter([
                'file' => $exception['file'] ?? null,
                'line' => isset($exception['line']) ? (string) $exception['line'] : null,
            ]);
        }

        return $this->toJson(array_filter($payload, static fn ($v) => $v !== null && $v !== []), true)."\n";
    }
}
