import type { Meta, StoryObj } from '@storybook/react'
import { Badge } from './Badge'

const meta: Meta<typeof Badge> = {
  title: 'Design System/Badge',
  component: Badge,
  args: { children: 'contract' },
  argTypes: { tone: { control: 'select', options: ['neutral', 'success', 'warning', 'danger', 'info'] } },
}
export default meta
type Story = StoryObj<typeof Badge>

export const Neutral: Story = {}
export const Success: Story = { args: { tone: 'success', dot: true, children: 'Healthy' } }
export const Warning: Story = { args: { tone: 'warning', dot: true, children: 'Lagging' } }
export const Danger: Story = { args: { tone: 'danger', dot: true, children: 'Down' } }
export const Info: Story = { args: { tone: 'info', children: 'diagnostic' } }
