import type { ButtonHTMLAttributes, ReactNode } from 'react'
import { cx } from './cx'

export type ButtonVariant = 'primary' | 'secondary' | 'ghost' | 'danger'
export type ButtonSize = 'sm' | 'md' | 'lg'

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  /** Visual style. Defaults to `secondary`. */
  variant?: ButtonVariant
  /** Size. Defaults to `md`. */
  size?: ButtonSize
  /** Stretch to the full width of the container. */
  block?: boolean
  children?: ReactNode
}

export function Button({
  variant = 'secondary',
  size = 'md',
  block = false,
  type = 'button',
  className,
  ...rest
}: ButtonProps) {
  return (
    <button
      type={type}
      className={cx(
        'ds-button',
        `ds-button--${variant}`,
        size !== 'md' && `ds-button--${size}`,
        block && 'ds-button--block',
        className,
      )}
      {...rest}
    />
  )
}
