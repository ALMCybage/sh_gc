/**
 * Persistent panel listing every in-flight and recently finished async request.
 *
 * This is the piece that makes the Pub/Sub architecture legible. Without it every
 * submit form has to invent its own progress affordance, and a user who navigates
 * away from a form loses all sight of the work they started.
 */
import { useEffect, useRef } from 'react'
import { Link } from 'react-router-dom'

import { Badge, Button, EmptyState } from '../components/ui'
import { StatusBadge } from '../components/StatusBadge'
import { duration, integer, money, relativeTime } from '../lib/format'
import { useJobs } from './JobsProvider'
import type { Job } from './types'
import { isTerminal } from './types'

function PayrollSummary({ job }: { job: Job }) {
  const detail = job.detail
  if (!detail) return null

  const currency = typeof detail.currency === 'string' ? detail.currency : 'USD'

  return (
    <dl className="mt-2 grid grid-cols-2 gap-x-4 gap-y-1 text-xs text-slate-600">
      <Stat label="Employees" value={integer(Number(detail.employee_count ?? 0))} />
      <Stat label="Net total" value={money(Number(detail.net_total ?? 0), currency)} />
      <Stat label="Commission" value={money(Number(detail.commission_total ?? 0), currency)} />
      <Stat label="Worker time" value={duration(Number(detail.duration_ms ?? 0))} />
    </dl>
  )
}

function SalesSummary({ job }: { job: Job }) {
  const detail = job.detail
  if (!detail) return null

  const currency = typeof detail.currency === 'string' ? detail.currency : 'USD'
  const unmatched = detail.unmatched_rep_emails ?? []

  return (
    <>
      <dl className="mt-2 grid grid-cols-2 gap-x-4 gap-y-1 text-xs text-slate-600">
        <Stat label="Rows received" value={integer(Number(detail.rows_received ?? 0))} />
        <Stat label="Rows written" value={integer(Number(detail.rows_written ?? 0))} />
        <Stat label="Total" value={money(Number(detail.total_amount ?? 0), currency)} />
        <Stat label="Worker time" value={duration(Number(detail.duration_ms ?? 0))} />
      </dl>

      {/* The rows were stored but are not linked to an employee, so they will not
          count toward commission. Silent data problems deserve to be loud. */}
      {unmatched.length > 0 && (
        <p className="mt-2 rounded bg-amber-50 px-2 py-1.5 text-xs text-amber-900 ring-1 ring-inset ring-amber-200">
          {unmatched.length} row{unmatched.length === 1 ? '' : 's'} stored without an employee link:{' '}
          <span className="font-medium">{unmatched.slice(0, 3).join(', ')}</span>
          {unmatched.length > 3 && ` +${unmatched.length - 3} more`}. They will not earn commission until the rep
          matches an employee email.
        </p>
      )}
    </>
  )
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between gap-2">
      <dt className="text-slate-500">{label}</dt>
      <dd className="font-medium tabular-nums text-slate-800">{value}</dd>
    </div>
  )
}

function JobRow({ job }: { job: Job }) {
  const attempt = Number(job.detail?.delivery_attempt ?? 0)

  return (
    <li className="rounded-md bg-white p-3 ring-1 ring-slate-200">
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="truncate text-sm font-medium text-slate-900">{job.label}</p>
          <p className="mt-0.5 font-mono text-[11px] text-slate-400">{job.requestId.slice(0, 18)}…</p>
        </div>
        <StatusBadge status={job.status} />
      </div>

      <p className="mt-1.5 text-xs text-slate-500">
        submitted {relativeTime(job.submittedAt)}
        {job.detail?.worker ? ` · ${String(job.detail.worker)}` : ''}
        {attempt > 1 ? ` · attempt ${attempt}` : ''}
      </p>

      {job.status === 'COMPLETED' &&
        (job.kind === 'payroll' ? <PayrollSummary job={job} /> : <SalesSummary job={job} />)}

      {job.status === 'FAILED' && (
        <p className="mt-2 rounded bg-red-50 px-2 py-1.5 text-xs text-red-800 ring-1 ring-inset ring-red-200">
          {job.error ?? 'The worker could not complete this request.'}
        </p>
      )}

      {job.status === 'COMPLETED' && job.kind === 'payroll' && (
        <Link
          to={`/payroll/${job.requestId}`}
          className="mt-2 inline-block text-xs font-medium text-slate-900 underline decoration-slate-300 hover:decoration-slate-900"
        >
          View payroll run
        </Link>
      )}

      {job.status === 'COMPLETED' && job.kind === 'sales' && (
        <Link
          to={`/sales/records?request_id=${job.requestId}`}
          className="mt-2 inline-block text-xs font-medium text-slate-900 underline decoration-slate-300 hover:decoration-slate-900"
        >
          View imported rows
        </Link>
      )}
    </li>
  )
}

export function ActivityDrawer({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { jobs, activeCount, clearFinished } = useJobs()
  const panelRef = useRef<HTMLDivElement>(null)

  // Escape closes, and focus moves into the panel so keyboard users are not
  // stranded behind it.
  useEffect(() => {
    if (!open) return

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose()
    }

    window.addEventListener('keydown', onKeyDown)
    panelRef.current?.focus()

    return () => window.removeEventListener('keydown', onKeyDown)
  }, [open, onClose])

  if (!open) return null

  const finished = jobs.filter((job) => isTerminal(job.status))

  return (
    <div className="fixed inset-0 z-40 flex justify-end">
      <button
        type="button"
        aria-label="Close activity panel"
        onClick={onClose}
        className="absolute inset-0 bg-slate-900/20"
      />

      <div
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-label="Activity"
        tabIndex={-1}
        className="relative flex h-full w-full max-w-md flex-col bg-slate-50 shadow-xl outline-none"
      >
        <header className="flex items-center justify-between border-b border-slate-200 bg-white px-5 py-4">
          <div className="flex items-center gap-2">
            <h2 className="text-sm font-semibold text-slate-900">Activity</h2>
            {activeCount > 0 && <Badge tone="info">{activeCount} running</Badge>}
          </div>
          <div className="flex items-center gap-2">
            {finished.length > 0 && (
              <Button variant="ghost" onClick={clearFinished}>
                Clear finished
              </Button>
            )}
            <Button variant="secondary" onClick={onClose}>
              Close
            </Button>
          </div>
        </header>

        <div className="flex-1 overflow-y-auto p-4">
          {jobs.length === 0 ? (
            <EmptyState
              title="Nothing running"
              description="Payroll calculations and sales imports are processed asynchronously by the Go worker pool. Anything you submit shows up here until it finishes."
            />
          ) : (
            <ul className="space-y-3">
              {jobs.map((job) => (
                <JobRow key={job.requestId} job={job} />
              ))}
            </ul>
          )}
        </div>

        <footer className="border-t border-slate-200 bg-white px-5 py-3 text-xs text-slate-500">
          Status is read from Firestore. Polling backs off automatically and pauses while this tab is hidden.
        </footer>
      </div>
    </div>
  )
}
