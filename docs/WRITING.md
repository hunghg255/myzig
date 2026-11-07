# Writing the docs

How pages in `docs/` are written. `npm run prose` checks the measurable
parts. This file is not part of the site.

## A page

1. A title and one sentence: what it is and when to use it.
2. The demo and picture (`<!-- demo: name height=N -->` above the image).
3. The smallest code that uses it.
4. An options table: `| Field | Default | |`, one short phrase per row.
5. **Behavior** as bullets: one fact per bullet, the facts a user would
   test or trip over.
6. Rare details, edge cases and reasons go last, in a `<details>` block
   with a `<summary>` line, or are cut.

Reference pages (architecture, CLI) follow the same rules but keep their
order.

## Sentences

- At most about 20 words. One idea each. Split on ";" and ":".
- Paragraphs at most 60 words (90 in Vietnamese); otherwise a list or a
  table.
- No nested parentheses, and at most one parenthesis per sentence.
- Say what it does, not how it is implemented, unless the page is about
  the implementation.
- Code before the explanation of the code.
- Cut "note that", "simply", "in order to", "it is worth".
- Keep every fact, number, default and API name. Shorter, not vaguer.

## Structure that must not change

Other pages and the site depend on these:

- Headings and their anchors: `## Dialogs` keeps its text, because
  `overlays.md#dialogs` links to it. The Vietnamese pages put
  `<a id="dialogs"></a>` above the translated heading.
- Demo comments, image paths and captions, code blocks (identical in both
  languages, comments in them may be translated), and links.

## Vietnamese

Write as a Vietnamese developer would, not word for word. Keep these terms
in English: toast, drawer, sheet, dialog, popover, tooltip, menu, widget,
view, state, frame, layout (as a noun for the pass), context, callback,
event, frontend, backend, build, test, render, shader, cache, thread,
handle (of a drawer), snap point, focus, scroll, padding, gap, flexbox,
webview, IPC, plugin, app, tab, label, placeholder, slider, checkbox,
switch, badge, spinner, accordion, combobox, the names of types, fields
and functions.

| English | Tiếng Việt |
|---|---|
| box | box |
| child, children | phần tử con |
| parent | phần tử cha |
| window | cửa sổ |
| button | nút |
| text | chữ, văn bản |
| point (unit) | điểm |
| pointer | con trỏ |
| press, click | bấm |
| drag | kéo |
| swipe | vuốt |
| keyboard focus | focus bàn phím |
| screen reader | trình đọc màn hình |
| reduced motion | giảm chuyển động |
| the user | người dùng |
| default | mặc định |
| option | tùy chọn |
| field | trường |
| returns | trả về |
| reports | báo về |
| test (noun) | test |
| Tester | `ui.Tester` |

Never: "trẻ em", "cha mẹ", "tiểu bang", "nâng cốc chúc mừng", "người
kiểm tra", "thùng chứa", "phòng" for room/space (use "chỗ", "khoảng
trống").
