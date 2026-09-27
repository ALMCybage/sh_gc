/**
 * Typed calls, one per endpoint. Each parses its response through the schema, so
 * the rest of the app works with validated data or an ApiError - never anything
 * in between.
 */
import { apiFetch } from './client'
import {
  acceptedSchema,
  auditLogsResponseSchema,
  authUserSchema,
  employeesResponseSchema,
  payrollRunDetailSchema,
  payrollRunsResponseSchema,
  requestStatusSchema,
  salesRecordsResponseSchema,
  whoamiSchema,
  type Accepted,
  type AuthUser,
  type LoginRequest,
  type PayrollRequest,
  type RequestStatusResponse,
  type SalesRow,
} from './schemas'

/* auth ---------------------------------------------------------------------- */

export async function fetchWhoami() {
  return whoamiSchema.parse(await apiFetch('/api/v1/whoami'))
}

export async function fetchCurrentUser(): Promise<AuthUser> {
  return authUserSchema.parse(await apiFetch('/api/v1/auth/user')).data
}

export async function login(body: LoginRequest): Promise<AuthUser> {
  return authUserSchema.parse(await apiFetch('/api/v1/auth/login', { method: 'POST', body })).data
}

export async function logout(): Promise<void> {
  await apiFetch('/api/v1/auth/logout', { method: 'POST' })
}

/* employees ----------------------------------------------------------------- */

export type EmployeeFilters = {
  department?: string
  active?: boolean | undefined
  page?: number
  per_page?: number
}

export async function fetchEmployees(filters: EmployeeFilters) {
  return employeesResponseSchema.parse(
    await apiFetch('/api/v1/employees', {
      query: {
        department: filters.department,
        // Laravel's boolean rule wants 1/0, not "true"/"false".
        active: filters.active === undefined ? undefined : filters.active ? 1 : 0,
        page: filters.page,
        per_page: filters.per_page,
      },
    }),
  )
}

/* async submissions --------------------------------------------------------- */

export async function submitPayroll(body: PayrollRequest, idempotencyKey: string): Promise<Accepted> {
  return acceptedSchema.parse(
    await apiFetch('/api/v1/payroll/calculations', { method: 'POST', body, idempotencyKey }),
  ).data
}

export async function submitSalesImport(
  source: string,
  rows: SalesRow[],
  idempotencyKey: string,
): Promise<Accepted> {
  return acceptedSchema.parse(
    await apiFetch('/api/v1/sales/imports', {
      method: 'POST',
      body: { source, rows },
      idempotencyKey,
    }),
  ).data
}

/* audit -------------------------------------------------------------------- */

export async function fetchAuditLogs(params: { page?: number; per_page?: number; action?: string }) {
  return auditLogsResponseSchema.parse(await apiFetch('/api/v1/audit-logs', { query: params }))
}

/* status -------------------------------------------------------------------- */

export async function fetchRequestStatus(requestId: string): Promise<RequestStatusResponse> {
  return requestStatusSchema.parse(await apiFetch(`/api/v1/requests/${requestId}`))
}

/* worker output ------------------------------------------------------------- */

export async function fetchPayrollRuns(params: { page?: number; per_page?: number; status?: string }) {
  return payrollRunsResponseSchema.parse(
    await apiFetch('/api/v1/payroll/calculations', { query: params }),
  )
}

export async function fetchPayrollRun(requestId: string) {
  return payrollRunDetailSchema.parse(
    await apiFetch(`/api/v1/payroll/calculations/${requestId}`),
  ).data
}

export async function fetchSalesRecords(params: {
  page?: number
  per_page?: number
  request_id?: string
  rep_email?: string
}) {
  return salesRecordsResponseSchema.parse(await apiFetch('/api/v1/sales/records', { query: params }))
}

/* health -------------------------------------------------------------------- */

export type Readiness = {
  status: string
  pod: string
  tenant: string | null
  checks: Record<string, { ok: boolean; error?: string }>
}

export async function fetchReadiness(): Promise<Readiness> {
  // /readyz answers 503 when a dependency is down, and that is information, not
  // an error - unwrap it instead of throwing so the page can render the detail.
  const response = await fetch('/readyz', {
    credentials: 'include',
    headers: { Accept: 'application/json' },
  })

  return (await response.json()) as Readiness
}

/* query keys ---------------------------------------------------------------- */

export const queryKeys = {
  whoami: ['whoami'] as const,
  currentUser: ['auth', 'user'] as const,
  employees: (filters: EmployeeFilters) => ['employees', filters] as const,
  payrollRuns: (page: number) => ['payroll-runs', page] as const,
  payrollRun: (requestId: string) => ['payroll-run', requestId] as const,
  salesRecords: (page: number, requestId?: string) => ['sales-records', page, requestId ?? null] as const,
  requestStatus: (requestId: string) => ['request-status', requestId] as const,
  auditLogs: (page: number, action?: string) => ['audit-logs', page, action ?? null] as const,
  readiness: ['readiness'] as const,
}
