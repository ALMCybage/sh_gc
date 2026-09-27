/**
 * Request type 2: bulk sales import (async).
 *
 * The file is parsed and validated in a Web Worker, then split into chunks that
 * respect the server's 2,000-row cap. Each chunk is its own request and its own
 * tracked job, so a 6,000-row file becomes three jobs in the Activity panel.
 */
import { useCallback, useRef, useState } from 'react'
import { useMutation } from '@tanstack/react-query'

import { Ability } from '../../api/abilities'
import { ApiError, newIdempotencyKey } from '../../api/client'
import { submitSalesImport } from '../../api/endpoints'
import { useAuth } from '../../auth/AuthProvider'
import { SALES_IMPORT_MAX_ROWS, type SalesRow } from '../../api/schemas'
import { Alert, Badge, Button, Card, Field, Input, PageHeader, Spinner } from '../../components/ui'
import { useJobs } from '../../jobs/JobsProvider'
import { integer, money } from '../../lib/format'
import type { ParseResult, RowIssue, WorkerMessage } from './csv.worker'

const SAMPLE_CSV = `external_id,rep_email,product,amount,currency,sold_at
SO-1001,employee01@example.test,Pro Plan,1499.99,USD,2026-09-03T14:22:00Z
SO-1002,employee05@example.test,Starter,249.50,USD,2026-09-05
SO-1003,employee09@example.test,Enterprise,8400.00,USD,2026-09-08 09:10:00
`

function chunk<T>(items: T[], size: number): T[][] {
  const out: T[][] = []
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size))

  return out
}

function IssueList({ issues, duplicates }: { issues: RowIssue[]; duplicates: string[] }) {
  if (issues.length === 0 && duplicates.length === 0) return null

  return (
    <div className="space-y-2">
      {issues.length > 0 && (
        <Alert tone="warning" title={`${issues.length} row${issues.length === 1 ? '' : 's'} skipped`}>
          <ul className="mt-1 space-y-0.5 text-xs">
            {issues.slice(0, 6).map((issue, index) => (
              <li key={`${issue.line}-${issue.field}-${index}`}>
                line {issue.line} · <span className="font-medium">{issue.field}</span>: {issue.message}
              </li>
            ))}
            {issues.length > 6 && <li>…and {issues.length - 6} more</li>}
          </ul>
        </Alert>
      )}

      {duplicates.length > 0 && (
        <Alert tone="warning" title={`${duplicates.length} duplicate external_id removed`}>
          <p className="mt-1 text-xs">
            The API rejects a batch containing the same external_id twice, since the upsert result would depend on row
            order. Only the first occurrence was kept: {duplicates.slice(0, 5).join(', ')}
            {duplicates.length > 5 && ` +${duplicates.length - 5} more`}.
          </p>
        </Alert>
      )}
    </div>
  )
}

export function SalesImportPage() {
  const { track } = useJobs()
  const { can, user } = useAuth()
  const keyRef = useRef(newIdempotencyKey('sales'))
  const [source, setSource] = useState('csv-upload')
  const [parsing, setParsing] = useState(false)
  const [progress, setProgress] = useState(0)
  const [parsed, setParsed] = useState<ParseResult | null>(null)
  const [parseError, setParseError] = useState<string | null>(null)
  const [submitted, setSubmitted] = useState<string[]>([])
  const fileInput = useRef<HTMLInputElement>(null)

  const parseFile = useCallback((file: File) => {
    setParsing(true)
    setParsed(null)
    setParseError(null)
    setSubmitted([])
    setProgress(0)

    const worker = new Worker(new URL('./csv.worker.ts', import.meta.url), { type: 'module' })

    worker.onmessage = (event: MessageEvent<WorkerMessage>) => {
      const message = event.data

      if (message.type === 'progress') {
        setProgress(message.parsed)
        return
      }

      if (message.type === 'error') {
        setParseError(message.message)
        setParsing(false)
        worker.terminate()
        return
      }

      setParsed(message.result)
      setParsing(false)
      worker.terminate()
    }

    worker.onerror = (event) => {
      setParseError(event.message || 'Could not read the file.')
      setParsing(false)
      worker.terminate()
    }

    worker.postMessage({ file })
  }, [])

  const mutation = useMutation({
    mutationFn: async (rows: SalesRow[]) => {
      const batches = chunk(rows, SALES_IMPORT_MAX_ROWS)
      const requestIds: string[] = []

      /*
       * One idempotency key per batch, derived from a per-upload base.
       *
       * Deriving them rather than generating fresh ones means retrying a failed
       * upload of the same file replays the batches that already succeeded instead
       * of importing them twice.
       */
      const base = keyRef.current

      // Sequential, not Promise.all: a 20-batch file fired in parallel would trip
      // the per-client rate limit and give up half the work for no benefit.
      for (const [index, batch] of batches.entries()) {
        const accepted = await submitSalesImport(source, batch, `${base}-b${index}`)

        track({
          requestId: accepted.request_id,
          kind: 'sales',
          label:
            batches.length === 1
              ? `Sales import · ${integer(batch.length)} rows`
              : `Sales import ${index + 1}/${batches.length} · ${integer(batch.length)} rows`,
        })

        requestIds.push(accepted.request_id)
      }

      return requestIds
    },
    onSuccess: (requestIds) => {
      setSubmitted(requestIds)
      setParsed(null)
      // A new upload is a new operation, so rotate the base key.
      keyRef.current = newIdempotencyKey('sales')
      if (fileInput.current) fileInput.current.value = ''
    },
  })

  const rowCount = parsed?.rows.length ?? 0
  const batches = Math.ceil(rowCount / SALES_IMPORT_MAX_ROWS)

  const submitError = mutation.error
  const submitMessage =
    submitError instanceof ApiError
      ? submitError.isQueueUnavailable
        ? 'Could not queue the import — nothing was enqueued. Please retry.'
        : submitError.isRateLimited
          ? `Rate limited. Try again in ${submitError.retryAfter ?? 60}s.`
          : submitError.isForbidden
            ? 'Your role does not permit importing sales.'
            : submitError.message
      : submitError
        ? 'Submission failed.'
        : null

  if (!can(Ability.SalesImport)) {
    return (
      <>
        <PageHeader title="Import sales" />
        <Card>
          <Alert tone="info" title="Read-only access">
            Your role ({user?.role}) cannot import sales. You can still view committed records under Sales records.
          </Alert>
        </Card>
      </>
    )
  }

  return (
    <>
      <PageHeader
        title="Import sales"
        description="Published to the sales-import topic. The worker upserts on external_id, so a re-send corrects rows instead of double-counting revenue."
        actions={<Badge tone="info">async · sales-import</Badge>}
      />

      <div className="grid gap-6 lg:grid-cols-2 lg:items-start">
        <Card title="Upload a CSV" description="Parsed and validated in your browser before anything is sent.">
          <div className="space-y-4">
            <Field label="Source label" htmlFor="source" hint="Recorded on the request so you can trace where rows came from.">
              <Input id="source" value={source} onChange={(event) => setSource(event.target.value)} maxLength={60} />
            </Field>

            <Field
              label="CSV file"
              htmlFor="file"
              hint="Headers: external_id, rep_email, product, amount, currency, sold_at. Common aliases are accepted."
            >
              <input
                id="file"
                ref={fileInput}
                type="file"
                accept=".csv,text/csv"
                onChange={(event) => {
                  const file = event.target.files?.[0]
                  if (file) parseFile(file)
                }}
                className="block w-full text-sm text-slate-600 file:mr-3 file:rounded-md file:border-0 file:bg-slate-900 file:px-3 file:py-2 file:text-sm file:font-medium file:text-white hover:file:bg-slate-700"
              />
            </Field>

            {parsing && (
              <p className="flex items-center gap-2 text-sm text-slate-600">
                <Spinner className="size-4" />
                Parsing… {progress > 0 && `${integer(progress)} rows`}
              </p>
            )}

            {parseError && <Alert title="Could not parse the file">{parseError}</Alert>}

            <details className="text-xs text-slate-500">
              <summary className="cursor-pointer font-medium text-slate-700">Sample CSV</summary>
              <pre className="mt-2 overflow-x-auto rounded bg-slate-50 p-3 ring-1 ring-inset ring-slate-200">
                {SAMPLE_CSV}
              </pre>
            </details>
          </div>
        </Card>

        <Card title="Review and submit">
          {submitted.length > 0 && (
            <Alert tone="info" title={`${submitted.length} request${submitted.length === 1 ? '' : 's'} accepted`}>
              Follow progress in the Activity panel. Rows appear under Sales records once the worker commits them.
            </Alert>
          )}

          {!parsed && submitted.length === 0 && (
            <p className="py-8 text-center text-sm text-slate-500">
              Choose a CSV to see a validated preview here.
            </p>
          )}

          {parsed && (
            <div className="space-y-4">
              <dl className="grid grid-cols-2 gap-3">
                {[
                  ['Rows read', integer(parsed.totalLines)],
                  ['Valid rows', integer(rowCount)],
                  ['Total value', money(parsed.totalAmount)],
                  ['Requests', integer(batches)],
                ].map(([label, value]) => (
                  <div key={label} className="rounded-md bg-slate-50 px-3 py-2 ring-1 ring-inset ring-slate-200">
                    <dt className="text-xs text-slate-500">{label}</dt>
                    <dd className="mt-0.5 text-sm font-semibold tabular-nums text-slate-900">{value}</dd>
                  </div>
                ))}
              </dl>

              {batches > 1 && (
                <Alert tone="info" title={`Split into ${batches} requests`}>
                  The API accepts {integer(SALES_IMPORT_MAX_ROWS)} rows per request. Each batch is submitted separately
                  and tracked as its own job.
                </Alert>
              )}

              <IssueList issues={parsed.issues} duplicates={parsed.duplicates} />

              {submitMessage && <Alert>{submitMessage}</Alert>}

              {rowCount > 0 && (
                <div className="overflow-x-auto rounded-md ring-1 ring-inset ring-slate-200">
                  <table className="min-w-full divide-y divide-slate-200 text-xs">
                    <thead className="bg-slate-50">
                      <tr>
                        <th className="px-3 py-2 text-left font-semibold text-slate-500">external_id</th>
                        <th className="px-3 py-2 text-left font-semibold text-slate-500">rep_email</th>
                        <th className="px-3 py-2 text-right font-semibold text-slate-500">amount</th>
                        <th className="px-3 py-2 text-left font-semibold text-slate-500">sold_at</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-slate-100">
                      {parsed.rows.slice(0, 5).map((row) => (
                        <tr key={row.external_id}>
                          <td className="px-3 py-1.5 font-mono">{row.external_id}</td>
                          <td className="px-3 py-1.5">{row.rep_email}</td>
                          <td className="px-3 py-1.5 text-right tabular-nums">{money(row.amount, row.currency)}</td>
                          <td className="px-3 py-1.5 text-slate-500">{row.sold_at}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                  {rowCount > 5 && (
                    <p className="bg-slate-50 px-3 py-1.5 text-xs text-slate-500">
                      +{integer(rowCount - 5)} more rows
                    </p>
                  )}
                </div>
              )}

              <Button
                onClick={() => parsed && mutation.mutate(parsed.rows)}
                loading={mutation.isPending}
                disabled={rowCount === 0}
              >
                Queue {integer(rowCount)} rows
              </Button>
            </div>
          )}
        </Card>
      </div>
    </>
  )
}
