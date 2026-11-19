# SorobanPulse design system

Issue #1352. Import from `src/design-system` (index.ts also loads the CSS):

```tsx
import { Button, Badge, Card, Table, Drawer } from '../design-system'
```

| File | Purpose |
|------|---------|
| `tokens.css` | Colour, spacing, typography, radius, elevation tokens (`--sp-*`), light + `[data-theme='dark']` |
| `components.css` | Component classes (`ds-button`, `ds-badge`, `ds-card`, `ds-table`, `ds-drawer`) and layout/text utilities |
| `*.tsx` | Typed React components |
| `*.stories.tsx` | Storybook stories (≥2 variants each) |

Run Storybook: `npm install && npm run storybook` (http://localhost:6006).

## Rules

- Pages do not use inline `style={{…}}` for design values; use a token-backed
  class. The only remaining `style` props are the row positions computed at
  runtime by the virtualizer in `LiveStreamPage.tsx`, which are layout
  geometry, not design values.
- Add new colours/sizes as tokens in `tokens.css` first, then reference them.
