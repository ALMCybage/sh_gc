# frontend — Static Frontend Tier (React 19)

The SPA. Builds to static files, published to Cloud Storage and served from Cloud
CDN, so this tier runs no pods. See the [root README](../README.md) for the whole
architecture.

## Run it

The API must be running first (see the root README, or `web-api/dev-sqlite.ps1`
for a no-dependency local API).

```bash
cp .env.example .env      # point VITE_API_TARGET at your API
npm install
npm run dev
```

Then open **http://acme.localhost:5173** — not `localhost:5173`. The tenant comes
from the subdomain, exactly as it does in production. `whiteknight.localhost:5173`
and `frdm.localhost:5173` work the same way; browsers resolve `*.localhost` to
127.0.0.1 with no hosts-file entry.

Seeded credentials are `admin@<tenant>.test` / `password`.

## Why the dev server proxies the API

`vite.config.ts` proxies `/api` and `/sanctum` to the API with
`changeOrigin: false`. That buys three things:

- **No CORS anywhere.** Not in dev, not in production. There is no cross-origin
  configuration to get wrong.
- **Cookies behave as they will in production** — `HttpOnly`, `SameSite=Lax`,
  host-only. An auth bug cannot hide behind a dev-only relaxation.
- **Laravel sees the real `Host` header**, so tenant resolution goes through the
  same code path the GCP load balancer will exercise.

## Where things live

| Concern | Path |
|---|---|
| The only place `fetch` is called | `src/api/client.ts` |
| The API contract (Zod) | `src/api/schemas.ts` |
| Typed endpoint calls + query keys | `src/api/endpoints.ts` |
| Session state | `src/auth/AuthProvider.tsx` |
| **Async job registry** | `src/jobs/JobsProvider.tsx`, `JobPoller.tsx` |
| Activity drawer | `src/jobs/ActivityDrawer.tsx` |
| CSV parsing (Web Worker) | `src/features/sales/csv.worker.ts` |
| Screens | `src/features/*` |
| UI primitives | `src/components/ui.tsx` |

## The async job pattern

Both writes return `202` with a `request_id`; the data does not exist yet. That is
handled in exactly one place:

1. A submit succeeds → `useJobs().track({ requestId, kind, label })`.
2. `JobsProvider` mounts a `JobPoller` per active job. Polling therefore continues
   while the drawer is closed and while the user navigates away from the form.
3. `JobPoller` reads `meta.terminal` from the API rather than hardcoding which
   statuses are final, and uses `meta.retry_after_seconds` as its interval. It
   backs off 2s → 5s → 15s, and pauses entirely while the tab is hidden.
4. On `COMPLETED` it invalidates the relevant list queries **once**. Nothing polls
   MySQL on a timer.
5. Jobs are mirrored to `sessionStorage`, so a refresh mid-payroll resumes
   tracking instead of orphaning the request, and broadcast over
   `BroadcastChannel` so a second tab sees the same jobs.

## Error handling

`ApiError` normalises every failure, and each status means something specific:

| Status | Handling |
|---|---|
| 422 | `fieldErrors` mapped onto the form via `setError` |
| 503 on submit | "nothing was enqueued, safe to retry" — the publish failed, so no duplicate can result |
| 429 | surfaces `Retry-After` in the message |
| 419 | the client refreshes the CSRF token and replays the request once, silently |
| 401 | fires a window event; `AuthProvider` clears the cached session |

## Known limitations

- No test suite. `npm run build` runs `tsc --noEmit` first, so the build is the
  type gate.
- No ESLint config; the strict `tsconfig.json` (`noUnusedLocals`,
  `noUncheckedIndexedAccess`) does most of that work.
- `BroadcastChannel` shares job state across tabs but does not elect a single
  poller, so two open tabs poll the same job independently. Fine at this scale;
  leader election would be the fix if it mattered.
- Polling could be replaced by subscribing to the Firestore status documents
  directly, which removes the status endpoint entirely. It also adds Firebase Auth
  alongside the Laravel session and makes Firestore security rules the only thing
  standing between tenants. Not worth it here.
