# Documents

Many apps edit files: a text editor, a drawing app, a notes app. Users
expect such apps to behave alike, as AppKit's `NSDocument` and SwiftUI's
`DocumentGroup` make them behave on the Mac: a window per document, a File
menu with New, Open, Open Recent, Save, Save As and Revert, a dot or an
asterisk while there are unsaved changes, a question before those changes
are lost, autosave, nothing lost in a crash, and files that other apps
change while they are open.

`myzig.Documents(T)` does all of this, on every platform, for documents
whose content is a Zig value of type `T`. The app says how to read a `T`
from a file's bytes and write it back, and how to make a document's
window; myzig does the rest. The `documents` example is a notes editor
built on it:

```sh
zig build run-documents                    # an untitled note
zig-out/bin/documents notes.md todo.txt    # these files
```

## Setting up

```zig
const std = @import("std");
const myzig = @import("myzig");

const Notes = myzig.Documents([]u8);

/// How a note's content is read and written: the file's text.
const Text = struct {
    fn read(gpa: std.mem.Allocator, bytes: []const u8) anyerror![]u8 {
        return gpa.dupe(u8, bytes);
    }
    fn write(_: std.mem.Allocator, content: *const []u8, w: *std.Io.Writer) anyerror!void {
        try w.writeAll(content.*);
    }
    fn free(gpa: std.mem.Allocator, content: []u8) void {
        gpa.free(content);
    }
    fn new(gpa: std.mem.Allocator) anyerror![]u8 {
        return gpa.alloc(u8, 0);
    }
    fn equal(a: *const []u8, b: *const []u8) bool {
        return std.mem.eql(u8, a.*, b.*);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const app = try myzig.App.create(init, .{ .name = "Notes", .file_extensions = &.{ "md", "txt" } });
    defer app.destroy();
    var host: myzig.DocumentHost = .{ .app = app };
    defer host.deinit();
    var editor: Editor = .{ .app = app, .host = &host };

    const data_dir = myzig.path(gpa, .data, app.options.name) catch null;
    defer if (data_dir) |d| gpa.free(d);
    const notes = try Notes.create(gpa, init.io, host.host(), .{
        .types = &.{
            .{ .name = "Markdown Document", .extensions = &.{ "md", "markdown" } },
            .{ .name = "Plain Text", .extensions = &.{"txt"} },
        },
        .read = Text.read,
        .write = Text.write,
        .free = Text.free,
        .new = Text.new,
        .equal = Text.equal,
        .window = .of(&editor, Editor.window),
        .app_name = app.options.name,
        .data_dir = data_dir,
    });
    defer notes.destroy();
    editor.notes = notes;

    app.options.on_open_file = .of(notes, Notes.openFile);
    try app.setMenu(&.{ .{ .role = .app_menu }, host.fileMenu(Notes, notes), .{ .role = .edit_menu }, .{ .role = .window_menu } });
    host.start(Notes, notes); // once the files the app was started with arrived
    try app.run();
}
```

`myzig.DocumentHost` is what documents need of the app: its dialogs,
timers, windows, file watches and recent documents. It is a small struct
made of the app (`.{ .app = app }`); `host.host()` hands it to
`Documents.create`. Documents only reach the app through it, which is how
their tests run without one.

## Documents and their content

`Documents(T).create(gpa, io, host, options)` takes:

- `types`: the kinds of files, each a `DocumentType` with a `name` that
  open dialogs show and its `extensions` (without dots, lower case). New
  documents are saved with the first type's first extension.
- `read`: makes a `T` from a file's bytes; an error leaves the file
  unopened and shows a message.
- `write`: writes a `T` as a file's bytes to a `std.Io.Writer`. Writes go
  to a temporary file which then replaces the document's, so a failed
  save never leaves half a file.
- `free`: frees a content the document no longer holds (optional for
  contents that own nothing).
- `new`: the content of a new document; `std.mem.zeroes(T)` without it.
- `equal`: compares two contents. With it, setting a content equal to what
  the file has makes the document unedited again, as undoing back to it
  does.
- `window`: makes a document's window (below).
- `autosave` (`.in_place` or `.off`), `autosave_delay_ms` (5000) and
  `backup_delay_ms` (1000), described below.
- `ask_on_quit`: ask to save at quit, rather than keep documents for the
  next launch.
- `no_untitled`: no untitled document when the app starts with nothing to
  open (an app that shows a start window instead).
- `strings`: the text of the messages and buttons, a `DocumentStrings`,
  in English by default, to translate.
- `app_name`: the app's name, in window titles off macOS.
- `data_dir`: the app's data directory, where recovery copies are kept;
  none are kept without it.
- `max_size`: the largest file read (1 GiB).

Each open document is a `Notes.Document`. Its `content` is the `T` it
owns. A view reads `doc.content`, and an edit gives the document a new
content or says the content changed:

- `doc.set(content)` replaces the content, which the document then owns,
  freeing the old one with `free`. It is an edit, unless `equal` says it
  is what the file has.
- `doc.changed()` says a mutable content was changed in place.
- `doc.setEdited(edited)` is for an app that knows better, from its own
  undo history: `false` makes the content count as the file's, without
  writing it.

`doc.state()` returns a `DocumentState` for the window's title and status:
its `name` (the file's, or "Untitled", "Untitled 2"...), its `path` (empty
when untitled), and whether it is `edited`, `read_only`, in `conflict`
(another app changed its file while it has unsaved changes) or `deleted`.

Two handlers on the document tell its window what happened:
`doc.on_reload` runs when the content was read from the file again
(reverted, or changed by another app), so the window shows the new
content; `doc.on_state` runs after the state changed. `Documents.on_change`
runs after any document's state changed, for the File menu.

## Windows

The window maker makes the window of a document, in native UI or with a
page, and returns it. `.of(&state, State.method)` takes a method
`fn (s: *State, doc: *Notes.Document) !*myzig.Window`:

```zig
const Editor = struct {
    app: *myzig.App,
    host: *myzig.DocumentHost,
    notes: *Notes = undefined,

    fn window(e: *Editor, doc: *Notes.Document) anyerror!*myzig.Window {
        const n = try e.app.gpa.create(Note);
        n.* = .{ .gpa = e.app.gpa, .doc = doc, .editor = .init(e.app.gpa, doc.content) };
        n.win = try e.app.newWindow(.{
            .title = doc.name(),
            .state = myzig.windowState("note"),
            .content = .{ .view = .init(n, Note.view) },
        });
        doc.on_reload = .of(n, Note.reloaded);
        doc.on_state = .of(n, Note.stateChanged);
        try e.host.attach(Notes, e.notes, n.win); // closing the window closes the document
        return n.win;
    }
};
```

Documents set their window's title: the document's name on macOS, and
elsewhere with an asterisk while edited and the app's name after it
(`*Notes.md - Notes`).

`host.attach(Notes, notes, win)` makes closing the window close its
document; the window's own `on_close` still runs. A window closed that way
keeps the document's unsaved changes in its recovery copy, so nothing is
lost. To ask before the window closes, as AppKit does, give the window an
`on_close_request` that asks the document, which saves or discards its
changes and tells whether it may close:

```zig
fn mayClose(n: *Note, _: *myzig.Window) bool {
    return !n.doc.edited or n.doc.askToSave();
}
// .on_close_request = .of(n, Note.mayClose),
```

A document's file may change while its window is in the background, where
the file watch might have missed it; call `notes.windowFocused(win)` and
`notes.windowBlurred(win)` from the window's `on_event` (`.focus`, `.blur`)
to look at the file when the window comes back, and to autosave when it
leaves, as Mac apps do.

## Opening

- `notes.new()` makes an untitled document in its window.
- `notes.open(path)` opens a file, or focuses its window when it is open
  already. It records the file in the recent documents.
- `notes.openDialog()` asks which files to open, of the documents' types.
- `notes.openFile(path)` opens a file the system hands the app, if it is
  one of its types (`handles`): give it to `AppOptions.on_open_file`, which
  receives the files of the app's `file_extensions` from Finder, Explorer,
  the command line and later instances of the app (see
  [the application](app.md)).
- `notes.start(paths)` opens what the app starts with: the documents a
  crash or a quit left with unsaved changes, then `paths`, else an
  untitled document. `host.start(Notes, notes)` calls it in the first turn
  of the loop, after the files the app was started with reached
  `on_open_file`.

`notes.find(path)`, `notes.forWindow(win)` and `notes.focused()` (the
document of the focused window) look documents up.

## Saving

- `doc.save()` does what File > Save does: an untitled document asks
  where to save it, a read-only one for another file, and one whose file
  another app changed whether to overwrite it (Save Anyway, Revert,
  Cancel). It returns false when the document isn't saved.
- `doc.saveAs(null)` asks where; `doc.saveAs(path)` saves there. A name
  without an extension gets the first type's.
- `doc.saveAnyway()` writes it even though another app changed its file.
- `doc.revert()` reads its file again, dropping its unsaved changes.
- `doc.duplicate()` opens an untitled copy ("Notes copy") in a window of
  its own.
- `doc.rename(new_name)` renames its file in its folder, and
  `doc.moveTo(dir)` moves it to another folder.
- `doc.close()` closes its window, asking to save first where it must, and
  returns false when it stays open.

A failed save shows a message with the error and keeps the changes.

## Autosave

With `autosave = .in_place` (the default), a document with a file saves
itself a moment after the user stops editing (`autosave_delay_ms`), at
least every 30 seconds while they keep editing, when its window loses the
focus and when it closes, as Mac apps do. Untitled, read-only and deleted
documents, and documents in conflict, don't autosave: their changes stay
in their recovery copies until the user saves.

With `.off`, documents save when the user saves, and closing a document
with unsaved changes asks whether to save them.

## Recovery copies

With a `data_dir`, a moment after the user stops editing
(`backup_delay_ms`) a document that has unsaved changes writes them to a
recovery copy, as VS Code's backups do, so that a crash, a forced quit or
a quit that keeps documents loses nothing. Copies are kept in
`<data>/Recovery/<kind>`, in a session of the running instance that a
locked file tells is alive: another instance of the app leaves it alone.
The next launch (`start`) opens the documents of the sessions no instance
holds, edited, with their unsaved changes. A file that changed meanwhile
is in conflict; a file that was deleted is `deleted`, and saving writes it
again.

Saving, reverting and discarding remove a document's copy.

## Quitting

`notes.quit()` quits once the documents are taken care of, and
`notes.prepareQuit()` only takes care of them and tells whether the app
may quit: autosaved documents are saved, the others keep their recovery
copies for the next launch, or with `ask_on_quit` the user is asked about
each (several at once: Save All, Don't Save, Cancel). Use it from the
app's own Quit menu item instead of the plain quit role.

`notes.destroy()` closes every document without asking: their unsaved
changes stay in their recovery copies.

## Files changed by other apps

Each open document watches its file (`myzig.file_watch`, see
[the system](system.md)). When another app changes it:

- a document without unsaved changes reads it again (`on_reload`);
- a document with unsaved changes is in `conflict`: its changes stay in
  its recovery copy, autosave stops, and the next save asks whether to
  overwrite the file or revert to it. The `documents` example shows a bar
  with Revert and Save in its window then;
- a file renamed or moved within its folder is followed: the document
  finds it by the identity of the file it last read or wrote (its inode,
  its file index on Windows, and its kind, so that a file reusing a
  removed one's inode is not taken for it), takes its new path, watches
  it and records it as recent. That holds for a file another app
  replaced, as editors save, and renamed right after: the document knows
  the file it read, not only the one it opened;
- a deleted file leaves its document open, `deleted`, and saving writes
  it again.

## The File menu

`host.fileMenu(Notes, notes)` returns the File menu: New, Open…, Open
Recent (with Clear Menu), Save, Save As…, Revert (Revert to Saved on
macOS) and Close, with their usual shortcuts, and Quit off macOS. Its
items act on the focused window's document. Its item ids start with
`documents.` (`documents.save`). Open Recent lists the app's recent
documents (`myzig.system.recentDocuments`); build the menu again and set
it with `app.setMenu` when they change, from `notes.on_change`. See
[menus](menus.md) for the rest of the menu bar.

## Platform differences

Documents behave the same everywhere; what differs is what they use:

- Window titles show the name alone on macOS, and `*Name - App` elsewhere.
- Recent documents also go to the system's lists: Open Recent and the
  Dock on macOS, Recent items and jump lists on Windows, recently used
  files on Linux.
- Dialogs are the system's ([the system](system.md) lists them); on
  Windows the open dialog chooses one file for now.
- In browsers there are no files to watch or dialogs that give paths:
  documents can't be opened there.

## What is left out

Next to `NSDocument`, there are no document versions (the Mac's Browse All
Versions), no iCloud documents, no document packages (folders shown as one
file), and no locked documents. Documents don't share an undo history with
the app: an app with its own (a text area's) tells documents with
`setEdited`.
