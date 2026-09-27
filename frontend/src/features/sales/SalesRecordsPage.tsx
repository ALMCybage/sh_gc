import { useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { keepPreviousData, useQuery } from '@tanstack/react-query'

import { fetchSalesRecords, queryKeys } from '../../api/endpoints'
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
import { dateTime, money } from '../../lib/format'

export function SalesRecordsPage() {
  // The request_id lives in the URL so the "View imported rows" link from the
  // Activity panel is shareable and survives a refresh.
  const [searchParams, setSearchParams] = useSearchParams()
  const requestId = searchParams.get('request_id') ?? undefined

  const [page, setPage] = useState(1)
  const [repEmail, setRepEmail] = useState('')
  const [appliedRep, setAppliedRep] = useState('')

  const query = useQuery({
    queryKey: [...queryKeys.salesRecords(page, requestId), appliedRep],
    queryFn: () =>
      fetchSalesRecords({
        page,
        per_page: 25,
        request_id: requestId,
        rep_email: appliedRep || undefined,
      }),
    placeholderData: keepPreviousData,
  })

  return (
    <>
      <PageHeader
        title="Sales records"
        description="Rows the Go worker upserted into this tenant's sales_records table. These feed commission on the next payroll run."
        actions={requestId && <Badge tone="info">filtered by request</Badge>}
      />

      <Card>
        <div className="mb-4 flex flex-wrap items-end gap-3">
          <div className="min-w-56 flex-1">
            <Field label="Rep email" htmlFor="rep_email">
              <Input
                id="rep_email"
                type="email"
                placeholder="employee01@example.test"
                value={repEmail}
                onChange={(event) => setRepEmail(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') {
                    setAppliedRep(repEmail.trim())
                    setPage(1)
                  }
                }}
              />
            </Field>
          </div>

          <Button
            variant="secondary"
            onClick={() => {
              setAppliedRep(repEmail.trim())
              setPage(1)
            }}
          >
            Filter
          </Button>

          {(appliedRep || requestId) && (
            <Button
              variant="ghost"
              onClick={() => {
                setRepEmail('')
                setAppliedRep('')
                setPage(1)
                setSearchParams({})
              }}
            >
              Clear filters
            </Button>
          )}
        </div>

        {query.isError && <Alert title="Could not load sales records">{(query.error as Error).message}</Alert>}

        {query.isLoading && (
          <div className="flex justify-center py-12">
            <Spinner />
          </div>
        )}

        {query.data && query.data.data.length === 0 && (
          <EmptyState
            title="No sales records"
            description={
              requestId
                ? 'The worker has not committed this import yet, or it failed. Check the Activity panel.'
                : 'Import a CSV to populate this table.'
            }
          />
        )}

        {query.data && query.data.data.length > 0 && (
          <>
            <Table caption="Sales records">
              <thead>
                <tr>
                  <Th>External ID</Th>
                  <Th>Rep</Th>
                  <Th>Product</Th>
                  <Th numeric>Amount</Th>
                  <Th>Sold at</Th>
                  <Th>Linked employee</Th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {query.data.data.map((record) => (
                  <tr key={record.id} className="hover:bg-slate-50">
                    <Td className="font-mono text-xs">{record.external_id}</Td>
                    <Td className="text-slate-600">{record.rep_email ?? '-'}</Td>
                    <Td>{record.product ?? '-'}</Td>
                    <Td numeric>{money(record.amount, record.currency)}</Td>
                    <Td className="text-slate-500">{dateTime(record.sold_at)}</Td>
                    <Td>
                      {record.employee_id ? (
                        <Badge tone="success">#{record.employee_id}</Badge>
                      ) : (
                        // Stored but unlinked: revenue is recorded, commission is not.
                        <Badge tone="warning">unmatched</Badge>
                      )}
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
