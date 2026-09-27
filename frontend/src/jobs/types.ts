import type { RequestStatusDoc, RequestStatusValue } from '../api/schemas'

export type JobKind = 'payroll' | 'sales'

/**
 * A submitted async request the UI is following.
 *
 * The `202` from Laravel gives us `requestId`; everything else is filled in as
 * the status document is polled. This is the only place the UI records the fact
 * that a write is in flight, which is what keeps every submit form identical.
 */
export type Job = {
  requestId: string
  kind: JobKind
  label: string
  status: RequestStatusValue
  submittedAt: number
  /** Fields the worker merged into the Firestore document once it finished. */
  detail?: RequestStatusDoc
  error?: string
}

export const TERMINAL_STATUSES: RequestStatusValue[] = ['COMPLETED', 'FAILED']

export function isTerminal(status: RequestStatusValue): boolean {
  return TERMINAL_STATUSES.includes(status)
}
