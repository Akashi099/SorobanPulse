import type { ReactNode } from 'react'
import { cx } from './cx'

export interface TableColumn<T> {
  key: string
  header: ReactNode
  render: (row: T) => ReactNode
}

export interface TableProps<T> {
  columns: TableColumn<T>[]
  rows: T[]
  /** Stable key for each row. */
  rowKey: (row: T, index: number) => string
  /** Shown in a single full-width cell when `rows` is empty. */
  emptyMessage?: ReactNode
  striped?: boolean
  compact?: boolean
  onRowClick?: (row: T) => void
  caption?: string
  className?: string
}

export function Table<T>({
  columns,
  rows,
  rowKey,
  emptyMessage = 'No data',
  striped = false,
  compact = false,
  onRowClick,
  caption,
  className,
}: TableProps<T>) {
  return (
    <div className="ds-table-wrap">
      <table className={cx('ds-table', striped && 'ds-table--striped', compact && 'ds-table--compact', className)}>
        {caption && <caption className="sr-only">{caption}</caption>}
        <thead>
          <tr>
            {columns.map((c) => (
              <th key={c.key} scope="col">
                {c.header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.length === 0 ? (
            <tr>
              <td colSpan={columns.length} className="ds-table__empty">
                {emptyMessage}
              </td>
            </tr>
          ) : (
            rows.map((row, i) => (
              <tr
                key={rowKey(row, i)}
                className={onRowClick ? 'ds-table__row--clickable' : undefined}
                onClick={onRowClick ? () => onRowClick(row) : undefined}
              >
                {columns.map((c) => (
                  <td key={c.key}>{c.render(row)}</td>
                ))}
              </tr>
            ))
          )}
        </tbody>
      </table>
    </div>
  )
}
