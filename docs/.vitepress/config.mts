// The documentation site: `npm install && npm run dev` in docs/ (see
// docs/README.md). The pages stay plain Markdown that reads the same on
// GitHub; links out of docs/ (to AGENTS.md, the sources, hillclimb's
// notes) go to the repository there.
import { defineConfig } from 'vitepress'
import path from 'node:path'
import { vietnamese, vietnameseSearch } from './vi.mts'

const repo = 'https://github.com/hunghg255/myzig'
const branch = 'main'

const page = (text: string, link: string) => ({ text, link })

const guide = [
  {
    text: 'Introduction',
    items: [page('Overview', '/README'), page('Getting started', '/getting-started')],
  },
  {
    text: 'The app and the desktop',
    items: [
      page('The application', '/app'),
      page('Windows', '/windows'),
      page('Menus, trays and shortcuts', '/menus'),
      page('The system around the app', '/system'),
      page('Documents', '/documents'),
      page('Audio', '/audio'),
      page('Clipboard and drag data', '/data-transfer'),
    ],
  },
  {
    text: 'Web pages',
    items: [page('Pages', '/pages'), page('Bindings', '/bindings'), page('The frontend', '/frontend')],
  },
  {
    text: 'Everything else',
    items: [
      page('Native UI in browsers', '/browsers'),
      page('Languages', '/i18n'),
      page('The myzig CLI', '/cli'),
      page('Configuration', '/configuration'),
      page('Building and distributing', '/distribution'),
      page('Updates', '/updates'),
    ],
  },
]

const ui = [
  {
    text: 'Native UI',
    items: [
      page('Overview', '/ui/README'),
      page('Rendering', '/ui/rendering'),
      page('Layout', '/ui/layout'),
      page('Grid', '/ui/grid'),
      page('Styling and themes', '/ui/styling'),
      page('Views', '/ui/views'),
      page('Testing', '/ui/testing'),
    ],
  },
  {
    text: 'Widgets',
    items: [
      page('Text', '/ui/text'),
      page('Buttons and small things', '/ui/buttons'),
      page('Choices', '/ui/choices'),
      page('Ranges', '/ui/ranges'),
      page('Text input', '/ui/text-input'),
      page('Dates, times and colors', '/ui/dates-and-colors'),
      page('Forms', '/ui/forms'),
      page('Overlays', '/ui/overlays'),
      page('Menus and selects', '/ui/menus'),
      page('Structures', '/ui/structures'),
      page('Lists, trees and tables', '/ui/lists'),
      page('Navigation and focus', '/ui/navigation'),
      page('Drag and drop', '/ui/drag-and-drop'),
      page('Custom widgets', '/ui/custom-widgets'),
      page('Scrolling and pinching', '/ui/gestures'),
    ],
  },
  {
    text: 'Motion and drawing',
    items: [
      page('Motion', '/ui/motion'),
      page('Transforms and effects', '/ui/transforms'),
      page('Drawing', '/ui/drawing'),
      page('Charts', '/ui/chart'),
      page('Shaders', '/ui/shaders'),
    ],
  },
  {
    text: 'Editors',
    items: [
      page('Markdown', '/ui/markdown'),
      page('Text area', '/ui/text-area'),
      page('Code editor and diffs', '/ui/code-editor'),
      page('Rich text editor', '/ui/rich-text'),
      page('Web views in native UI', '/ui/web-view'),
    ],
  },
  {
    text: 'More',
    items: [
      page('Accessibility', '/ui/accessibility'),
      page('Right to left', '/ui/right-to-left'),
      page('Inspector', '/ui/inspector'),
      page('Performance', '/ui/performance'),
    ],
  },
]

const plugins = [
  {
    text: 'Plugins',
    items: [
      page('Using and writing plugins', '/plugins'),
      ...['fetch', 'websocket', 'sqlite', 'watch', 'updater', 'terminal', 'glass', 'game', 'mainthread', 'loading'].map((name) =>
        page(name, `/plugins/${name}`),
      ),
    ],
  },
]

const architecture = [
  {
    text: 'How myzig works',
    items: [
      page('Architecture', '/architecture'),
      page('IPC and TypeScript generation', '/architecture-ipc'),
      page('Rendering native UI', '/architecture-rendering'),
      page('Testing, size and features', '/architecture-testing'),
    ],
  },
]

/** A link out of docs/ (`../AGENTS.md` from a page) becomes the file's page in the repository. */
function outOfDocs(md: any) {
  md.core.ruler.push('myzig_out_of_docs', (state: any) => {
    const from = path.posix.dirname(state.env.relativePath ?? '')
    const walk = (tokens: any[]) => {
      for (const t of tokens) {
        if (t.children) walk(t.children)
        if (t.type !== 'link_open') continue
        const href: string = t.attrGet('href') ?? ''
        if (/^[a-z]+:|^#|^\//i.test(href)) continue
        const [file, hash] = href.split('#')
        const target = path.posix.normalize(path.posix.join(from, file))
        // public/ is the site root; keep source links usable on GitHub too.
        if (target.startsWith('public/')) {
          t.attrSet('href', `/${target.slice('public/'.length)}${hash ? '#' + hash : ''}`)
          continue
        }
        if (!target.startsWith('../')) continue
        const inRepo = target.replace(/^\.\.\//, '')
        const kind = /\.[a-z0-9]+$/i.test(inRepo) ? 'blob' : 'tree'
        t.attrSet('href', `${repo}/${kind}/${branch}/${inRepo}${hash ? '#' + hash : ''}`)
      }
    }
    walk(state.tokens)
  })
}

export default defineConfig({
  lang: 'en',
  title: 'myzig',
  description: 'Desktop apps in Zig, with native UI drawn on the GPU or a web frontend.',
  cleanUrls: true,
  locales: {
    root: { label: 'English', lang: 'en' },
    vi: {
      label: 'Tiếng Việt',
      lang: 'vi',
      description: 'Ứng dụng desktop bằng Zig với giao diện native trên GPU hoặc frontend web.',
      themeConfig: vietnamese({ '/ui/': ui, '/plugins': plugins, '/architecture': architecture, '/': guide }),
    },
  },
  lastUpdated: false,
  head: [['link', { rel: 'icon', type: 'image/png', href: '/favicon.png' }]],
  markdown: {
    config: outOfDocs,
    theme: { light: 'github-light', dark: 'github-dark' },
  },
  themeConfig: {
    logo: '/logo.png',
    nav: [
      { text: 'Guide', link: '/getting-started', activeMatch: '^/(?!ui/|plugins|architecture)' },
      { text: 'Native UI', link: '/ui/README', activeMatch: '^/ui/' },
      { text: 'Plugins', link: '/plugins', activeMatch: '^/plugins' },
      { text: 'Architecture', link: '/architecture', activeMatch: '^/architecture' },
    ],
    sidebar: {
      '/ui/': ui,
      '/plugins': plugins,
      '/architecture': architecture,
      '/': guide,
    },
    socialLinks: [{ icon: 'github', link: repo }],
    search: { provider: 'local', options: { locales: { vi: { translations: vietnameseSearch } } } },
    outline: { level: [2, 3] },
    editLink: { pattern: `${repo}/edit/${branch}/docs/:path` },
    footer: { message: 'Released under the MIT License.', copyright: 'myzig, after mygo and GPUI' },
  },
})
