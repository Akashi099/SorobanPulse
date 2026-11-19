import type { HTMLAttributes, ReactNode } from 'react'
import { cx } from './cx'

export type BadgeTone = 'neutral' | 'success' | 'warning' | 'danger' | 'info'

export interface BadgeProps extends HTMLAttributes<HTMLSpanElement> {
  /** Semantic colour. Defaults to `neutral`. */
  tone?: BadgeTone
  /** Show a leading status dot. */
  dot?: boolean
  children?: ReactNode
}

export function Badge({ tone = 'neutral', dot = false, className, children, ...rest }: BadgeProps) {
  return (
    <span className={cx('ds-badge', tone !== 'neutral' && `ds-badge--${tone}`, className)} {...rest}>
      {dot && <span className="ds-badge__dot" aria-hidden="true" />}
      {children}
    </span>
  )
}
