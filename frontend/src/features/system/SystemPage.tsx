/**
 * Operational view: which pod answered, which tenant schema is bound, and whether
 * each dependency is reachable. Useful in a demo and genuinely useful on call.
 */
import { useQuery } from '@tanstack/react-query'

import { fetchReadiness, fetchWhoami, queryKeys } from '../../api/endpoints'
import { Alert, Badge, Card, PageHeader, Spinner } from '../../components/ui'

const CHECK_LABELS: Record<string, string> = {
  mysql: 'Cloud SQL for MySQL',
  redis: 'Memorystore (Redis)',
  firestore: 'Firestore',
}

export function SystemPage() {
  const whoami = useQuery({ queryKey: queryKeys.whoami, queryFn: fetchWhoami })

  const readiness = useQuery({
    queryKey: queryKeys.readiness,
    queryFn: fetchReadiness,
    refetchInterval: 15_000,
    refetchIntervalInBackground: false,
  })

  return (
    <>
      <PageHeader
        title="System"
        description="Tenant binding and dependency health, straight from the pod that served this request."
      />

      <div className="grid gap-6 lg:grid-cols-2 lg:items-start">
        <Card title="Tenant binding" description="Resolved from the Host header by the web tier">
          {whoami.isLoading && <Spinner />}

          {whoami.data && (
            <dl className="space-y-2 text-sm">
              {[
                ['Tenant id', whoami.data.tenant.id],
                ['Name', whoami.data.tenant.name],
                ['MySQL schema', whoami.data.tenant.database],
                ['Domain', whoami.data.tenant.domain ?? '-'],
                ['Serving pod', whoami.data.pod],
                ['Payroll topic', whoami.data.topics.payroll],
                ['Sales topic', whoami.data.topics.sales],
              ].map(([label, value]) => (
                <div key={label} className="flex justify-between gap-3 border-b border-slate-100 pb-1.5">
                  <dt className="text-slate-500">{label}</dt>
                  <dd className="text-right font-mono text-xs font-medium text-slate-800">{value}</dd>
                </div>
              ))}
            </dl>
          )}
        </Card>

        <Card
          title="Readiness"
          description="GET /readyz — the same endpoint the GKE BackendConfig health check uses"
          actions={
            readiness.data && (
              <Badge tone={readiness.data.status === 'ready' ? 'success' : 'danger'}>{readiness.data.status}</Badge>
            )
          }
        >
          {readiness.isLoading && <Spinner />}

          {readiness.isError && <Alert title="Could not reach /readyz">{(readiness.error as Error).message}</Alert>}

          {readiness.data && (
            <ul className="space-y-2">
              {Object.entries(readiness.data.checks).map(([name, check]) => (
                <li
                  key={name}
                  className="flex items-start justify-between gap-3 rounded-md bg-slate-50 px-3 py-2 ring-1 ring-inset ring-slate-200"
                >
                  <div>
                    <p className="text-sm font-medium text-slate-800">{CHECK_LABELS[name] ?? name}</p>
                    {check.error && <p className="mt-0.5 text-xs text-red-700">{check.error}</p>}
                  </div>
                  <Badge tone={check.ok ? 'success' : 'danger'}>{check.ok ? 'ok' : 'down'}</Badge>
                </li>
              ))}
            </ul>
          )}

          <p className="mt-4 text-xs text-slate-500">
            Liveness (<span className="font-mono">/healthz</span>) deliberately checks nothing, so a dependency blip
            cannot restart healthy pods. Readiness does check dependencies, so an unhealthy pod leaves the load
            balancer's NEG instead of serving errors.
          </p>
        </Card>
      </div>
    </>
  )
}
