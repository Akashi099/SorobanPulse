import { useEffect, type ReactNode } from 'react'
import { Button } from './Button'
import { cx } from './cx'

export interface DrawerProps {
  open: boolean
  onClose: () => void
  title: ReactNode
  /** Edge the drawer slides from. Defaults to `right`. */
  side?: 'left' | 'right'
  /** Use the wider drawer width. */
  wide?: boolean
  children?: ReactNode
}

export function Drawer({ open, onClose, title, side = 'right', wide = false, children }: DrawerProps) {
  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose()
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open, onClose])

  if (!open) return null
  return (
    <div className={cx('ds-drawer-overlay', `ds-drawer-overlay--${side}`)} onClick={onClose}>
      <aside
        role="dialog"
        aria-modal="true"
        aria-label={typeof title === 'string' ? title : undefined}
        className={cx('ds-drawer', wide && 'ds-drawer--wide')}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="ds-drawer__header">
          <h2 className="ds-drawer__title">{title}</h2>
          <Button variant="ghost" size="sm" onClick={onClose} aria-label="Close">
            ✕
          </Button>
        </div>
        {children}
      </aside>
    </div>
  )
}
