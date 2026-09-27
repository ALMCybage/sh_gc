/**
 * Three-state detail view, and the states matter.
 *
 * `GET /api/v1/payroll/calculations/{requestId}` answers 404 while the worker has
 * not committed yet, and 404 also means "never will" once the job has failed.
 * Rendering a bare "Not found" for either would be wrong, so this page decides
 * what to show from the *status document* first, and only asks for the run once
 * the job is known to have completed.
 */
import { Link, useParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'

import { ApiError } from '../../api/client'
import { fetchPayrollRun, fetchRequestStatus, queryKeys } from '../../api/endpoints'
import {
  Alert,
  Badge,
  Card,
  EmptyState,
  PageHeader,
  Spinner,
  Table,
  Td,
  Th,
} from '../../components/ui'
import { StatusBadge } from '../../components/StatusBadge'
import { date, dateTime, duration, integer, money } from '../../lib/format'
import { isTerminal } from '../../jobs/types'

function StatusTimeline({ requestId }: { requestId: string }) {
  const query = useQuery({
    queryKey: queryKeys.requestStatus(requestId),
    queryFn: () => fetchRequestStatus(requestId),
    refetchInterval: (q) => (q.state.data?.meta.terminal ? false : 2000),
    refetchIntervalInBackground: false,
    retry: (count, error) => !(error instanceof ApiError && error.status === 404) && count < 2,
  })

  if (query.isLoading) {
    return (
      <div className="flex justify-center py-8">
        <Spinner />
      </div>
    )
  }

  if (query.error instanceof ApiError && query.error.status === 404) {
    return (
      <Alert tone="warning" title="Unknown request">
        This tenant has no record of <span className="font-mono text-xs">{requestId}</span>. Status documents are
        partitioned per tenant, so a request submitted by another tenant is invisible here.
      </Alert>
    )
  }

  const doc = query.data?.data
  if (!doc) return null

  const rows: Array<[string, string]> = [
    ['Status', doc.status],
    ['Event type', String(doc.event_type ?? '-')],
    ['Topic', String(doc.topic ?? '-')],
    ['Pub/Sub message', String(doc.message_id ?? '-')],
    ['Accepted', dateTime(doc.created_at)],
    ['Worker started', dateTime(doc.started_at)],
    ['Worker', String(doc.worker ?? doc.processed_by ?? '-')],
    ['Delivery attempt', doc.delivery_attempt ? String(doc.delivery_attempt) : '-'],
    ['Queue lag', doc.queue_lag_ms === undefined ? '-' : duration(doc.queue_lag_ms)],
    ['Finished', dateTime(doc.completed_at ?? doc.failed_at)],
  ]

  return (
    <div className="space-y-4">
      <div className="flex items-center gap-2">
        <StatusBadge status={doc.status} />
        {!isTerminal(doc.status) && <span className="text-xs text-slate-500">polling every 2s…</span>}
      </div>

      {doc.status === 'FAILED' && (
        <Alert title="The worker could not complete this request">
          {doc.error ?? doc.last_error ?? 'No further detail was recorded.'}
        </Alert>
      )}

      <dl className="grid gap-x-6 gap-y-2 text-sm sm:grid-cols-2">
        {rows.map(([label, value]) => (
          <div key={label} className="flex justify-between gap-3 border-b border-slate-100 pb-1.5">
            <dt className="text-slate-500">{label}</dt>
            <dd className="text-right font-medium text-slate-800">{value}</dd>
          </div>
        ))}
      </dl>
    </div>
  )
}

function CommittedRun({ requestId }: { requestId: string }) {
  const query = useQuery({
    queryKey: queryKeys.payrollRun(requestId),
    queryFn: () => fetchPayrollRun(requestId),
    retry: (count, error) => !(error instanceof ApiError && error.status === 404) && count < 2,
  })

  if (query.isLoading) {
    return (
      <div className="flex justify-center py-12">
        <Spinner />
      </div>
    )
  }

  if (query.error instanceof ApiError && query.error.status === 404) {
    return (
      <EmptyState
        title="Not committed yet"
        description="The worker has not written this run to Cloud SQL. The status panel above shows where it is."
      />
    )
  }

  if (query.isError) {
    return <Alert title="Could not load the run">{(query.error as Error).message}</Alert>
  }

  const run = query.data
  if (!run) return null

  return (
    <div className="space-y-6">
      <dl className="grid grid-cols-2 gap-4 sm:grid-cols-4">
        {[
          ['Employees', integer(run.employee_count)],
          ['Gross', money(run.gross_total, run.currency)],
          ['Commission', money(run.commission_total, run.currency)],
          ['Tax', money(run.tax_total, run.currency)],
        ].map(([label, value]) => (
          <div key={label} className="rounded-md bg-slate-50 px-3 py-2 ring-1 ring-inset ring-slate-200">
            <dt className="text-xs text-slate-500">{label}</dt>
            <dd className="mt-0.5 text-sm font-semibold tabular-nums text-slate-900">{value}</dd>
          </div>
        ))}
      </dl>

      <div className="rounded-md bg-slate-900 px-4 py-3 text-white">
        <p className="text-xs text-slate-300">Net total</p>
        <p className="text-lg font-semibold tabular-nums">{money(run.net_total, run.currency)}</p>
      </div>

      <Table caption="Payroll lines">
        <thead>
          <tr>
            <Th>Employee</Th>
            <Th>Department</Th>
            <Th numeric>Gross</Th>
            <Th numeric>Commission</Th>
            <Th numeric>Tax</Th>
            <Th numeric>Net</Th>
          </tr>
        </thead>
        <tbody className="divide-y divide-slate-100">
          {run.lines.map((line) => (
            <tr key={line.id} className="hover:bg-slate-50">
              <Td>
                {line.employee ? (
                  <>
                    <span className="font-mono text-xs text-slate-500">{line.employee.employee_code}</span>{' '}
                    {line.employee.first_name} {line.employee.last_name}
                  </>
                ) : (
                  `#${line.employee_id}`
                )}
              </Td>
              <Td>{line.employee?.department ?? '-'}</Td>
              <Td numeric>{money(line.gross_amount, run.currency)}</Td>
              <Td numeric>{money(line.commission_amount, run.currency)}</Td>
              <Td numeric>{money(line.tax_amount, run.currency)}</Td>
              <Td numeric className="font-medium">
                {money(line.net_amount, run.currency)}
              </Td>
            </tr>
          ))}
        </tbody>
      </Table>

      <p className="text-xs text-slate-500">
        Period {date(run.period_start)} → {date(run.period_end)} · computed by{' '}
        <span className="font-mono">{run.processed_by ?? 'unknown'}</span> in {duration(run.duration_ms)}
      </p>
    </div>
  )
}

export function RunDetailPage() {
  const { requestId = '' } = useParams()

  return (
    <>
      <PageHeader
        title="Payroll run"
        description={requestId}
        actions={
          <Link
            to="/payroll"
            className="text-sm font-medium text-slate-900 underline decoration-slate-300 hover:decoration-slate-900"
          >
            Back to payroll
          </Link>
        }
      />

      <div className="grid gap-6 lg:grid-cols-[minmax(0,360px)_minmax(0,1fr)] lg:items-start">
        <Card title="Request status" description="Read from Firestore" actions={<Badge tone="neutral">sync</Badge>}>
          <StatusTimeline requestId={requestId} />
        </Card>

        <Card title="Committed result" description="Read from this tenant's MySQL schema">
          <CommittedRun requestId={requestId} />
        </Card>
      </div>
    </>
  )
}
