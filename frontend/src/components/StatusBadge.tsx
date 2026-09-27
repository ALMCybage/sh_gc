import { Badge, Spinner, type BadgeTone } from './ui'
import type { RequestStatusValue } from '../api/schemas'

const tones: Record<RequestStatusValue, BadgeTone> = {
  ACCEPTED: 'neutral',
  QUEUED: 'info',
  PROCESSING: 'warning',
  COMPLETED: 'success',
  FAILED: 'danger',
}

const labels: Record<RequestStatusValue, string> = {
  ACCEPTED: 'Accepted',
  QUEUED: 'Queued',
  PROCESSING: 'Processing',
  COMPLETED: 'Completed',
  FAILED: 'Failed',
}

export function StatusBadge({ status }: { status: RequestStatusValue }) {
  const inFlight = status === 'QUEUED' || status === 'PROCESSING' || status === 'ACCEPTED'

  return (
    <Badge tone={tones[status]}>
      <span className="inline-flex items-center gap-1.5">
        {inFlight && <Spinner className="size-3" />}
        {labels[status]}
      </span>
    </Badge>
  )
}
