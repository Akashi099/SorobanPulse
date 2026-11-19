import type { Preview } from '@storybook/react'
import '../src/design-system/tokens.css'
import '../src/design-system/components.css'

const preview: Preview = {
  globalTypes: {
    theme: {
      description: 'Colour theme',
      toolbar: { icon: 'mirror', items: ['light', 'dark'], dynamicTitle: true },
    },
  },
  initialGlobals: { theme: 'light' },
  decorators: [
    (Story, ctx) => {
      document.documentElement.dataset.theme = ctx.globals.theme ?? 'light'
      return Story()
    },
  ],
}
export default preview
