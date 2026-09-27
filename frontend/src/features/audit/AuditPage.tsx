/**
 * The tenant's audit trail.
 *
 * Payroll is financial data, so "who authorised this run" has to be answerable.
 * The worker records which pod did the arithmetic; this records which human asked
 * for it, and correlates to the async request via request_id.
 */
import { useState } from 'react'
import { Link } from 'react-router-dom'
import { keepPreviousData, useQuery } from '@tanstack/react-query'

import { fetchAuditLogs, queryKeys } from '../../api/endpoints'
import {
  Alert,
  Badge,
  Card,
  EmptyState,
  Field,
  PageHeader,
  Pagination,
  Select,
  Spinner,
  Table,
  Td,
  Th,
} from '../../components/ui'
import { dateTime } from '../../lib/format'

const ACTIONS = [
  'payroll.requested',
  'sales_import.requested',
  'auth.login.succeeded',
  'auth.login.failed',
  'auth.logout',
]

function outcomeTone(outcome: string) {
  if (outcome === 'success') return 'success' as const
  if (outcome === 'denied') return 'warning' as const

  return 'danger' as const
}

export function AuditPage() {
  const [page, setPage] = useState(1)
  const [action, setAction] = useState('')

  const query = useQuery({
    queryKey: queryKeys.auditLogs(page, action || undefined),
    queryFn: () => fetchAuditLogs({ page, per_page: 50, action: action || undefined }),
    placeholderData: keepPreviousData,
  })

  return (
    <>
      <PageHeader
        title="Audit trail"
        description="Append-only record of who did what, stored inside this tenant's schema so it is isolated with the rest of the tenant's data."
        actions={<Badge tone="neutral">append-only</Badge>}
      />

      <Card>
        <div className="mb-4 max-w-xs">
          <Field label="Action" htmlFor="action">
            <Select
              id="action"
              value={action}
              onChange={(event) => {
                setAction(event.target.value)
                setPage(1)
              }}
            >
              <option value="">All actions</option>
              {ACTIONS.map((value) => (
                <option key={value} value={value}>
                  {value}
                </option>
              ))}
            </Select>
          </Field>
        </div>

        {query.isError && <Alert title="Could not load the audit trail">{(query.error as Error).message}</Alert>}

        {query.isLoading && (
          <div className="flex justify-center py-12">
            <Spinner />
          </div>
        )}

        {query.data && query.data.data.length === 0 && (
          <EmptyState title="No audit entries" description="Actions are recorded here as they happen." />
        )}

        {query.data && query.data.data.length > 0 && (
          <>
            <Table caption="Audit trail">
              <thead>
                <tr>
                  <Th>When</Th>
                  <Th>Actor</Th>
                  <Th>Role</Th>
                  <Th>Action</Th>
                  <Th>Outcome</Th>
                  <Th>Request</Th>
                  <Th>Detail</Th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {query.data.data.map((entry) => (
                  <tr key={entry.id} className="hover:bg-slate-50">
                    <Td className="text-slate-500">{dateTime(entry.created_at)}</Td>
                    <Td>{entry.actor_email ?? '-'}</Td>
                    <Td>{entry.actor_role ?? '-'}</Td>
                    <Td className="font-mono text-xs">{entry.action}</Td>
                    <Td>
                      <Badge tone={outcomeTone(entry.outcome)}>{entry.outcome}</Badge>
                    </Td>
                    <Td className="font-mono text-xs text-slate-500">
                      {entry.request_id ? (
                        entry.action === 'payroll.requested' ? (
                          <Link
                            to={`/payroll/${entry.request_id}`}
                            className="underline decoration-slate-300 hover:decoration-slate-900"
                          >
                            {entry.request_id.slice(0, 8)}…
                          </Link>
                        ) : (
                          `${entry.request_id.slice(0, 8)}…`
                        )
                      ) : (
                        '-'
                      )}
                    </Td>
                    <Td className="max-w-xs truncate text-xs text-slate-500">
                      {/* Parameters, never payloads: the rows themselves live in
                          sales_records and would bloat the trail. */}
                      {entry.context ? JSON.stringify(entry.context) : '-'}
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
    </>
  )
}
