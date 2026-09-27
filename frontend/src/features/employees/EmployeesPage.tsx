/**
 * Request type 4: a synchronous read of Cloud SQL, cached in Memorystore.
 */
import { useState } from 'react'
import { keepPreviousData, useQuery } from '@tanstack/react-query'

import { fetchEmployees, queryKeys, type EmployeeFilters } from '../../api/endpoints'
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
import { money, percent } from '../../lib/format'

const DEPARTMENTS = ['Sales', 'Engineering', 'Support', 'Finance']

export function EmployeesPage() {
  const [filters, setFilters] = useState<EmployeeFilters>({ page: 1, per_page: 25 })

  const query = useQuery({
    queryKey: queryKeys.employees(filters),
    queryFn: () => fetchEmployees(filters),
    // Keep the previous page on screen while the next one loads, so paging does
    // not flash an empty table.
    placeholderData: keepPreviousData,
  })

  const showCompensation = query.data?.meta.includes_compensation ?? false

  function patch(next: Partial<EmployeeFilters>) {
    setFilters((current) => ({ ...current, ...next, page: next.page ?? 1 }))
  }

  return (
    <>
      <PageHeader
        title="Employees"
        description="Read straight from this tenant's MySQL schema through the Cloud SQL Auth Proxy, then cached in Memorystore."
        actions={
          query.data && (
            <Badge tone="neutral">cache TTL {query.data.meta.cache_ttl_seconds}s</Badge>
          )
        }
      />

      <Card>
        {/* The server decides whether compensation is included, and says so in
            meta.includes_compensation. The client renders what it was given rather
            than deciding from a role name - the two could disagree. */}
        {query.data?.meta.includes_compensation === false && (
          <div className="mb-4">
            <Alert tone="info" title="Compensation hidden">
              Your role can see who works here but not what they are paid. Salary and commission are a separate
              permission.
            </Alert>
          </div>
        )}

        <div className="mb-4 grid gap-3 sm:grid-cols-3">
          <Field label="Department" htmlFor="department">
            <Select
              id="department"
              value={filters.department ?? ''}
              onChange={(event) => patch({ department: event.target.value || undefined })}
            >
              <option value="">All departments</option>
              {DEPARTMENTS.map((department) => (
                <option key={department} value={department}>
                  {department}
                </option>
              ))}
            </Select>
          </Field>

          <Field label="Status" htmlFor="active">
            <Select
              id="active"
              value={filters.active === undefined ? '' : filters.active ? '1' : '0'}
              onChange={(event) =>
                patch({ active: event.target.value === '' ? undefined : event.target.value === '1' })
              }
            >
              <option value="">Any status</option>
              <option value="1">Active only</option>
              <option value="0">Inactive only</option>
            </Select>
          </Field>

          <Field label="Per page" htmlFor="per_page">
            <Select
              id="per_page"
              value={String(filters.per_page ?? 25)}
              onChange={(event) => patch({ per_page: Number(event.target.value) })}
            >
              {[10, 25, 50, 100].map((size) => (
                <option key={size} value={size}>
                  {size}
                </option>
              ))}
            </Select>
          </Field>
        </div>

        {query.isError && <Alert title="Could not load employees">{(query.error as Error).message}</Alert>}

        {query.isLoading && (
          <div className="flex justify-center py-12">
            <Spinner />
          </div>
        )}

        {query.data && query.data.data.length === 0 && (
          <EmptyState
            title="No employees match these filters"
            description="Try clearing the department or status filter."
          />
        )}

        {query.data && query.data.data.length > 0 && (
          <>
            <Table caption="Employees in this tenant">
              <thead>
                <tr>
                  <Th>Code</Th>
                  <Th>Name</Th>
                  <Th>Email</Th>
                  <Th>Department</Th>
                  {showCompensation && <Th numeric>Base salary</Th>}
                  {showCompensation && <Th numeric>Commission</Th>}
                  <Th>Status</Th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {query.data.data.map((employee) => (
                  <tr key={employee.id} className="hover:bg-slate-50">
                    <Td className="font-mono text-xs">{employee.employee_code}</Td>
                    <Td>
                      {employee.first_name} {employee.last_name}
                    </Td>
                    <Td className="text-slate-500">{employee.email}</Td>
                    <Td>{employee.department ?? '-'}</Td>
                    {showCompensation && <Td numeric>{money(employee.base_salary ?? 0)}</Td>}
                    {showCompensation && (
                      <Td numeric>
                        {(employee.commission_rate ?? 0) > 0 ? percent(employee.commission_rate ?? 0) : '-'}
                      </Td>
                    )}
                    <Td>
                      {employee.is_active ? (
                        <Badge tone="success">Active</Badge>
                      ) : (
                        <Badge tone="neutral">Inactive</Badge>
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
              onChange={(page) => setFilters((current) => ({ ...current, page }))}
            />
          </>
        )}
      </Card>
    </>
  )
}
