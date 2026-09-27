import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'

import { ApiError } from '../../api/client'
import { loginRequestSchema, type LoginRequest } from '../../api/schemas'
import { useAuth } from '../../auth/AuthProvider'
import { Alert, Button, Card, Field, Input } from '../../components/ui'

export function LoginPage() {
  const { signIn, isSigningIn, tenant } = useAuth()

  const {
    register,
    handleSubmit,
    setError,
    formState: { errors },
  } = useForm<LoginRequest>({
    resolver: zodResolver(loginRequestSchema),
    defaultValues: { email: '', password: '', remember: false },
  })

  const onSubmit = handleSubmit(async (values) => {
    try {
      await signIn(values)
    } catch (error) {
      if (error instanceof ApiError && error.isValidation) {
        // Laravel's 422 field errors map straight onto the form.
        for (const [field, messages] of Object.entries(error.fieldErrors)) {
          setError(field as keyof LoginRequest, { message: messages[0] })
        }
        return
      }

      if (error instanceof ApiError && error.isRateLimited) {
        setError('root', {
          message: `Too many attempts. Try again in ${error.retryAfter ?? 60} seconds.`,
        })
        return
      }

      setError('root', {
        message: error instanceof ApiError ? error.message : 'Something went wrong. Please try again.',
      })
    }
  })

  return (
    <main className="flex min-h-full items-center justify-center px-4 py-12">
      <div className="w-full max-w-sm">
        <div className="mb-6 text-center">
          <h1 className="text-lg font-semibold tracking-tight text-slate-900">Sequifi Console</h1>
          {/* Naming the tenant before sign-in confirms the user is on the right
              hostname; the tenant comes from the subdomain, not from a picker. */}
          <p className="mt-1 text-sm text-slate-600">
            {tenant ? (
              <>
                Signing in to <span className="font-medium text-slate-900">{tenant.name}</span>
              </>
            ) : (
              'Resolving tenant…'
            )}
          </p>
        </div>

        <Card>
          <form onSubmit={onSubmit} className="space-y-4" noValidate>
            {errors.root && <Alert>{errors.root.message}</Alert>}

            <Field label="Email" htmlFor="email" error={errors.email?.message}>
              <Input
                id="email"
                type="email"
                autoComplete="username"
                autoFocus
                invalid={Boolean(errors.email)}
                {...register('email')}
              />
            </Field>

            <Field label="Password" htmlFor="password" error={errors.password?.message}>
              <Input
                id="password"
                type="password"
                autoComplete="current-password"
                invalid={Boolean(errors.password)}
                {...register('password')}
              />
            </Field>

            <label className="flex items-center gap-2 text-sm text-slate-700">
              <input type="checkbox" className="size-4 rounded border-slate-300" {...register('remember')} />
              Keep me signed in
            </label>

            <Button type="submit" loading={isSigningIn} className="w-full">
              Sign in
            </Button>
          </form>
        </Card>

        {import.meta.env.DEV && tenant && (
          <p className="mt-4 text-center text-xs text-slate-500">
            Seeded credentials: <span className="font-mono">admin@{tenant.id}.test</span> / password
          </p>
        )}
      </div>
    </main>
  )
}
