/**
 * Request type 1: submit a payroll calculation (async), and read back the runs
 * the Go worker has committed.
 */
import { useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { keepPreviousData, useMutation, useQuery } from '@tanstack/react-query'

import { ApiError, newIdempotencyKey } from '../../api/client'
import { Ability } from '../../api/abilities'
import { useAuth } from '../../auth/AuthProvider'
import { fetchPayrollRuns, queryKeys, submitPayroll } from '../../api/endpoints'
import { payrollRequestSchema, type PayrollRequest } from '../../api/schemas'
import {
  Alert,
  Badge,
  Button,
  Card,
  EmptyState,
  Field,
  Input,
  PageHeader,
  Pagination,
  Spinner,
  Table,
  Td,
  Th,
} from '../../components/ui'
import { useJobs } from '../../jobs/JobsProvider'
import { date, dateTime, duration, integer, money } from '../../lib/format'

function defaultPeriod() {
  const now = new Date()
  const start = new Date(now.getFullYear(), now.getMonth(), 1)
  const end = new Date(now.getFullYear(), now.getMonth() + 1, 0)
  const iso = (d: Date) => d.toISOString().slice(0, 10)

  return { start: iso(start), end: iso(end) }
}

function SubmitForm() {
  const { track } = useJobs()
  const [accepted, setAccepted] = useState<string | null>(null)
  const period = defaultPeriod()

  /*
   * One key per attempt, held in a ref so it survives re-renders.
   *
   * A retry after a failure reuses it (the server replays the original 202 rather
   * than queueing a second run); a *successful* submit rotates it, because the
   * next click is a genuinely new operation.
   */
  const keyRef = useRef(newIdempotencyKey('payroll'))

  const {
    register,
    handleSubmit,
    setError,
    watch,
    formState: { errors },
  } = useForm<PayrollRequest>({
    resolver: zodResolver(payrollRequestSchema),
    defaultValues: {
      period_start: period.start,
      period_end: period.end,
      include_commission: true,
      tax_rate: 0.22,
      notes: '',
    },
  })

  const mutation = useMutation({
    mutationFn: (values: PayrollRequest) => submitPayroll(values, keyRef.current),
    onSuccess: (result, variables) => {
      // The 202 hands the request to the job registry; nothing else here waits.
      track({
        requestId: result.request_id,
        kind: 'payroll',
        label: `Payroll ${variables.period_start} → ${variables.period_end}`,
      })
      setAccepted(result.request_id)

      // Rotate the key: the next submit is a new operation, not a retry.
      keyRef.current = newIdempotencyKey('payroll')
    },
  })

  const onSubmit = handleSubmit(async (values) => {
    setAccepted(null)

    try {
      await mutation.mutateAsync({ ...values, notes: values.notes || undefined })
    } catch (error) {
      if (error instanceof ApiError && error.isValidation) {
        for (const [field, messages] of Object.entries(error.fieldErrors)) {
          setError(field as keyof PayrollRequest, { message: messages[0] })
        }
        return
      }

      // 503 means the publish failed, so nothing was enqueued: retrying is safe
      // and cannot produce a duplicate run.
      if (error instanceof ApiError && error.isQueueUnavailable) {
        setError('root', { message: 'Could not queue the run — nothing was enqueued. Please retry.' })
        return
      }

      if (error instanceof ApiError && error.isRateLimited) {
        setError('root', { message: `Rate limited. Try again in ${error.retryAfter ?? 60}s.` })
        return
      }

      // The first request carrying this key is still running, or the key was
      // reused with different data. Either way, do not resubmit.
      if (error instanceof ApiError && error.isConflict) {
        setError('root', { message: error.message })
        return
      }

      if (error instanceof ApiError && error.isForbidden) {
        setError('root', { message: 'Your role does not permit running payroll.' })
        return
      }

      setError('root', { message: error instanceof ApiError ? error.message : 'Submission failed.' })
    }
  })

  const taxRate = watch('tax_rate')

  return (
    <Card
      title="Run payroll"
      description="Published to the payroll-calc-events topic. The web tier returns immediately; a Go worker does the arithmetic."
    >
      <form onSubmit={onSubmit} className="space-y-4" noValidate>
        {errors.root && <Alert>{errors.root.message}</Alert>}

        {accepted && (
          <Alert tone="info" title="Accepted for processing">
            Request <span className="font-mono text-xs">{accepted}</span> is queued. Watch it in the Activity panel.
          </Alert>
        )}

        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Period start" htmlFor="period_start" error={errors.period_start?.message}>
            <Input id="period_start" type="date" invalid={Boolean(errors.period_start)} {...register('period_start')} />
          </Field>

          <Field label="Period end" htmlFor="period_end" error={errors.period_end?.message}>
            <Input id="period_end" type="date" invalid={Boolean(errors.period_end)} {...register('period_end')} />
          </Field>
        </div>

        <Field
          label={`Tax rate — ${(taxRate * 100).toFixed(1)}%`}
          htmlFor="tax_rate"
          error={errors.tax_rate?.message}
          hint="The API accepts 0-60%. The slider cannot leave that range, so this never round-trips a 422."
        >
          <input
            id="tax_rate"
            type="range"
            min={0}
            max={0.6}
            step={0.005}
            className="w-full accent-slate-900"
            {...register('tax_rate', { valueAsNumber: true })}
          />
        </Field>

        <label className="flex items-start gap-2 text-sm text-slate-700">
          <input type="checkbox" className="mt-0.5 size-4 rounded border-slate-300" {...register('include_commission')} />
          <span>
            Include commission
            <span className="block text-xs text-slate-500">
              The worker sums each rep's imported sales inside the period and applies their commission rate.
            </span>
          </span>
        </label>

        <Field label="Notes" htmlFor="notes" error={errors.notes?.message}>
          <Input id="notes" placeholder="Optional" invalid={Boolean(errors.notes)} {...register('notes')} />
        </Field>

        <Button type="submit" loading={mutation.isPending}>
          Queue payroll run
        </Button>
      </form>
    </Card>
  )
}

function RunsTable() {
  const [page, setPage] = useState(1)

  const query = useQuery({
    queryKey: queryKeys.payrollRuns(page),
    queryFn: () => fetchPayrollRuns({ page, per_page: 15 }),
    placeholderData: keepPreviousData,
  })

  return (
    <Card
      title="Committed runs"
      description="Rows the Go worker wrote to payroll_runs. Refreshed automatically when a job completes — nothing polls MySQL."
    >
      {query.isError && <Alert title="Could not load payroll runs">{(query.error as Error).message}</Alert>}

      {query.isLoading && (
        <div className="flex justify-center py-12">
          <Spinner />
        </div>
      )}

      {query.data && query.data.data.length === 0 && (
        <EmptyState
          title="No payroll runs yet"
          description="Queue a run above. It will appear here once the worker commits it to Cloud SQL."
        />
      )}

      {query.data && query.data.data.length > 0 && (
        <>
          <Table caption="Committed payroll runs">
            <thead>
              <tr>
                <Th>Period</Th>
                <Th numeric>Employees</Th>
                <Th numeric>Gross</Th>
                <Th numeric>Commission</Th>
                <Th numeric>Tax</Th>
                <Th numeric>Net</Th>
                <Th>Worker</Th>
                <Th numeric>Took</Th>
                <Th>Committed</Th>
                <Th> </Th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {query.data.data.map((run) => (
                <tr key={run.id} className="hover:bg-slate-50">
                  <Td>
                    {date(run.period_start)} → {date(run.period_end)}
                  </Td>
                  <Td numeric>{integer(run.employee_count)}</Td>
                  <Td numeric>{money(run.gross_total, run.currency)}</Td>
                  <Td numeric>{money(run.commission_total, run.currency)}</Td>
                  <Td numeric>{money(run.tax_total, run.currency)}</Td>
                  <Td numeric className="font-medium">
                    {money(run.net_total, run.currency)}
                  </Td>
                  <Td className="font-mono text-xs text-slate-500">{run.processed_by ?? '-'}</Td>
                  <Td numeric>{duration(run.duration_ms)}</Td>
                  <Td className="text-slate-500">{dateTime(run.created_at)}</Td>
                  <Td>
                    <Link
                      to={`/payroll/${run.request_id}`}
                      className="text-xs font-medium text-slate-900 underline decoration-slate-300 hover:decoration-slate-900"
                    >
                      Detail
                    </Link>
                  </Td>
                </tr>
              ))}
            </tbody>
          </Table>

          <Pagination
            page={query.data.current_page}
            lastPage={query.data.last_page}
            total={query.data.total}
            from={query.data.from}
            to={query.data.to}
            busy={query.isFetching}
            onChange={setPage}
          />
        </>
      )}
    </Card>
  )
}

export function PayrollPage() {
  const { can, user } = useAuth()
  const mayRun = can(Ability.PayrollRun)

  return (
    <>
      <PageHeader
        title="Payroll"
        description="Calculations run in the Go worker pool, not in a web pod. Submitting returns HTTP 202 with a request id you can follow."
        actions={<Badge tone="info">async · payroll-calc-events</Badge>}
      />

      <div className="grid gap-6 lg:grid-cols-[minmax(0,380px)_minmax(0,1fr)] lg:items-start">
        {/* Hidden rather than disabled: a control that cannot ever work is noise.
            The route is gated server-side regardless. */}
        {mayRun ? (
          <SubmitForm />
        ) : (
          <Card title="Run payroll">
            <Alert tone="info" title="Read-only access">
              Your role ({user?.role}) can view payroll runs but not start one. Running payroll is limited to owners
              and admins because it is the action that moves money.
            </Alert>
          </Card>
        )}
        <RunsTable />
      </div>
    </>
  )
}
