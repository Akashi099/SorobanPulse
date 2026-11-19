import type { Meta, StoryObj } from '@storybook/react'
import { Badge } from './Badge'
import { Card } from './Card'

const meta: Meta<typeof Card> = {
  title: 'Design System/Card',
  component: Card,
  args: { children: 'Total events indexed: 1,284,301' },
}
export default meta
type Story = StoryObj<typeof Card>

export const Plain: Story = {}
export const WithHeader: Story = {
  args: { title: 'Indexer', actions: <Badge tone="success" dot>Healthy</Badge> },
}
export const Accent: Story = { args: { accent: 'info', title: 'Latest ledger', children: '52,118,004' } }
export const Flush: Story = { args: { flush: true, children: <div className="ds-m-4">Edge-to-edge content</div> } }
