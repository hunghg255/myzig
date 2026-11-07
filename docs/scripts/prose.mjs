// `npm run prose`: the measurable parts of docs/WRITING.md.
// - paragraphs and list items at most 60 words (90 in Vietnamese);
// - a Vietnamese page has its English page's demos, pictures, code blocks
//   and heading anchors;
// - Vietnamese pages avoid the mistranslations WRITING.md lists.
import fs from 'node:fs'
import path from 'node:path'

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Z]:)/, '$1')), '..')
const pages = []
const walk = (dir) => {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name)
    if (e.isDirectory()) {
      if (!['node_modules', '.vitepress', 'public', 'scripts', 'images'].includes(e.name)) walk(p)
    } else if (e.name.endsWith('.md') && e.name !== 'WRITING.md') pages.push(path.relative(root, p).replaceAll('\\', '/'))
  }
}
walk(root)

const slug = (s) =>
  s
    .replace(/`/g, '')
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/[\s~`!@#$%^&*()\-_+=[\]{}|\\;:"'“”‘’<>,.?/]+/g, '-')
    .replace(/-{2,}/g, '-')
    .replace(/^-+|-+$/g, '')
    .replace(/^(\d)/, '_$1')
    .toLowerCase()

function parse(text) {
  const lines = text.replace(/\r\n/g, '\n').split('\n')
  const out = { blocks: [], code: [], demos: [], images: [], headings: [], anchors: new Set() }
  let fence = null
  let buf = []
  let item = null
  const flush = () => {
    if (buf.length) out.blocks.push(buf.join(' '))
    buf = []
  }
  for (const line of lines) {
    if (fence !== null) {
      if (line.trim().startsWith('```')) {
        out.code.push(fence)
        fence = null
      } else fence += line + '\n'
      continue
    }
    if (line.trim().startsWith('```')) {
      flush()
      fence = ''
      continue
    }
    const demo = /<!--\s*demo:\s*([a-z-]+)/.exec(line)
    if (demo) out.demos.push(demo[1])
    for (const m of line.matchAll(/!\[[^\]]*\]\(([^)]+)\)/g)) out.images.push(m[1])
    for (const m of line.matchAll(/<a id="([^"]+)"/g)) out.anchors.add(m[1])
    const h = /^(#{2,4})\s+(.*)$/.exec(line)
    if (h) {
      flush()
      out.headings.push(slug(h[2]))
      out.anchors.add(slug(h[2]))
      continue
    }
    if (!line.trim() || /^\s*(\||<|!\[|#)/.test(line)) {
      flush()
      continue
    }
    if (/^\s*([-*]|\d+\.)\s/.test(line)) flush()
    buf.push(line.trim())
  }
  flush()
  return out
}

const words = (s) => s.replace(/`[^`]*`/g, 'x').split(/\s+/).filter(Boolean).length
const banned = [/trẻ em/i, /cha mẹ/i, /tiểu bang/i, /nâng (cốc|ly)/i, /chúc mừng/i, /người kiểm tra/i, /thùng chứa/i]
const problems = []
const parsed = new Map(pages.map((p) => [p, parse(fs.readFileSync(path.join(root, p), 'utf8'))]))

for (const [p, doc] of parsed) {
  const vi = p.startsWith('vi/')
  const limit = vi ? 90 : 60
  for (const b of doc.blocks) {
    const n = words(b)
    if (n > limit) problems.push(`${p}: ${n} words: ${b.slice(0, 70)}…`)
  }
  if (!vi) continue
  const text = fs.readFileSync(path.join(root, p), 'utf8')
  for (const re of banned) if (re.test(text)) problems.push(`${p}: "${re.source}" (see WRITING.md)`)
  const en = parsed.get(p.slice(3))
  if (!en) continue
  const same = (what, a, b) => {
    if (JSON.stringify(a) !== JSON.stringify(b)) problems.push(`${p}: its ${what} differ from ${p.slice(3)}`)
  }
  same('demos', doc.demos, en.demos)
  same('pictures', doc.images.map((i) => i.replace('../', '')), en.images)
  same('number of code blocks', doc.code.length, en.code.length)
  for (const a of en.headings) if (!doc.anchors.has(a)) problems.push(`${p}: no anchor "${a}" (<a id="${a}"></a> above its heading)`)
}

for (const p of problems) console.log(p)
console.log(`${problems.length} problems in ${pages.length} pages`)
process.exit(problems.length ? 1 : 0)
