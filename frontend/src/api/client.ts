/**
 * The single HTTP boundary for the app.
 *
 * Everything about talking to Laravel is decided here: same-origin URLs, cookie
 * credentials, CSRF handling, and turning every non-2xx response into one
 * predictable ApiError shape. No component ever calls fetch directly.
 */

/** Field-level validation messages from a Laravel 422. */
export type FieldErrors = Record<string, string[]>

export class ApiError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly fieldErrors: FieldErrors = {},
    /** Seconds the server asked us to wait, from Retry-After. */
    readonly retryAfter: number | null = null,
    readonly body: unknown = null,
  ) {
    super(message)
    this.name = 'ApiError'
  }

  get isUnauthenticated() {
    return this.status === 401
  }

  /** Authenticated, but the role does not permit the action. */
  get isForbidden() {
    return this.status === 403
  }

  get isValidation() {
    return this.status === 422
  }

  /**
   * An Idempotency-Key was reused with a different payload, or the first request
   * carrying it is still in flight.
   */
  get isConflict() {
    return this.status === 409
  }

  /** The role reported by the server on a 403, for the message shown to the user. */
  get role(): string | null {
    const body = this.body as { role?: unknown } | null

    return typeof body?.role === 'string' ? body.role : null
  }

  get isRateLimited() {
    return this.status === 429
  }

  /** 503 from a submit means Pub/Sub was unreachable: nothing was enqueued. */
  get isQueueUnavailable() {
    return this.status === 503
  }

  /** Losing the CSRF token (session expired or rotated) shows up as 419. */
  get isTokenMismatch() {
    return this.status === 419
  }
}

/**
 * Broadcast when any request comes back 401, so the auth layer can drop the
 * cached user without every call site having to handle it.
 */
export const UNAUTHENTICATED_EVENT = 'sequifi:unauthenticated'

const UNSAFE_METHODS = new Set(['POST', 'PUT', 'PATCH', 'DELETE'])

function readCookie(name: string): string | null {
  const match = document.cookie.match(new RegExp('(^|;\\s*)' + name + '=([^;]*)'))
  return match?.[2] ? decodeURIComponent(match[2]) : null
}

let csrfPromise: Promise<void> | null = null

/**
 * Make sure the XSRF-TOKEN cookie exists before an unsafe request.
 *
 * Concurrent callers share one in-flight request; a submit that fires while the
 * token is still being fetched must not trigger a second round trip.
 */
export async function ensureCsrfToken(force = false): Promise<void> {
  if (!force && readCookie('XSRF-TOKEN')) return

  if (!csrfPromise || force) {
    csrfPromise = fetch('/sanctum/csrf-cookie', {
      credentials: 'include',
      headers: { Accept: 'application/json' },
    })
      .then(() => undefined)
      .finally(() => {
        csrfPromise = null
      })
  }

  await csrfPromise
}

type RequestOptions = {
  method?: string
  body?: unknown
  query?: Record<string, string | number | boolean | null | undefined>
  signal?: AbortSignal
  /**
   * Required by the async write endpoints. Must be stable across retries of the
   * same logical operation: that is the whole point of it.
   */
  idempotencyKey?: string
  /** Internal: set while retrying a 419 so we cannot loop forever. */
  isRetry?: boolean
}

/**
 * A key for one logical operation.
 *
 * Generated once per attempt at a *distinct* action and reused for every retry of
 * it, so a double-click or a retry after a timeout replays the original response
 * instead of queueing a second payroll run.
 */
export function newIdempotencyKey(prefix: string): string {
  const random =
    typeof crypto !== 'undefined' && 'randomUUID' in crypto
      ? crypto.randomUUID()
      : Math.random().toString(36).slice(2) + Date.now().toString(36)

  return `${prefix}-${random}`
}

function buildUrl(path: string, query?: RequestOptions['query']): string {
  if (!query) return path

  const params = new URLSearchParams()

  for (const [key, value] of Object.entries(query)) {
    if (value === null || value === undefined || value === '') continue
    params.set(key, String(value))
  }

  const qs = params.toString()
  return qs ? `${path}?${qs}` : path
}

async function parseBody(response: Response): Promise<unknown> {
  if (response.status === 204) return null

  const type = response.headers.get('content-type') ?? ''
  if (!type.includes('json')) return await response.text()

  try {
    return await response.json()
  } catch {
    return null
  }
}

function toApiError(status: number, body: unknown, retryAfterHeader: string | null): ApiError {
  const record = (body ?? {}) as Record<string, unknown>
  const retryAfter = retryAfterHeader ? Number(retryAfterHeader) : null

  const fallback: Record<number, string> = {
    401: 'Your session has expired. Please sign in again.',
    403: 'You do not have access to this resource.',
    404: 'Not found.',
    419: 'Your session expired. Please try again.',
    422: 'Please correct the highlighted fields.',
    429: 'Too many requests. Please slow down.',
    503: 'The service is temporarily unavailable. Please retry.',
  }

  const message =
    (typeof record.message === 'string' && record.message) ||
    fallback[status] ||
    `Request failed with status ${status}.`

  return new ApiError(
    status,
    message,
    (record.errors as FieldErrors) ?? {},
    Number.isFinite(retryAfter) ? retryAfter : null,
    body,
  )
}

/**
 * Same-origin fetch with cookies, CSRF and normalised errors.
 *
 * Paths are relative ("/api/v1/employees") on purpose: in production the SPA is
 * served by Cloud CDN from the same hostname as the API, so there is no base URL
 * to configure and no environment-specific bundle.
 */
export async function apiFetch<T>(path: string, options: RequestOptions = {}): Promise<T> {
  const method = (options.method ?? 'GET').toUpperCase()
  const headers: Record<string, string> = { Accept: 'application/json' }

  if (UNSAFE_METHODS.has(method)) {
    await ensureCsrfToken()

    const token = readCookie('XSRF-TOKEN')
    if (token) headers['X-XSRF-TOKEN'] = token
  }

  if (options.idempotencyKey) {
    headers['Idempotency-Key'] = options.idempotencyKey
  }

  if (options.body !== undefined) {
    headers['Content-Type'] = 'application/json'
  }

  const response = await fetch(buildUrl(path, options.query), {
    method,
    headers,
    credentials: 'include',
    signal: options.signal ?? null,
    body: options.body === undefined ? null : JSON.stringify(options.body),
  })

  if (response.ok) {
    return (await parseBody(response)) as T
  }

  const body = await parseBody(response)

  /*
   * A 419 means the CSRF token went stale (the session rotated, or the tab sat
   * open for a long time). Refresh it once and replay: retrying transparently is
   * far better UX than showing the user a confusing "page expired".
   */
  if (response.status === 419 && !options.isRetry && UNSAFE_METHODS.has(method)) {
    await ensureCsrfToken(true)
    return apiFetch<T>(path, { ...options, isRetry: true })
  }

  if (response.status === 401) {
    window.dispatchEvent(new CustomEvent(UNAUTHENTICATED_EVENT))
  }

  throw toApiError(response.status, body, response.headers.get('Retry-After'))
}
