/// <reference lib="webworker" />
/**
 * CSV parsing off the main thread.
 *
 * A 2,000-row parse plus per-row validation is enough to drop frames if it runs
 * on the UI thread, and the file the user drops may be much larger than the
 * server's per-request cap. Doing it in a worker keeps the page responsive and
 * lets us report progress.
 */
import Papa from 'papaparse'

import { salesRowSchema, type SalesRow } from '../../api/schemas'

export type ParseRequest = { file: File }

export type RowIssue = { line: number; field: string; message: string }

export type ParseResult = {
  rows: SalesRow[]
  issues: RowIssue[]
  duplicates: string[]
  totalLines: number
  totalAmount: number
}

export type WorkerMessage =
  | { type: 'progress'; parsed: number }
  | { type: 'done'; result: ParseResult }
  | { type: 'error'; message: string }

/** Accept a few common header spellings rather than demanding one exact format. */
const HEADER_ALIASES: Record<string, keyof SalesRow> = {
  external_id: 'external_id',
  externalid: 'external_id',
  id: 'external_id',
  order_id: 'external_id',
  rep_email: 'rep_email',
  repemail: 'rep_email',
  email: 'rep_email',
  rep: 'rep_email',
  product: 'product',
  item: 'product',
  amount: 'amount',
  total: 'amount',
  value: 'amount',
  currency: 'currency',
  sold_at: 'sold_at',
  soldat: 'sold_at',
  date: 'sold_at',
  sold_date: 'sold_at',
}

function normaliseHeader(header: string): string {
  const key = header.trim().toLowerCase().replace(/\s+/g, '_')
  return HEADER_ALIASES[key] ?? key
}

/** Normalise whatever the CSV holds into the RFC3339 the API expects. */
function toIsoTimestamp(raw: string): string | null {
  const value = raw.trim()
  if (!value) return null

  // Bare dates get midnight UTC rather than the browser's timezone, so an import
  // does not land in a different period depending on who uploaded it.
  if (/^\d{4}-\d{2}-\d{2}$/.test(value)) return `${value}T00:00:00Z`

  const parsed = new Date(value.includes(' ') && !value.includes('T') ? value.replace(' ', 'T') + 'Z' : value)
  if (Number.isNaN(parsed.getTime())) return null

  return parsed.toISOString().replace(/\.\d{3}Z$/, 'Z')
}

function parseAmount(raw: string): number {
  // Strip currency symbols and thousands separators: "$1,499.99" -> 1499.99
  return Number(raw.replace(/[^0-9.\-]/g, ''))
}

self.onmessage = (event: MessageEvent<ParseRequest>) => {
  const rows: SalesRow[] = []
  const issues: RowIssue[] = []
  const seen = new Set<string>()
  const duplicates: string[] = []

  let totalLines = 0
  let totalAmount = 0

  Papa.parse<Record<string, string>>(event.data.file, {
    header: true,
    skipEmptyLines: 'greedy',
    transformHeader: normaliseHeader,

    step: (results) => {
      totalLines += 1
      const line = totalLines + 1 // +1 for the header row, so it matches the editor
      const raw = results.data

      const candidate = {
        external_id: (raw.external_id ?? '').trim(),
        rep_email: (raw.rep_email ?? '').trim().toLowerCase(),
        product: (raw.product ?? '').trim() || null,
        amount: parseAmount(raw.amount ?? ''),
        currency: (raw.currency ?? '').trim().toUpperCase() || undefined,
        sold_at: toIsoTimestamp(raw.sold_at ?? '') ?? '',
      }

      const parsed = salesRowSchema.safeParse(candidate)

      if (!parsed.success) {
        for (const issue of parsed.error.issues.slice(0, 2)) {
          issues.push({ line, field: String(issue.path[0] ?? '?'), message: issue.message })
        }
        return
      }

      /*
       * The API rejects a batch containing the same external_id twice, because the
       * upsert's result would depend on statement order. Catching it here turns a
       * permanent worker failure into an inline warning.
       */
      if (seen.has(parsed.data.external_id)) {
        duplicates.push(parsed.data.external_id)
        return
      }

      seen.add(parsed.data.external_id)
      rows.push(parsed.data)
      totalAmount += parsed.data.amount

      if (totalLines % 250 === 0) {
        self.postMessage({ type: 'progress', parsed: totalLines } satisfies WorkerMessage)
      }
    },

    complete: () => {
      self.postMessage({
        type: 'done',
        result: { rows, issues, duplicates, totalLines, totalAmount },
      } satisfies WorkerMessage)
    },

    error: (error: Error) => {
      self.postMessage({ type: 'error', message: error.message } satisfies WorkerMessage)
    },
  })
}
