// The default theme, in the logo's orange.
import DefaultTheme from 'vitepress/theme'
import LiveDemo from './LiveDemo.vue'
import './style.css'

export default {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    app.component('LiveDemo', LiveDemo)
  },
}
