/**
 * Polls one job's status document until it reaches a terminal state.
 *
 * Renders nothing. Mounted by JobsProvider for each active job so polling is
 * independent of whether the Activity drawer happens to be open.
 */
import { useEffect } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'

import { ApiError } from '../api/client'
import { fetchRequestStatus, queryKeys } from '../api/endpoints'
import { useJobs } from './JobsProvider'
import type { Job } from './types'
import { isTerminal } from './types'

/**
 * Interval schedule.
 *
 * Tight at first because most jobs finish in under a second, then backing off:
 * a payroll run over thousands of employees is not going to finish in two
 * seconds, and continuing to poll every 2s spends the tenant's rate-limit budget
 * (600 req/min) on polling instead of real work.
 */
function intervalFor(attempts: number, retryAfterSeconds: number | null): number {
  const base = (retryAfterSeconds ?? 2) * 1000

  if (attempts < 8) return base // first ~16s
  if (attempts < 20) return Math.max(base, 5_000)

  return 15_000
}

export function JobPoller({ job }: { job: Job }) {
  const { update } = useJobs()
  const queryClient = useQueryClient()

  const query = useQuery({
    queryKey: queryKeys.requestStatus(job.requestId),
    queryFn: () => fetchRequestStatus(job.requestId),

    /*
     * `meta.terminal` comes from the API precisely so the client does not have to
     * hardcode which statuses are final; when the server says stop, stop.
     */
    refetchInterval: (query) => {
      const data = query.state.data
      if (data?.meta.terminal) return false

      return intervalFor(query.state.dataUpdateCount, data?.meta.retry_after_seconds ?? null)
    },

    // Hidden tabs stop polling. A background tab left open overnight should not
    // keep hitting the API.
    refetchIntervalInBackground: false,

    // A 404 means the request id is unknown for this tenant - retrying will not
    // change that. Anything else gets a couple of attempts.
    retry: (failureCount, error) => {
      if (error instanceof ApiError && (error.status === 404 || error.isUnauthenticated)) return false
      return failureCount < 3
    },

    staleTime: 0,
    gcTime: 5 * 60_000,
  })

  const doc = query.data?.data
  const status = doc?.status

  /* Push status changes back into the registry. */
  useEffect(() => {
    if (!doc || !status) return
    if (status === job.status && job.detail) return

    update(job.requestId, {
      status,
      detail: doc,
      error: doc.error ?? doc.last_error ?? undefined,
    })
  }, [doc, status, job.requestId, job.status, job.detail, update])

  /*
   * Invalidate the read models once, on completion. This is the only thing that
   * refreshes the payroll/sales lists after an async write - nothing polls MySQL.
   */
  useEffect(() => {
    if (!status || !isTerminal(status)) return

    if (status === 'COMPLETED') {
      if (job.kind === 'payroll') {
        void queryClient.invalidateQueries({ queryKey: ['payroll-runs'] })
        void queryClient.invalidateQueries({ queryKey: queryKeys.payrollRun(job.requestId) })
      } else {
        void queryClient.invalidateQueries({ queryKey: ['sales-records'] })
        // Imported sales feed the next payroll's commission, and employees are
        // cached for 60s, so refresh both views too.
        void queryClient.invalidateQueries({ queryKey: ['employees'] })
      }
    }
  }, [status, job.kind, job.requestId, queryClient])

  /* A 404 for a tracked job means it is gone server-side; stop following it. */
  useEffect(() => {
    if (query.error instanceof ApiError && query.error.status === 404) {
      update(job.requestId, {
        status: 'FAILED',
        error: 'The server no longer knows about this request.',
      })
    }
  }, [query.error, job.requestId, update])

  return null
}
