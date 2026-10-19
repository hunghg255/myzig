# Clipboard and drag data

Apps move data in two ways: the clipboard (copy and paste) and drag and
drop. myzig has the system's clipboard as plain calls in `myzig.clipboard`,
one data model for what drags carry in `myzig.transfer`, files dropped on
windows from file managers through `WindowOptions.on_drop`, and on Windows
drags that leave the window for other apps (`myzig.systemDrag`).

Drag and drop *within* a window of native UI (draggable boxes, drop
targets, the preview that follows the pointer) is in
[drag and drop](ui/drag-and-drop.md); this page is about the data, and
about what crosses into other apps.

The `clipboard` example copies the same note as text, HTML and files, and
the `drag-drop` example drags notes, text, URLs and files between two
windows and out to other apps:

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

Each read returns null when the clipboard holds nothing of that kind;
what it returns the caller frees. A write replaces what the clipboard
held.

| | text | HTML | images | files |
|---|---|---|---|---|
| macOS | `public.utf8-plain-text` | `public.html` | `public.png`, else TIFF converted to PNG | file URLs |
| Linux | GTK's text | `text/html` | GdkPixbuf, as PNG | `text/uri-list` and GNOME's `x-special/gnome-copied-files` |
| Windows | `CF_UNICODETEXT` | "HTML Format" with its offsets header | the "PNG" format browsers write, else a DIB | `CF_HDROP`, as Explorer copies |
| browsers | the Clipboard API (writes); reads return what the app wrote | text only | no | no |

On Linux, what myzig writes is served from memory until another app takes
the clipboard, as GTK does. `changeCount` is 0 in browsers.

`myzig.clipboard.writeData(&data)` writes a `myzig.transfer.Data`, every
item in all its formats; `formats()` lists what the clipboard holds and
`read(mime)` reads one. A format given by a `Lazy` provider is made only
when an app pastes it: on Windows through delayed rendering
(`WM_RENDERFORMAT`), on macOS through `NSPasteboardItemDataProvider`, on
Linux as GTK asks.

Native UI's text fields, text areas and editors copy, cut and paste text
through the clipboard by themselves. In tests, `ui.Tester` has a clipboard
of its own, so tests never touch the user's.

## Transfer data

`myzig.transfer.Data` is what a drag carries, and what an app can build
for its own copy and paste: ordered *items* (a note, three files), each
offering alternative *formats* of the same content (the note's text and
its HTML), named by MIME types, with bytes given now or made only when a
receiver asks:

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
is `transfer.bytes(format, bytes)` or `transfer.lazy(format, provider)`,
where `transfer.Provider.of(ptr, func)` takes a method
`fn (x: *X, gpa: std.mem.Allocator) anyerror![]u8`. A lazy provider runs
at most once per data, when a receiver first reads its format, so a drag
of a large document costs nothing until it drops somewhere that wants the
expensive format. What it points to must live as long as the data; the
`drag-drop` example keeps a copy of the note as it was when the drag
started for that.

The formats myzig names:

- `transfer.text` (`text/plain`), `transfer.html` (`text/html`),
  `transfer.markdown` (`text/markdown`), `transfer.png` (`image/png`),
- `transfer.uri_list` (`text/uri-list`) and `transfer.file_list`, a URI
  list known to hold local files: the system's file list,
- any MIME type of the app's own, such as
  `application/vnd.example.note+json`.

Shortcuts make common data: `transfer.textData(gpa, s)` (one item of
text), `transfer.fileData(gpa, paths)` (one item per file, as file URLs),
and `transfer.valueData(gpa, T, ptr)`, a Zig value of this process.

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

- `data.has(format)` tells whether an item offers a format, and
  `data.formats(a)` lists them all, without repeats.
- `data.preferred(wanted)` returns the first of `wanted` offered.
- `data.read(a, format)` returns its bytes, the items' coalesced as the
  systems' transfers do: text joined by newlines, URI lists by CRLF, other
  formats the first item's. Lazy providers run now. The bytes are in
  `a`'s memory: give it an arena.
- `data.files(a)` returns the local paths of a file list or URI list.
  `transfer.urlOfPath` and `transfer.pathOfUrl` convert between paths and
  `file:` URLs (`file:///C:/x` is `C:/x` on Windows).
- `data.value(T)` returns the value of type `T` the data offers, or null.
- `data.clone(gpa)` makes an independent copy, to keep data a drop handed
  over for one frame only.

### Values

`transfer.valueData(gpa, T, ptr)` offers a pointer to a Zig value under
the format `transfer.value_format(T)`
(`application/x-myzig-value;type=...`). It never leaves the process:
native data never holds a pointer, so values only reach drop targets of
the app's own windows, which read them with `data.value(T)`. Moving a task
from one list to another is that simple:

```zig
if (d.starting) d.offer(try transfer.valueData(gpa, Task, task));
// in the target:
if (t.dropped) |drop| drop.data.value(Task).?.done = true;
```

### Effects

A drag says what the drop may do with its data, a `transfer.Effects` of
`copy`, `move` and `link` (copy alone by default; `.copy_move` both), and a
target says what it accepts. `transfer.negotiate` picks the effect: the
one the modifier keys suggest when both ends allow it (Option copies and
Command moves on macOS; Ctrl copies and Shift moves elsewhere), else copy,
then move, then link. A source told `.move` removes its value.

## Files dropped on windows

A window with `on_drop` accepts files dragged onto it from Finder,
Explorer and file managers. The handler gets
their absolute paths, valid during the call:

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

It is `NSDraggingDestination` on macOS, GTK's drag destination on Linux
and `WM_DROPFILES` on Windows. Only files are accepted this way so far;
text and other formats dragged from other apps are not.

## Drags that leave the window

In native UI, a drag that leaves its window goes on in the system's drag
and drop, so that notes, text, URLs and files reach other windows and
other apps (a text editor, Explorer), when the window's `ui.DragDrop` has
an `external`:

```zig
const win = try app.newWindow(.{ .title = "Notes", .content = .{ .view = .init(&pane, Pane.view) } });
pane.dnd.external = myzig.systemDrag(win);
```

`myzig.systemDrag(win)` returns the system's drag where myzig has one, and
null elsewhere, where drags stay within their window:

- **Windows**: OLE's `DoDragDrop`, with an `IDataObject` offering the
  data's formats as other apps read them: `CF_UNICODETEXT` for text,
  `CF_HDROP` for files, "HTML Format", "PNG", and other MIME names as
  registered clipboard formats. Lazy providers run when the receiving app
  asks. Escape gives up; the drop's effect comes back to the source as
  its `finished.effect`.
- **macOS**: an AppKit dragging session (`beginDraggingSessionWithItems:`)
  of pasteboard items; **Linux**: GTK's drag, each format's bytes made
  when the app it drops on asks.

The source's `finished` (a `ui.DragFinished`) tells how it ended:
`effect` is what the target did, `canceled` that nothing dropped,
`escaped` that the user gave the drag up (Escape, `dd.cancel()`) rather
than let it go over no target, and `screen` where a drag that left the
window ended, in points from the primary display's top left (null for
one that ended in the window, at the pointer). A tab let go outside every
window, for example, is `canceled and !escaped` at `screen`: the app
opens a window for it there.

An `External` is a pair of a context and a `start` function, so an app can
plug in a drag of its own: `start` is called in the frame the pointer
leaves the window and must not block; later, outside the frame, it drags
`DragDrop.active`'s data, then calls `dd.externalEnd(.{ .effect = effect,
.escaped = escaped, .screen = point })` (`dd.externalDone(effect)` when
it knows no more; `.none` when nothing took it) and draws a frame.

## Drops from other apps

```zig
try myzig.systemDrop(window, &state.dnd, &.{"application/x-myapp"});
```

`myzig.systemDrop` makes a window of native UI take what other apps drag
onto it (text, URLs, HTML, files, images and the extra types named) into
its `ui.DragDrop` targets, as drags within the window are
([drag and drop](ui/drag-and-drop.md)): OLE's IDropTarget on Windows,
GTK's drag destination on Linux, NSDraggingDestination on macOS. Pages
take drops themselves, as browsers do.

## Platform differences

| | clipboard | files dropped on windows | drags out of the window |
|---|---|---|---|
| macOS | text, HTML, images, files | yes | NSDraggingSource |
| Linux | text, HTML, images, files | yes | GTK's drag source |
| Windows | text, HTML, images, files | yes | OLE |
| browsers | text | no | no |
