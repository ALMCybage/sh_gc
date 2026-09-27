/**
 * The API contract, expressed once.
 *
 * Every response is parsed through these schemas, so a backend change that breaks
 * the contract fails loudly at one place instead of turning into `undefined`
 * three components deep. The request schemas mirror the Laravel validation rules
 * so most 422s are caught in the browser before a round trip.
 */
import { z } from 'zod'

/* -------------------------------------------------------------------------- */
/* shared                                                                      */
/* -------------------------------------------------------------------------- */

export const tenantSchema = z.object({
  id: z.string(),
  name: z.string(),
  database: z.string(),
  domain: z.string().nullable(),
})

export type Tenant = z.infer<typeof tenantSchema>

/** Laravel's LengthAwarePaginator, as returned by ->paginate(). */
export function paginated<T extends z.ZodTypeAny>(item: T) {
  return z.object({
    current_page: z.number(),
    data: z.array(item),
    from: z.number().nullable(),
    to: z.number().nullable(),
    last_page: z.number(),
    per_page: z.union([z.number(), z.string()]).transform(Number),
    total: z.number(),
  })
}

/** MySQL DECIMAL columns arrive as strings; keep the precision, parse on demand. */
const decimal = z.union([z.string(), z.number()]).transform((v) => Number(v))

/* -------------------------------------------------------------------------- */
/* auth + tenant                                                               */
/* -------------------------------------------------------------------------- */

export const whoamiSchema = z.object({
  tenant: tenantSchema,
  pod: z.string(),
  topics: z.object({ payroll: z.string(), sales: z.string() }),
})

export const authUserSchema = z.object({
  data: z.object({
    id: z.number(),
    name: z.string(),
    email: z.string(),
    role: z.string(),
    /*
     * The server's resolved ability list, not the role name.
     *
     * The SPA hides what the API would refuse, and it must not reimplement the
     * role matrix to work that out - the two would eventually disagree, and the
     * disagreement would look like a bug in the UI rather than a policy change.
     */
    abilities: z.array(z.string()),
    tenant: tenantSchema,
  }),
})

export type AuthUser = z.infer<typeof authUserSchema>['data']

export const loginRequestSchema = z.object({
  email: z.string().min(1, 'Email is required.').email('Enter a valid email address.'),
  password: z.string().min(1, 'Password is required.'),
  remember: z.boolean().optional(),
})

export type LoginRequest = z.infer<typeof loginRequestSchema>

/* -------------------------------------------------------------------------- */
/* async submissions (the 202 envelope)                                        */
/* -------------------------------------------------------------------------- */

export const acceptedSchema = z.object({
  data: z.object({
    request_id: z.string(),
    event_id: z.string(),
    message_id: z.string(),
    status: z.string(),
    accepted_at: z.string(),
    tenant: z.string(),
    status_url: z.string(),
    row_count: z.number().optional(),
  }),
})

export type Accepted = z.infer<typeof acceptedSchema>['data']

/* -------------------------------------------------------------------------- */
/* request status (Firestore)                                                  */
/* -------------------------------------------------------------------------- */

export const REQUEST_STATUSES = ['ACCEPTED', 'QUEUED', 'PROCESSING', 'COMPLETED', 'FAILED'] as const
export type RequestStatusValue = (typeof REQUEST_STATUSES)[number]

/**
 * The status document is written by two services: the web tier seeds it, then the
 * Go worker merges its own fields in. Rather than enumerate every key, the known
 * ones are typed and the rest passes through - a new field added by the worker
 * should show up in the UI, not blow up the parse.
 */
export const requestStatusSchema = z.object({
  data: z
    .object({
      request_id: z.string(),
      tenant_id: z.string(),
      status: z.enum(REQUEST_STATUSES).catch('QUEUED'),
      event_type: z.string().optional(),
      topic: z.string().optional(),
      message_id: z.string().optional(),
      created_at: z.string().optional(),
      updated_at: z.string().optional(),
      started_at: z.string().optional(),
      completed_at: z.string().optional(),
      failed_at: z.string().optional(),
      error: z.string().optional(),
      last_error: z.string().optional(),
      worker: z.string().optional(),
      processed_by: z.string().optional(),
      delivery_attempt: z.number().optional(),
      queue_lag_ms: z.number().optional(),
      duration_ms: z.number().optional(),
      warning: z.string().optional(),
      unmatched_rep_emails: z.array(z.string()).optional(),
    })
    .passthrough(),
  meta: z.object({
    terminal: z.boolean(),
    retry_after_seconds: z.number().nullable(),
  }),
})

export type RequestStatusResponse = z.infer<typeof requestStatusSchema>
export type RequestStatusDoc = RequestStatusResponse['data']

/* -------------------------------------------------------------------------- */
/* employees                                                                   */
/* -------------------------------------------------------------------------- */

export const employeeSchema = z.object({
  id: z.number(),
  employee_code: z.string(),
  first_name: z.string(),
  last_name: z.string(),
  email: z.string(),
  department: z.string().nullable(),
  // Optional because the server omits these columns entirely for callers without
  // the employees.view-compensation ability. Absent, not null - the row shape
  // itself changes, which is why the response carries includes_compensation.
  base_salary: decimal.optional(),
  commission_rate: decimal.optional(),
  is_active: z.boolean(),
})

export type Employee = z.infer<typeof employeeSchema>

export const employeesResponseSchema = paginated(employeeSchema).extend({
  meta: z.object({
    tenant: z.string(),
    cache_ttl_seconds: z.number(),
    includes_compensation: z.boolean(),
  }),
})

/* -------------------------------------------------------------------------- */
/* payroll                                                                     */
/* -------------------------------------------------------------------------- */

export const payrollRunSchema = z.object({
  id: z.number(),
  request_id: z.string(),
  period_start: z.string(),
  period_end: z.string(),
  status: z.string(),
  employee_count: z.number(),
  gross_total: decimal,
  tax_total: decimal,
  commission_total: decimal,
  net_total: decimal,
  currency: z.string(),
  processed_by: z.string().nullable(),
  duration_ms: z.number().nullable(),
  notes: z.string().nullable(),
  created_at: z.string().nullable(),
})

export type PayrollRun = z.infer<typeof payrollRunSchema>

export const payrollLineSchema = z.object({
  id: z.number(),
  employee_id: z.number(),
  gross_amount: decimal,
  tax_amount: decimal,
  commission_amount: decimal,
  net_amount: decimal,
  employee: z
    .object({
      id: z.number(),
      employee_code: z.string(),
      first_name: z.string(),
      last_name: z.string(),
      department: z.string().nullable(),
    })
    .nullable()
    .optional(),
})

export type PayrollLine = z.infer<typeof payrollLineSchema>

export const payrollRunsResponseSchema = paginated(payrollRunSchema)

export const payrollRunDetailSchema = z.object({
  data: payrollRunSchema.extend({
    lines: z.array(payrollLineSchema).default([]),
  }),
})

export const payrollRequestSchema = z
  .object({
    period_start: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Use YYYY-MM-DD.'),
    period_end: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Use YYYY-MM-DD.'),
    include_commission: z.boolean(),
    // Laravel accepts 0..0.6; mirror it so the slider cannot submit a 422.
    tax_rate: z.number().min(0, 'Cannot be negative.').max(0.6, 'Cannot exceed 60%.'),
    notes: z.string().max(500, 'Keep notes under 500 characters.').optional(),
  })
  .refine((v) => v.period_end >= v.period_start, {
    path: ['period_end'],
    message: 'Period end must be on or after period start.',
  })

export type PayrollRequest = z.infer<typeof payrollRequestSchema>

/* -------------------------------------------------------------------------- */
/* sales                                                                       */
/* -------------------------------------------------------------------------- */

export const salesRecordSchema = z.object({
  id: z.number(),
  request_id: z.string(),
  external_id: z.string(),
  employee_id: z.number().nullable(),
  rep_email: z.string().nullable(),
  product: z.string().nullable(),
  amount: decimal,
  currency: z.string(),
  sold_at: z.string().nullable(),
})

export type SalesRecord = z.infer<typeof salesRecordSchema>

export const salesRecordsResponseSchema = paginated(salesRecordSchema)

/* -------------------------------------------------------------------------- */
/* audit trail                                                                 */
/* -------------------------------------------------------------------------- */

export const auditLogSchema = z.object({
  id: z.number(),
  actor_id: z.number().nullable(),
  actor_email: z.string().nullable(),
  actor_role: z.string().nullable(),
  action: z.string(),
  subject_type: z.string().nullable(),
  subject_id: z.string().nullable(),
  request_id: z.string().nullable(),
  ip: z.string().nullable(),
  outcome: z.string(),
  context: z.record(z.unknown()).nullable(),
  created_at: z.string().nullable(),
})

export type AuditLogEntry = z.infer<typeof auditLogSchema>

export const auditLogsResponseSchema = paginated(auditLogSchema)

export const salesRowSchema = z.object({
  external_id: z.string().min(1, 'Required.').max(64, 'Max 64 characters.'),
  rep_email: z.string().email('Invalid email.').max(190),
  product: z.string().max(120).nullable().optional(),
  amount: z.number().nonnegative('Cannot be negative.'),
  currency: z.string().length(3).optional(),
  sold_at: z.string().min(1, 'Required.'),
})

export type SalesRow = z.infer<typeof salesRowSchema>

/** The server caps a single import at 2,000 rows; the client chunks to match. */
export const SALES_IMPORT_MAX_ROWS = 2000
