import type { Meta, StoryObj } from '@storybook/react'
import { useState } from 'react'
import { Button } from './Button'
import { Drawer, type DrawerProps } from './Drawer'

function Demo(props: Omit<DrawerProps, 'open' | 'onClose'>) {
  const [open, setOpen] = useState(true)
  return (
    <>
      <Button variant="primary" onClick={() => setOpen(true)}>
        Open drawer
      </Button>
      <Drawer {...props} open={open} onClose={() => setOpen(false)} />
    </>
  )
}

const meta: Meta<typeof Demo> = {
  title: 'Design System/Drawer',
  component: Demo,
  args: { title: 'Event details', children: <p>Ledger 52,118,004 · tx 9f2c…</p> },
}
export default meta
type Story = StoryObj<typeof Demo>

export const Right: Story = {}
export const Left: Story = { args: { side: 'left' } }
export const Wide: Story = { args: { wide: true } }
