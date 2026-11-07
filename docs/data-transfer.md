# Clipboard and drag data

Apps move data in two ways: the clipboard (copy and paste) and drag and
drop. myzig has:

- the system's clipboard, as plain calls in `myzig.clipboard`;
- one data model for what drags carry, in `myzig.transfer`;
- files dropped on windows from file managers, through
  `WindowOptions.on_drop`;
- drags that leave the window for other apps (`myzig.systemDrag`), and
  drops from them (`myzig.systemDrop`).

Drag and drop *within* a window of native UI is in
[drag and drop](ui/drag-and-drop.md): draggable boxes, drop targets, the
preview that follows the pointer. This page is about the data, and about
what crosses into other apps.

The `clipboard` example copies the same note as text, HTML and files. The
`drag-drop` example drags notes, text, URLs and files between two windows
and out to other apps:

```sh
zig build run-clipboard
zig build run-drag-drop
```

## The clipboard

```zig
const myzig = @import("myzig");

myzig.clipboard.writeText("Hello");
if (try myzig.clipboard.readText(gpa)) |s| {
    defer gpa.free(s);
}

try myzig.clipboard.writeHtml(gpa, "<b>Hello</b>", "Hello"); // with plain text for other apps
if (try myzig.clipboard.readHtml(gpa)) |html| gpa.free(html);

try myzig.clipboard.writeImage(gpa, png_bytes); // a PNG file's bytes
if (try myzig.clipboard.readImage(gpa)) |png| gpa.free(png); // a screenshot, a copied image, as PNG

try myzig.clipboard.writeFiles(gpa, &.{"/Users/ada/report.pdf"}); // as a file manager's Copy
if (try myzig.clipboard.readFiles(gpa)) |paths| myzig.dialog.freePaths(gpa, paths);

const seen = myzig.clipboard.changeCount(); // changes whenever anything writes to it
```

- Each read returns null when the clipboard holds nothing of that kind.
- The caller frees what a read returns.
- A write replaces what the clipboard held.

| | text | HTML | images | files |
|---|---|---|---|---|
| macOS | `public.utf8-plain-text` | `public.html` | `public.png`, else TIFF converted to PNG | file URLs |
| Linux | GTK's text | `text/html` | GdkPixbuf, as PNG | `text/uri-list` and GNOME's `x-special/gnome-copied-files` |
| Windows | `CF_UNICODETEXT` | "HTML Format" with its offsets header | the "PNG" format browsers write, else a DIB | `CF_HDROP`, as Explorer copies |
| browsers | the Clipboard API (writes); reads return what the app wrote | text only | no | no |

- On Linux, what myzig writes is served from memory until another app
  takes the clipboard, as GTK does.
- `changeCount` is 0 in browsers.

**Any data.** `myzig.clipboard.writeData(&data)` writes a
`myzig.transfer.Data`, every item in all its formats. `formats()` lists
what the clipboard holds, and `read(mime)` reads one.

A format given by a `Lazy` provider is made only when an app pastes it:

- on Windows, through delayed rendering (`WM_RENDERFORMAT`);
- on macOS, through `NSPasteboardItemDataProvider`;
- on Linux, as GTK asks.

Native UI's text fields, text areas and editors copy, cut and paste text
through the clipboard by themselves. In tests, `ui.Tester` has a clipboard
of its own, so tests never touch the user's.

## Transfer data

`myzig.transfer.Data` is what a drag carries. An app can also build one
for its own copy and paste.

- It holds ordered *items*: a note, three files.
- Each item offers alternative *formats* of the same content: the note's
  text and its HTML.
- Formats are named by MIME types.
- Bytes are given now, or made only when a receiver asks.

```zig
const transfer = myzig.transfer;

const Note = struct {
    title: []const u8,
    body: []const u8,

    /// Made once per data, when a receiver reads it.
    fn json(n: *Note, gpa: std.mem.Allocator) anyerror![]u8 {
        return std.json.Stringify.valueAlloc(gpa, n.*, .{});
    }
};

var data = try transfer.Data.init(gpa, &.{.{ .reps = &.{
    transfer.bytes(transfer.text, note.title),
    transfer.lazy("application/vnd.example.note+json", .of(&note, Note.json)),
} }});
defer data.deinit();
```

`Data.init` copies the formats and bytes it is given. Each representation
is one of:

- `transfer.bytes(format, bytes)`;
- `transfer.lazy(format, provider)`. `transfer.Provider.of(ptr, func)`
  takes a method `fn (x: *X, gpa: std.mem.Allocator) anyerror![]u8`.

A lazy provider runs at most once per data, when a receiver first reads
its format. So a drag of a large document costs nothing until it drops
where the expensive format is wanted.

What the provider points to must live as long as the data. For that, the
`drag-drop` example keeps a copy of the note as it was when the drag
started.

The formats myzig names:

- `transfer.text` (`text/plain`), `transfer.html` (`text/html`),
  `transfer.markdown` (`text/markdown`), `transfer.png` (`image/png`),
- `transfer.uri_list` (`text/uri-list`) and `transfer.file_list`, a URI
  list known to hold local files: the system's file list,
- any MIME type of the app's own, such as
  `application/vnd.example.note+json`.

Shortcuts make common data:

- `transfer.textData(gpa, s)`: one item of text;
- `transfer.fileData(gpa, paths)`: one item per file, as file URLs;
- `transfer.valueData(gpa, T, ptr)`: a Zig value of this process.

### Reading

A receiver asks for the formats it wants, in its order of preference:

```zig
const wanted = [_][]const u8{ note_format, transfer.file_list, transfer.uri_list, transfer.text };

fn receive(data: *transfer.Data, a: std.mem.Allocator) !void {
    const f = data.preferred(&wanted) orelse return;
    if (std.mem.eql(u8, f, note_format)) {
        const bytes = try data.read(a, f);
        const note = try std.json.parseFromSliceLeaky(Note, a, bytes, .{});
        _ = note;
    } else if (std.mem.eql(u8, f, transfer.text)) {
        const s = try data.read(a, f);
        _ = s;
    } else {
        const files = try data.files(a); // local paths
        _ = files;
    }
}
```

- `data.has(format)` tells whether an item offers a format.
  `data.formats(a)` lists them all, without repeats.
- `data.preferred(wanted)` returns the first of `wanted` offered.
- `data.read(a, format)` returns its bytes. Lazy providers run now. The
  bytes are in `a`'s memory: give it an arena.
- `data.read` coalesces the items as the systems' transfers do: text
  joined by newlines, URI lists by CRLF, other formats the first item's.
- `data.files(a)` returns the local paths of a file list or URI list.
- `transfer.urlOfPath` and `transfer.pathOfUrl` convert between paths and
  `file:` URLs. On Windows `file:///C:/x` is `C:/x`.
- `data.value(T)` returns the value of type `T` the data offers, or null.
- `data.clone(gpa)` makes an independent copy. Use it to keep data that a
  drop hands over for one frame only.

### Values

```zig
if (d.starting) d.offer(try transfer.valueData(gpa, Task, task));
// in the target:
if (t.dropped) |drop| drop.data.value(Task).?.done = true;
```

`transfer.valueData(gpa, T, ptr)` offers a pointer to a Zig value under
the format `transfer.value_format(T)`
(`application/x-myzig-value;type=...`).

- It never leaves the process: native data never holds a pointer.
- So values only reach drop targets of the app's own windows. They read
  them with `data.value(T)`.
- Moving a task from one list to another is as simple as the code above.

### Effects

A drag says what the drop may do with its data: a `transfer.Effects` of
`copy`, `move` and `link`. The default is copy alone; `.copy_move` allows
both. A target says what it accepts.

`transfer.negotiate` picks the effect:

1. the one the modifier keys suggest, when both ends allow it;
2. else copy, then move, then link.

| modifier | macOS | elsewhere |
|---|---|---|
| copy | Option | Ctrl |
| move | Command | Shift |

A source told `.move` removes its value.

## Files dropped on windows

A window with `on_drop` accepts files dragged onto it from Finder,
Explorer and file managers. The handler gets their absolute paths, valid
during the call:

```zig
const Pane = struct {
    fn droppedFiles(p: *Pane, _: *myzig.Window, paths: []const []const u8) void {
        var data = transfer.fileData(p.gpa, paths) catch return;
        defer data.deinit();
        p.receive(&data); // the same code as for drops within the window
    }
};

_ = try app.newWindow(.{
    .title = "Drop here",
    .on_drop = .of(&pane, Pane.droppedFiles),
    .content = .{ .view = .init(&pane, Pane.view) },
});
```

- It is `NSDraggingDestination` on macOS, GTK's drag destination on Linux
  and `WM_DROPFILES` on Windows.
- Only files arrive this way. For text and other formats from other apps,
  see [Drops from other apps](#drops-from-other-apps).

## Drags that leave the window

```zig
const win = try app.newWindow(.{ .title = "Notes", .content = .{ .view = .init(&pane, Pane.view) } });
pane.dnd.external = myzig.systemDrag(win);
```

In native UI, a drag that leaves its window can go on in the system's drag
and drop. Notes, text, URLs and files then reach other windows and other
apps, as a text editor or Explorer. It needs an `external` on the window's
`ui.DragDrop`.

`myzig.systemDrag(win)` returns the system's drag where myzig has one. It
returns null elsewhere, where drags stay within their window.

| | the system's drag |
|---|---|
| Windows | OLE's `DoDragDrop`, with an `IDataObject` |
| macOS | an AppKit dragging session (`beginDraggingSessionWithItems:`) of pasteboard items |
| Linux | GTK's drag; each format's bytes are made when the app it drops on asks |

On Windows:

- The `IDataObject` offers the data's formats as other apps read them:
  `CF_UNICODETEXT` for text, `CF_HDROP` for files, "HTML Format", "PNG".
  Other MIME names become registered clipboard formats.
- Lazy providers run when the receiving app asks.
- Escape gives up. The drop's effect comes back to the source as its
  `finished.effect`.

**How it ended.** The source's `finished`, a `ui.DragFinished`, tells:

| field | |
|---|---|
| `effect` | what the target did |
| `canceled` | nothing dropped |
| `escaped` | the user gave the drag up (Escape, `dd.cancel()`), rather than let it go over no target |
| `screen` | where a drag that left the window ended, in points from the primary display's top left; null for one that ended in the window, at the pointer |

For example, a tab let go outside every window is `canceled and !escaped`
at `screen`. The app opens a window for it there.

<details>
<summary>A drag of your own</summary>

An `External` is a pair of a context and a `start` function, so an app can
plug in a drag of its own.

1. `start` is called in the frame the pointer leaves the window. It must
   not block.
2. Later, outside the frame, it drags `DragDrop.active`'s data.
3. Then it calls
   `dd.externalEnd(.{ .effect = effect, .escaped = escaped, .screen = point })`,
   or `dd.externalDone(effect)` when it knows no more. The effect is
   `.none` when nothing took it.
4. It draws a frame.

</details>

## Drops from other apps

```zig
try myzig.systemDrop(window, &state.dnd, &.{"application/x-myapp"});
```

`myzig.systemDrop` makes a window of native UI take what other apps drag
onto it, into its `ui.DragDrop` targets. That is text, URLs, HTML, files,
images and the extra types named. It works as drags within the window do
([drag and drop](ui/drag-and-drop.md)).

- It is OLE's IDropTarget on Windows, GTK's drag destination on Linux and
  NSDraggingDestination on macOS.
- On Windows, files that no target takes still reach the window's
  `on_drop`.
- Pages take drops themselves, as browsers do.

## Platform differences

| | clipboard | files dropped on windows | drags out of the window |
|---|---|---|---|
| macOS | text, HTML, images, files | yes | NSDraggingSource |
| Linux | text, HTML, images, files | yes | GTK's drag source |
| Windows | text, HTML, images, files | yes | OLE |
| browsers | text | no | no |
