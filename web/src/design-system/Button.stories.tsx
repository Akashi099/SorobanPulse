import type { Meta, StoryObj } from '@storybook/react'
import { Button } from './Button'

const meta: Meta<typeof Button> = {
  title: 'Design System/Button',
  component: Button,
  args: { children: 'Button' },
  argTypes: {
    variant: { control: 'select', options: ['primary', 'secondary', 'ghost', 'danger'] },
    size: { control: 'select', options: ['sm', 'md', 'lg'] },
  },
}
export default meta
type Story = StoryObj<typeof Button>

export const Primary: Story = { args: { variant: 'primary', children: 'Save' } }
export const Secondary: Story = { args: { variant: 'secondary', children: 'Cancel' } }
export const Ghost: Story = { args: { variant: 'ghost', children: 'More' } }
export const Danger: Story = { args: { variant: 'danger', children: 'Delete key' } }
export const Small: Story = { args: { size: 'sm', children: 'Small' } }
export const Disabled: Story = { args: { variant: 'primary', disabled: true, children: 'Disabled' } }
