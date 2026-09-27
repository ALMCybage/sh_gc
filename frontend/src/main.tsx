import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { BrowserRouter } from 'react-router-dom'

import './index.css'
import { App } from './App'
import { ApiError } from './api/client'
import { AuthProvider } from './auth/AuthProvider'

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      /*
       * Never retry a 4xx: the request is wrong, or the session is gone, and
       * retrying only delays the error the user needs to see. 5xx and network
       * failures get two attempts.
       */
      retry: (failureCount, error) => {
        if (error instanceof ApiError && error.status >= 400 && error.status < 500) return false
        return failureCount < 2
      },
      staleTime: 30_000,
      // Refetching on focus is right for a dashboard: coming back to the tab
      // should show current data, not whatever was on screen an hour ago.
      refetchOnWindowFocus: true,
    },
    mutations: {
      // Writes are never retried automatically. A payroll submission that appears
      // to fail may still have been published, and a blind retry could enqueue a
      // second run.
      retry: false,
    },
  },
})

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <AuthProvider>
          <App />
        </AuthProvider>
      </BrowserRouter>
    </QueryClientProvider>
  </StrictMode>,
)
