import type { Meta, StoryObj } from '@storybook/react'
import { Badge } from './Badge'
import { Table, type TableProps } from './Table'

interface Row {
  id: string
  contract: string
  type: string
  ledger: number
}

const rows: Row[] = [
  { id: '1', contract: 'CABC…XYZ1', type: 'contract', ledger: 52118004 },
  { id: '2', contract: 'CDEF…XYZ2', type: 'system', ledger: 52118003 },
  { id: '3', contract: 'CGHI…XYZ3', type: 'diagnostic', ledger: 52118001 },
]

const base: TableProps<Row> = {
  rows,
  rowKey: (r) => r.id,
  columns: [
    { key: 'contract', header: 'Contract', render: (r) => r.contract },
    { key: 'type', header: 'Type', render: (r) => <Badge>{r.type}</Badge> },
    { key: 'ledger', header: 'Ledger', render: (r) => r.ledger.toLocaleString() },
  ],
}

const meta: Meta<typeof Table<Row>> = { title: 'Design System/Table', component: Table }
export default meta
type Story = StoryObj<typeof Table<Row>>

export const Default: Story = { args: base }
export const Striped: Story = { args: { ...base, striped: true } }
export const Compact: Story = { args: { ...base, compact: true } }
export const Empty: Story = { args: { ...base, rows: [], emptyMessage: 'No events yet' } }
