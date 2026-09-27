/**
 * Registry of in-flight async requests.
 *
 * Every `202` from the API lands here, and one poller per job watches the status
 * document until it reaches a terminal state. Two things this deliberately avoids:
 *
 *   - a setInterval inside each submit form, which produces N uncoordinated
 *     pollers and keeps running after the component unmounts;
 *   - refetching the payroll/sales lists on a timer. The lists are invalidated
 *     exactly once, when a job completes.
 */
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react'
import { useQueryClient } from '@tanstack/react-query'

import type { Job, JobKind } from './types'
import { isTerminal } from './types'
import type { RequestStatusDoc, RequestStatusValue } from '../api/schemas'
import { JobPoller } from './JobPoller'

const STORAGE_KEY = 'sequifi.jobs.v1'
const CHANNEL_NAME = 'sequifi-jobs'
const MAX_JOBS = 25

type JobsContextValue = {
  jobs: Job[]
  activeCount: number
  track: (input: { requestId: string; kind: JobKind; label: string }) => void
  update: (requestId: string, patch: Partial<Job>) => void
  dismiss: (requestId: string) => void
  clearFinished: () => void
}

const JobsContext = createContext<JobsContextValue | null>(null)

function load(): Job[] {
  try {
    const raw = sessionStorage.getItem(STORAGE_KEY)
    if (!raw) return []

    const parsed = JSON.parse(raw) as Job[]
    return Array.isArray(parsed) ? parsed : []
  } catch {
    return []
  }
}

function persist(jobs: Job[]) {
  try {
    sessionStorage.setItem(STORAGE_KEY, JSON.stringify(jobs.slice(0, MAX_JOBS)))
  } catch {
    // A full or unavailable sessionStorage must never break the app; the only
    // consequence is that a refresh loses the job list.
  }
}

export function JobsProvider({ children }: { children: ReactNode }) {
  /*
   * sessionStorage rather than useState alone: refreshing the page mid-payroll
   * must not orphan the request. On mount the poller picks straight back up.
   * sessionStorage (not localStorage) because the list is per browser tab session
   * and should not outlive it.
   */
  const [jobs, setJobs] = useState<Job[]>(() => load())
  const channelRef = useRef<BroadcastChannel | null>(null)

  useEffect(() => {
    persist(jobs)
  }, [jobs])

  /*
   * Mirror job state across tabs. Two tabs open on the same tenant each poll
   * their own jobs, but a job submitted in one tab shows up (and finishes) in the
   * other, and a completion in either tab invalidates both tabs' lists.
   */
  useEffect(() => {
    if (typeof BroadcastChannel === 'undefined') return

    const channel = new BroadcastChannel(CHANNEL_NAME)
    channelRef.current = channel

    channel.onmessage = (event: MessageEvent<{ type: 'sync'; jobs: Job[] }>) => {
      if (event.data?.type !== 'sync') return

      setJobs((current) => {
        const merged = new Map(current.map((job) => [job.requestId, job]))

        for (const incoming of event.data.jobs) {
          const existing = merged.get(incoming.requestId)
          // Last writer wins per job, but never regress a terminal state.
          if (!existing || !isTerminal(existing.status)) merged.set(incoming.requestId, incoming)
        }

        return [...merged.values()].sort((a, b) => b.submittedAt - a.submittedAt)
      })
    }

    return () => {
      channel.close()
      channelRef.current = null
    }
  }, [])

  const broadcast = useCallback((next: Job[]) => {
    channelRef.current?.postMessage({ type: 'sync', jobs: next })
  }, [])

  const track = useCallback<JobsContextValue['track']>(
    ({ requestId, kind, label }) => {
      setJobs((current) => {
        if (current.some((job) => job.requestId === requestId)) return current

        const next = [
          { requestId, kind, label, status: 'QUEUED' as RequestStatusValue, submittedAt: Date.now() },
          ...current,
        ].slice(0, MAX_JOBS)

        broadcast(next)
        return next
      })
    },
    [broadcast],
  )

  const update = useCallback<JobsContextValue['update']>(
    (requestId, patch) => {
      setJobs((current) => {
        const next = current.map((job) => (job.requestId === requestId ? { ...job, ...patch } : job))
        broadcast(next)
        return next
      })
    },
    [broadcast],
  )

  const dismiss = useCallback<JobsContextValue['dismiss']>(
    (requestId) => {
      setJobs((current) => {
        const next = current.filter((job) => job.requestId !== requestId)
        broadcast(next)
        return next
      })
    },
    [broadcast],
  )

  const clearFinished = useCallback(() => {
    setJobs((current) => {
      const next = current.filter((job) => !isTerminal(job.status))
      broadcast(next)
      return next
    })
  }, [broadcast])

  const activeCount = useMemo(() => jobs.filter((job) => !isTerminal(job.status)).length, [jobs])

  const value = useMemo<JobsContextValue>(
    () => ({ jobs, activeCount, track, update, dismiss, clearFinished }),
    [jobs, activeCount, track, update, dismiss, clearFinished],
  )

  return (
    <JobsContext.Provider value={value}>
      {children}
      {/* One poller component per active job. Mounting them here rather than in
          the drawer means polling continues while the drawer is closed. */}
      {jobs
        .filter((job) => !isTerminal(job.status))
        .map((job) => (
          <JobPoller key={job.requestId} job={job} />
        ))}
    </JobsContext.Provider>
  )
}

export function useJobs(): JobsContextValue {
  const context = useContext(JobsContext)
  if (!context) throw new Error('useJobs must be used inside <JobsProvider>')

  return context
}

/**
 * Hook for submit forms: hand it the 202 payload and it starts tracking.
 * Also exposes the queryClient so completion handlers can invalidate reads.
 */
export function useTrackJob() {
  const { track } = useJobs()
  const queryClient = useQueryClient()

  return useCallback(
    (requestId: string, kind: JobKind, label: string) => {
      track({ requestId, kind, label })
      return queryClient
    },
    [track, queryClient],
  )
}

export type { RequestStatusDoc }
