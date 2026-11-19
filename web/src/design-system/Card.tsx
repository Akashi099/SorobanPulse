import type { HTMLAttributes, ReactNode } from 'react'
import { cx } from './cx'

export type CardAccent = 'success' | 'warning' | 'danger' | 'info'

export interface CardProps extends Omit<HTMLAttributes<HTMLDivElement>, 'title'> {
  /** Optional heading rendered in the card header. */
  title?: ReactNode
  /** Optional content on the right of the header (e.g. a Button or Badge). */
  actions?: ReactNode
  /** Coloured top border. */
  accent?: CardAccent
  /** Remove inner padding (for edge-to-edge tables). */
  flush?: boolean
  children?: ReactNode
}

export function Card({ title, actions, accent, flush = false, className, children, ...rest }: CardProps) {
  return (
    <div
      className={cx('ds-card', 'card', flush && 'ds-card--flush', accent && `ds-card--accent-${accent}`, className)}
      {...rest}
    >
      {(title || actions) && (
        <div className="ds-card__header">
          {title && <h2 className="ds-card__title">{title}</h2>}
          {actions}
        </div>
      )}
      {children}
    </div>
  )
}
