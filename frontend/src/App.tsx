import { Navigate, Route, Routes } from 'react-router-dom'

import { useAuth } from './auth/AuthProvider'
import { Spinner } from './components/ui'
import { AuditPage } from './features/audit/AuditPage'
import { LoginPage } from './features/auth/LoginPage'
import { EmployeesPage } from './features/employees/EmployeesPage'
import { PayrollPage } from './features/payroll/PayrollPage'
import { RunDetailPage } from './features/payroll/RunDetailPage'
import { SalesImportPage } from './features/sales/SalesImportPage'
import { SalesRecordsPage } from './features/sales/SalesRecordsPage'
import { SystemPage } from './features/system/SystemPage'
import { JobsProvider } from './jobs/JobsProvider'
import { AppShell } from './layout/AppShell'

export function App() {
  const { user, isLoading } = useAuth()

  // The session lives in an HttpOnly cookie, so the first render has to wait for
  // the server's answer. Rendering the login form first would flash it at users
  // who are already signed in.
  if (isLoading) {
    return (
      <div className="flex h-full items-center justify-center">
        <Spinner className="size-6 text-slate-400" />
      </div>
    )
  }

  if (!user) {
    return <LoginPage />
  }

  return (
    // JobsProvider lives inside the authenticated tree: job state is per session,
    // and signing out must not leave pollers running against a dead session.
    <JobsProvider>
      <Routes>
        <Route element={<AppShell />}>
          <Route index element={<Navigate to="/employees" replace />} />
          <Route path="/employees" element={<EmployeesPage />} />
          <Route path="/payroll" element={<PayrollPage />} />
          <Route path="/payroll/:requestId" element={<RunDetailPage />} />
          <Route path="/sales/import" element={<SalesImportPage />} />
          <Route path="/sales/records" element={<SalesRecordsPage />} />
          <Route path="/audit" element={<AuditPage />} />
          <Route path="/system" element={<SystemPage />} />
          <Route path="*" element={<Navigate to="/employees" replace />} />
        </Route>
      </Routes>
    </JobsProvider>
  )
}
