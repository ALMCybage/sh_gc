import { useState } from 'react'
import { NavLink, Outlet } from 'react-router-dom'

import { Ability, RoleLabel, type AbilityName } from '../api/abilities'
import { useAuth } from '../auth/AuthProvider'
import { Badge, Button } from '../components/ui'
import { ActivityDrawer } from '../jobs/ActivityDrawer'
import { useJobs } from '../jobs/JobsProvider'
import { cn } from '../lib/cn'

/**
 * Nav entries carry the ability they need. Hiding a link the API would refuse is a
 * usability decision, not a security one - every route is gated server-side.
 */
const navigation: Array<{ to: string; label: string; ability?: AbilityName }> = [
  { to: '/employees', label: 'Employees', ability: Ability.EmployeesView },
  { to: '/payroll', label: 'Payroll', ability: Ability.PayrollView },
  { to: '/sales/import', label: 'Import sales', ability: Ability.SalesImport },
  { to: '/sales/records', label: 'Sales records', ability: Ability.SalesView },
  { to: '/audit', label: 'Audit', ability: Ability.AuditView },
  { to: '/system', label: 'System' },
]

export function AppShell() {
  const { user, tenant, signOut, isSigningOut, can } = useAuth()
  const { activeCount } = useJobs()
  const [drawerOpen, setDrawerOpen] = useState(false)

  const visible = navigation.filter((item) => !item.ability || can(item.ability))

  return (
    <div className="flex min-h-full flex-col">
      <header className="border-b border-slate-200 bg-white">
        <div className="mx-auto flex max-w-7xl flex-wrap items-center gap-x-6 gap-y-3 px-4 py-3 sm:px-6">
          <div className="flex items-center gap-3">
            <span className="text-sm font-semibold tracking-tight text-slate-900">Sequifi</span>
            {/* The tenant badge is a safety rail: one glance confirms which
                tenant's data is on screen, and it comes from the server, not
                from anything the client chose. */}
            {tenant && <Badge tone="info">{tenant.name}</Badge>}
          </div>

          <nav className="order-3 -mx-1 flex w-full gap-1 overflow-x-auto sm:order-none sm:w-auto">
            {visible.map((item) => (
              <NavLink
                key={item.to}
                to={item.to}
                className={({ isActive }) =>
                  cn(
                    'whitespace-nowrap rounded-md px-3 py-1.5 text-sm font-medium transition',
                    isActive ? 'bg-slate-900 text-white' : 'text-slate-600 hover:bg-slate-100 hover:text-slate-900',
                  )
                }
              >
                {item.label}
              </NavLink>
            ))}
          </nav>

          <div className="ml-auto flex items-center gap-2">
            <Button variant="secondary" onClick={() => setDrawerOpen(true)}>
              Activity
              {activeCount > 0 && (
                <span className="ml-1 inline-flex size-5 items-center justify-center rounded-full bg-sky-100 text-xs font-semibold text-sky-700">
                  {activeCount}
                </span>
              )}
            </Button>

            <div className="hidden text-right sm:block">
              <p className="text-xs font-medium text-slate-900">{user?.name}</p>
              <p className="text-xs text-slate-500">
                {user?.email}
                {user?.role && <> · {RoleLabel[user.role] ?? user.role}</>}
              </p>
            </div>

            <Button variant="ghost" onClick={() => void signOut()} loading={isSigningOut}>
              Sign out
            </Button>
          </div>
        </div>
      </header>

      <main className="mx-auto w-full max-w-7xl flex-1 px-4 py-8 sm:px-6">
        <Outlet />
      </main>

      <ActivityDrawer open={drawerOpen} onClose={() => setDrawerOpen(false)} />
    </div>
  )
}
