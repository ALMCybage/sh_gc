/**
 * Session state for the SPA.
 *
 * There is no token in JavaScript: the credential is an HttpOnly cookie, so
 * "am I signed in?" is answered by asking the server. The answer is cached by
 * TanStack Query and cleared the moment any request comes back 401.
 */
import { createContext, useCallback, useContext, useEffect, useMemo, type ReactNode } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'

import { ApiError, UNAUTHENTICATED_EVENT, ensureCsrfToken } from '../api/client'
import { fetchCurrentUser, fetchWhoami, login as loginRequest, logout as logoutRequest, queryKeys } from '../api/endpoints'
import type { AbilityName } from '../api/abilities'
import type { AuthUser, LoginRequest, Tenant } from '../api/schemas'

type AuthContextValue = {
  user: AuthUser | null
  tenant: Tenant | null
  isLoading: boolean
  signIn: (credentials: LoginRequest) => Promise<AuthUser>
  signOut: () => Promise<void>
  isSigningIn: boolean
  isSigningOut: boolean
  /**
   * Whether the server said this user holds an ability.
   *
   * Used only to hide controls the API would refuse. It is not a security
   * boundary - every route is gated server-side with `can:` middleware, and
   * hiding a button has never stopped anyone from calling an endpoint.
   */
  can: (ability: AbilityName) => boolean
}

const AuthContext = createContext<AuthContextValue | null>(null)

export function AuthProvider({ children }: { children: ReactNode }) {
  const queryClient = useQueryClient()

  /*
   * whoami is unauthenticated but tenant-scoped, so the login screen can name the
   * tenant before anyone signs in. It also seeds the XSRF-TOKEN cookie as a side
   * effect of passing through Sanctum's stateful middleware.
   */
  const whoami = useQuery({
    queryKey: queryKeys.whoami,
    queryFn: fetchWhoami,
    staleTime: 60 * 60_000,
    retry: 1,
  })

  const userQuery = useQuery({
    queryKey: queryKeys.currentUser,
    queryFn: fetchCurrentUser,
    // A 401 is the expected answer for a signed-out visitor, not a failure worth
    // retrying. Retrying would delay the login screen by seconds.
    retry: (failureCount, error) => {
      if (error instanceof ApiError && error.isUnauthenticated) return false
      return failureCount < 2
    },
    staleTime: 5 * 60_000,
  })

  /* Any 401 anywhere drops the cached session, so a component never renders
     against a user who is no longer signed in. */
  useEffect(() => {
    const onUnauthenticated = () => {
      queryClient.setQueryData(queryKeys.currentUser, null)
    }

    window.addEventListener(UNAUTHENTICATED_EVENT, onUnauthenticated)
    return () => window.removeEventListener(UNAUTHENTICATED_EVENT, onUnauthenticated)
  }, [queryClient])

  const signInMutation = useMutation({
    mutationFn: async (credentials: LoginRequest) => {
      // The token must exist before the POST, or Laravel answers 419.
      await ensureCsrfToken(true)
      return loginRequest(credentials)
    },
    onSuccess: (user) => {
      queryClient.setQueryData(queryKeys.currentUser, user)
    },
  })

  const signOutMutation = useMutation({
    mutationFn: logoutRequest,
    onSuccess: () => {
      // Drop every cached response: the next user of this browser must not see
      // the previous user's employees or payroll runs from cache.
      queryClient.clear()
      queryClient.setQueryData(queryKeys.currentUser, null)
      sessionStorage.removeItem('sequifi.jobs.v1')
    },
  })

  const signIn = useCallback(
    (credentials: LoginRequest) => signInMutation.mutateAsync(credentials),
    [signInMutation],
  )

  const signOut = useCallback(async () => {
    await signOutMutation.mutateAsync()
  }, [signOutMutation])

  const user = userQuery.data ?? null

  const can = useCallback(
    (ability: AbilityName) => Boolean(user?.abilities.includes(ability)),
    [user],
  )

  const value = useMemo<AuthContextValue>(
    () => ({
      user,
      tenant: user?.tenant ?? whoami.data?.tenant ?? null,
      isLoading: userQuery.isLoading,
      signIn,
      signOut,
      isSigningIn: signInMutation.isPending,
      isSigningOut: signOutMutation.isPending,
      can,
    }),
    [
      user,
      whoami.data,
      userQuery.isLoading,
      signIn,
      signOut,
      signInMutation.isPending,
      signOutMutation.isPending,
      can,
    ],
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth(): AuthContextValue {
  const context = useContext(AuthContext)
  if (!context) throw new Error('useAuth must be used inside <AuthProvider>')

  return context
}
