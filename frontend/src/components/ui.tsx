/**
 * Small hand-rolled primitives.
 *
 * Deliberately not a component library: this app needs about eight pieces, and a
 * dependency-free set keeps the bundle (and the audit surface) small. Every
 * interactive element carries the accessibility attributes it needs rather than
 * relying on a library to supply them.
 */
import type { ButtonHTMLAttributes, InputHTMLAttributes, ReactNode, SelectHTMLAttributes } from 'react'

import { cn } from '../lib/cn'

/* buttons ------------------------------------------------------------------- */

type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: 'primary' | 'secondary' | 'ghost' | 'danger'
  loading?: boolean
}

const buttonVariants: Record<NonNullable<ButtonProps['variant']>, string> = {
  primary: 'bg-slate-900 text-white hover:bg-slate-700 focus-visible:outline-slate-900',
  secondary:
    'bg-white text-slate-900 ring-1 ring-inset ring-slate-300 hover:bg-slate-50 focus-visible:outline-slate-900',
  ghost: 'text-slate-600 hover:bg-slate-100 hover:text-slate-900 focus-visible:outline-slate-400',
  danger: 'bg-red-600 text-white hover:bg-red-500 focus-visible:outline-red-600',
}

export function Button({ variant = 'primary', loading, className, children, ...props }: ButtonProps) {
  return (
    <button
      {...props}
      // aria-busy tells a screen reader the control is working, which a spinner
      // alone does not convey.
      aria-busy={loading || undefined}
      disabled={props.disabled || loading}
      className={cn(
        'inline-flex items-center justify-center gap-2 rounded-md px-3 py-2 text-sm font-medium',
        'transition focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2',
        'disabled:cursor-not-allowed disabled:opacity-50',
        buttonVariants[variant],
        className,
      )}
    >
      {loading && <Spinner className="size-4" />}
      {children}
    </button>
  )
}

export function Spinner({ className }: { className?: string }) {
  return (
    <svg className={cn('animate-spin', className ?? 'size-5')} viewBox="0 0 24 24" aria-hidden="true">
      <circle cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" fill="none" opacity="0.25" />
      <path d="M12 2a10 10 0 0 1 10 10" stroke="currentColor" strokeWidth="4" fill="none" />
    </svg>
  )
}

/* form fields --------------------------------------------------------------- */

export function Field({
  label,
  htmlFor,
  error,
  hint,
  children,
}: {
  label: string
  htmlFor: string
  error?: string
  hint?: string
  children: ReactNode
}) {
  const describedBy = error ? `${htmlFor}-error` : hint ? `${htmlFor}-hint` : undefined

  return (
    <div className="space-y-1.5">
      <label htmlFor={htmlFor} className="block text-sm font-medium text-slate-700">
        {label}
      </label>
      {children}
      {hint && !error && (
        <p id={describedBy} className="text-xs text-slate-500">
          {hint}
        </p>
      )}
      {error && (
        // role="alert" so the message is announced when validation fails.
        <p id={describedBy} role="alert" className="text-xs font-medium text-red-600">
          {error}
        </p>
      )}
    </div>
  )
}

export function Input({ invalid, className, ...props }: InputHTMLAttributes<HTMLInputElement> & { invalid?: boolean }) {
  return (
    <input
      {...props}
      aria-invalid={invalid || undefined}
      className={cn(
        'block w-full rounded-md border-0 px-3 py-2 text-sm text-slate-900 shadow-sm',
        'ring-1 ring-inset placeholder:text-slate-400',
        'focus:ring-2 focus:ring-inset focus:ring-slate-900',
        invalid ? 'ring-red-400' : 'ring-slate-300',
        className,
      )}
    />
  )
}

export function Select({ className, ...props }: SelectHTMLAttributes<HTMLSelectElement>) {
  return (
    <select
      {...props}
      className={cn(
        'block w-full rounded-md border-0 px-3 py-2 text-sm text-slate-900 shadow-sm',
        'ring-1 ring-inset ring-slate-300 focus:ring-2 focus:ring-inset focus:ring-slate-900',
        className,
      )}
    />
  )
}

/* layout -------------------------------------------------------------------- */

export function Card({
  title,
  description,
  actions,
  children,
  className,
}: {
  title?: string
  description?: string
  actions?: ReactNode
  children: ReactNode
  className?: string
}) {
  return (
    <section className={cn('rounded-lg bg-white shadow-sm ring-1 ring-slate-200', className)}>
      {(title || actions) && (
        <header className="flex flex-wrap items-start justify-between gap-3 border-b border-slate-200 px-5 py-4">
          <div>
            {title && <h2 className="text-sm font-semibold text-slate-900">{title}</h2>}
            {description && <p className="mt-0.5 text-xs text-slate-500">{description}</p>}
          </div>
          {actions && <div className="flex items-center gap-2">{actions}</div>}
        </header>
      )}
      <div className="px-5 py-4">{children}</div>
    </section>
  )
}

export function PageHeader({
  title,
  description,
  actions,
}: {
  title: string
  description?: string
  actions?: ReactNode
}) {
  return (
    <div className="mb-6 flex flex-wrap items-end justify-between gap-4">
      <div>
        <h1 className="text-xl font-semibold tracking-tight text-slate-900">{title}</h1>
        {description && <p className="mt-1 max-w-2xl text-sm text-slate-600">{description}</p>}
      </div>
      {actions && <div className="flex items-center gap-2">{actions}</div>}
    </div>
  )
}

/* status ------------------------------------------------------------------- */

export type BadgeTone = 'neutral' | 'info' | 'success' | 'warning' | 'danger'

const badgeTones: Record<BadgeTone, string> = {
  neutral: 'bg-slate-100 text-slate-700 ring-slate-200',
  info: 'bg-sky-50 text-sky-700 ring-sky-200',
  success: 'bg-emerald-50 text-emerald-700 ring-emerald-200',
  warning: 'bg-amber-50 text-amber-800 ring-amber-200',
  danger: 'bg-red-50 text-red-700 ring-red-200',
}

export function Badge({ tone = 'neutral', children }: { tone?: BadgeTone; children: ReactNode }) {
  return (
    <span
      className={cn(
        'inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ring-1 ring-inset',
        badgeTones[tone],
      )}
    >
      {children}
    </span>
  )
}

export function Alert({
  tone = 'danger',
  title,
  children,
}: {
  tone?: BadgeTone
  title?: string
  children?: ReactNode
}) {
  const tones: Record<BadgeTone, string> = {
    neutral: 'bg-slate-50 text-slate-700 ring-slate-200',
    info: 'bg-sky-50 text-sky-800 ring-sky-200',
    success: 'bg-emerald-50 text-emerald-800 ring-emerald-200',
    warning: 'bg-amber-50 text-amber-900 ring-amber-200',
    danger: 'bg-red-50 text-red-800 ring-red-200',
  }

  return (
    <div role="alert" className={cn('rounded-md px-4 py-3 text-sm ring-1 ring-inset', tones[tone])}>
      {title && <p className="font-semibold">{title}</p>}
      {children && <div className={cn(title && 'mt-1')}>{children}</div>}
    </div>
  )
}

export function EmptyState({ title, description, action }: { title: string; description?: string; action?: ReactNode }) {
  return (
    <div className="py-12 text-center">
      <p className="text-sm font-medium text-slate-900">{title}</p>
      {description && <p className="mx-auto mt-1 max-w-md text-sm text-slate-500">{description}</p>}
      {action && <div className="mt-4 flex justify-center">{action}</div>}
    </div>
  )
}

/* tables ------------------------------------------------------------------- */

export function Table({ children, caption }: { children: ReactNode; caption?: string }) {
  return (
    <div className="-mx-5 overflow-x-auto">
      <table className="min-w-full divide-y divide-slate-200 text-sm">
        {caption && <caption className="sr-only">{caption}</caption>}
        {children}
      </table>
    </div>
  )
}

export function Th({ children, numeric }: { children: ReactNode; numeric?: boolean }) {
  return (
    <th
      scope="col"
      className={cn(
        'px-5 py-2.5 text-xs font-semibold uppercase tracking-wide text-slate-500',
        numeric ? 'text-right' : 'text-left',
      )}
    >
      {children}
    </th>
  )
}

export function Td({ children, numeric, className }: { children: ReactNode; numeric?: boolean; className?: string }) {
  return (
    <td className={cn('whitespace-nowrap px-5 py-2.5 text-slate-700', numeric && 'text-right tabular-nums', className)}>
      {children}
    </td>
  )
}

export function Pagination({
  page,
  lastPage,
  total,
  from,
  to,
  onChange,
  busy,
}: {
  page: number
  lastPage: number
  total: number
  from: number | null
  to: number | null
  onChange: (page: number) => void
  busy?: boolean
}) {
  return (
    <nav className="mt-4 flex items-center justify-between gap-4" aria-label="Pagination">
      <p className="text-xs text-slate-500" aria-live="polite">
        {total === 0 ? 'No results' : `Showing ${from ?? 0}-${to ?? 0} of ${total}`}
      </p>
      <div className="flex items-center gap-2">
        <Button variant="secondary" disabled={busy || page <= 1} onClick={() => onChange(page - 1)}>
          Previous
        </Button>
        <span className="text-xs text-slate-500">
          Page {page} of {Math.max(lastPage, 1)}
        </span>
        <Button variant="secondary" disabled={busy || page >= lastPage} onClick={() => onChange(page + 1)}>
          Next
        </Button>
      </div>
    </nav>
  )
}
