# Documents

`myzig.Documents(T)` gives a file-editing app what users expect of one, on
every platform. It works as AppKit's `NSDocument` and SwiftUI's
`DocumentGroup` do on the Mac:

- a window per document;
- a File menu with New, Open, Open Recent, Save, Save As and Revert;
- a dot or an asterisk while there are unsaved changes;
- a question before those changes are lost;
- autosave, and nothing lost in a crash;
- files that other apps change while they are open.

A document's content is a Zig value of type `T`. The app says how to read
a `T` from a file's bytes, how to write it back, and how to make a
document's window. myzig does the rest. The `documents` example is a notes
editor built on it:

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
timers, windows, file watches and recent documents.

- It is a small struct made of the app: `.{ .app = app }`.
- `host.host()` hands it to `Documents.create`.
- Documents reach the app only through it. That is how their tests run
  without an app.

## Documents and their content

`Documents(T).create(gpa, io, host, options)` takes:

| Option | Default | |
|---|---|---|
| `types` | | the kinds of files, each a `DocumentType` (below) |
| `read` | | makes a `T` from a file's bytes |
| `write` | | writes a `T` as a file's bytes to a `std.Io.Writer` |
| `free` | | frees a content the document no longer holds |
| `new` | `std.mem.zeroes(T)` | the content of a new document |
| `equal` | | compares two contents |
| `window` | | makes a document's window (see [Windows](#windows)) |
| `autosave` | `.in_place` | or `.off` (see [Autosave](#autosave)) |
| `autosave_delay_ms` | 5000 | the pause in editing before an autosave |
| `backup_delay_ms` | 1000 | the pause before a recovery copy |
| `ask_on_quit` | `false` | ask to save at quit, rather than keep documents for the next launch |
| `no_untitled` | `false` | no untitled document when the app starts with nothing to open |
| `strings` | English | the text of messages and buttons, a `DocumentStrings`, to translate |
| `app_name` | `""` | the app's name, in window titles off macOS |
| `data_dir` | `null` | where recovery copies are kept; none without it |
| `max_size` | 1 GiB | the largest file read |

- A `DocumentType` has a `name`, which open dialogs show, and its
  `extensions`: without dots, lower case. New documents are saved with the
  first type's first extension.
- A `read` error leaves the file unopened and shows a message.
- `write` goes to a temporary file, which then replaces the document's.
  A failed save never leaves half a file.
- `free` is optional for contents that own nothing.
- With `equal`, setting a content equal to the file's makes the document
  unedited again, as undoing back to it does.
- `no_untitled` suits an app that shows a start window instead.

Each open document is a `Notes.Document`. Its `content` is the `T` it
owns. A view reads `doc.content`. An edit gives the document a new content
or says the content changed:

| Call | |
|---|---|
| `doc.set(content)` | replaces the content, which the document then owns; frees the old one with `free`. An edit, unless `equal` says it is the file's |
| `doc.changed()` | a mutable content was changed in place |
| `doc.setEdited(edited)` | for an app that knows from its own undo history: `false` makes the content count as the file's, without writing it |

`doc.state()` returns a `DocumentState`, for the window's title and status:

- `name`: the file's, or "Untitled", "Untitled 2"...;
- `path`: empty when untitled;
- `edited`, `read_only`, `deleted`;
- `conflict`: another app changed its file while it has unsaved changes.

Handlers tell the window what happened:

- `doc.on_reload` runs when the content was read from the file again:
  reverted, or changed by another app. The window shows the new content.
- `doc.on_state` runs after the document's state changed.
- `Documents.on_change` runs after any document's state changed, for the
  File menu.

## Windows

The window maker makes a document's window, in native UI or with a page,
and returns it. `.of(&state, State.method)` takes a method
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

Documents set their window's title:

- on macOS, the document's name;
- elsewhere, an asterisk while edited and the app's name after it:
  `*Notes.md - Notes`.

`host.attach(Notes, notes, win)` makes closing the window close its
document. The window's own `on_close` still runs. A window closed that way
keeps the unsaved changes in the recovery copy, so nothing is lost.

To ask before the window closes, as AppKit does, give the window an
`on_close_request` that asks the document. The document saves or discards
its changes and tells whether the window may close:

```zig
fn mayClose(n: *Note, _: *myzig.Window) bool {
    return !n.doc.edited or n.doc.askToSave();
}
// .on_close_request = .of(n, Note.mayClose),
```

Call `notes.windowFocused(win)` and `notes.windowBlurred(win)` from the
window's `on_event` (`.focus`, `.blur`), as Mac apps do:

- on focus, the document looks at its file again, since the file watch
  may have missed a change while the window was in the background;
- on blur, it autosaves.

## Opening

| Call | |
|---|---|
| `notes.new()` | an untitled document in its window |
| `notes.open(path)` | opens a file, or focuses its window when it is open already; records it in the recent documents |
| `notes.openDialog()` | asks which files to open, of the documents' types |
| `notes.openFile(path)` | opens a file the system hands the app, if it is one of its types (`handles`) |
| `notes.start(paths)` | opens what the app starts with |
| `notes.find(path)`, `notes.forWindow(win)`, `notes.focused()` | look documents up; `focused` is the focused window's |

- Give `openFile` to `AppOptions.on_open_file`. It receives the files of
  the app's `file_extensions` from Finder, Explorer, the command line and
  later instances of the app (see [the application](app.md)).
- `start` opens the documents a crash or a quit left with unsaved
  changes, then `paths`, else an untitled document.
- `host.start(Notes, notes)` calls `start` in the first turn of the loop,
  after the files the app was started with reached `on_open_file`.

## Saving

| Call | |
|---|---|
| `doc.save()` | what File > Save does; false when the document isn't saved |
| `doc.saveAs(null)`, `doc.saveAs(path)` | asks where, or saves there |
| `doc.saveAnyway()` | writes it although another app changed its file |
| `doc.revert()` | reads its file again, dropping unsaved changes |
| `doc.duplicate()` | opens an untitled copy ("Notes copy") in a window of its own |
| `doc.rename(new_name)` | renames its file in its folder |
| `doc.moveTo(dir)` | moves its file to another folder |
| `doc.close()` | closes its window, asking to save first where it must; false when it stays open |

- `save` on an untitled document asks where to save it.
- `save` on a read-only one asks for another file.
- `save` on one whose file another app changed asks whether to overwrite
  it: Save Anyway, Revert, Cancel.
- A name without an extension gets the first type's.
- A failed save shows a message with the error and keeps the changes.

## Autosave

With `autosave = .in_place`, the default, a document with a file saves
itself, as Mac apps do:

- a moment after the user stops editing (`autosave_delay_ms`);
- at least every 30 seconds while they keep editing;
- when its window loses the focus, and when it closes.

Untitled, read-only and deleted documents don't autosave, nor do documents
in conflict. Their changes stay in their recovery copies until the user
saves.

With `.off`, documents save when the user saves. Closing a document with
unsaved changes asks whether to save them.

## Recovery copies

With a `data_dir`, a document with unsaved changes writes them to a
recovery copy a moment after the user stops editing (`backup_delay_ms`).
It works like VS Code's backups. A crash, a forced quit or a quit that
keeps documents loses nothing.

- Copies are kept in `<data>/Recovery/<kind>`, in a session of the running
  instance. A locked file tells the session is alive, so another instance
  of the app leaves it alone.
- The next launch (`start`) opens the documents of the sessions no
  instance holds: edited, with their unsaved changes.
- A file that changed meanwhile is in conflict.
- A file that was deleted is `deleted`, and saving writes it again.
- Saving, reverting and discarding remove a document's copy.

## Quitting

- `notes.quit()` quits once the documents are taken care of.
- `notes.prepareQuit()` only takes care of them, and tells whether the app
  may quit. Use it from the app's own Quit menu item instead of the plain
  quit role.
- `notes.destroy()` closes every document without asking. Their unsaved
  changes stay in their recovery copies.

Taking care of the documents means:

- autosaved documents are saved;
- the others keep their recovery copies for the next launch;
- or, with `ask_on_quit`, the user is asked about each. Several at once
  get Save All, Don't Save, Cancel.

## Files changed by other apps

Each open document watches its file (`myzig.file_watch`, see
[the system](system.md)). When another app changes it:

- A document without unsaved changes reads it again (`on_reload`).
- A document with unsaved changes is in `conflict`. Its changes stay in
  its recovery copy, autosave stops, and the next save asks whether to
  overwrite the file or revert to it. The `documents` example then shows a
  bar with Revert and Save in its window.
- A file renamed or moved within its folder is followed. The document
  takes its new path, watches it and records it as recent.
- A deleted file leaves its document open and `deleted`. Saving writes it
  again.

<details><summary>How a moved file is found</summary>

The document finds the file by the identity of the file it last read or
wrote: its inode (its file index on Windows) and its kind. The kind keeps
a file that reuses a removed one's inode from being taken for it.

This holds for a file another app replaced, as editors save, and renamed
right after. The document knows the file it read, not only the one it
opened.

</details>

## The File menu

`host.fileMenu(Notes, notes)` returns the File menu, with the usual
shortcuts:

- New, Open…, Open Recent (with Clear Menu);
- Save, Save As…, Revert (Revert to Saved on macOS) and Close;
- Quit, off macOS.

Its items act on the focused window's document. Their ids start with
`documents.` (`documents.save`).

Open Recent lists the app's recent documents
(`myzig.system.recentDocuments`). When they change, from
`notes.on_change`, build the menu again and set it with `app.setMenu`. See
[menus](menus.md) for the rest of the menu bar.

## Platform differences

Documents behave the same everywhere. What differs is what they use:

- Window titles show the name alone on macOS, and `*Name - App` elsewhere.
- Recent documents also go to the system's lists: Open Recent and the
  Dock on macOS, Recent items and jump lists on Windows, recently used
  files on Linux.
- Dialogs are the system's ([the system](system.md) lists them). On
  Windows the open dialog chooses one file for now.
- In browsers there are no files to watch, and no dialogs that give
  paths. Documents can't be opened there.

## What is left out

Next to `NSDocument`, there are:

- no document versions (the Mac's Browse All Versions);
- no iCloud documents;
- no document packages (folders shown as one file);
- no locked documents.

Documents don't share an undo history with the app. An app with its own,
such as a text area's, tells documents with `setEdited`.
