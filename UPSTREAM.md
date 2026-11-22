# Upstream: mygo

myzig ports [mygo](https://github.com/egoist/mygo). This page records how far
it follows it, so the next review starts where this one ended.

**Listed through mygo `a0eaaaaf` (2026-11-23); reviewed in detail through
`afff19d9` (2026-11-03).** Every mygo commit up to `a0eaaaaf` is listed below.
The 692 after `afff19d9` were triaged for bug fixes: those ported, present
or not applicable say so, and the rest are **pending**, for the next reviews
to go through in order. New commits start from:

```sh
cd ../mygo && git fetch && git log --reverse --oneline a0eaaaaf..origin/main
```

When a review is done, move the commit above to the newest one reviewed, add
its commits to the table, and keep `THIRD_PARTY_NOTICES.md` in step.

Statuses:

- **ported**: myzig has the change.
- **n/a**: it does not apply to myzig (the note says why).
- **skip**: not code myzig carries (mygo's website, showcase, releases, CI,
  Go-only tooling).
- **present**: myzig already behaved so before the commit (the note says where).
- **todo-S / todo-M / todo-L**: applies and is still to port; S is under about
  60 lines of Zig, M up to about 300, L a new feature. The note says what and where.
- **deferred**: applies, but not ported yet for the reason noted.
- **pending**: not reviewed in detail yet.

Commits before `976f17c9` are covered by the baseline in
`THIRD_PARTY_NOTICES.md`.

| mygo | date | subject | status | note |
|---|---|---|---|---|
| `1c058ab7` | 2026-10-16 | Call DocumentsOptions.Equal with the document's lock down | n/a | documents have no mutex |
| `d73af4e1` | 2026-10-18 | Merge remote-tracking branch 'origin/main' into pr/417 | skip |  |
| `d89af4a6` | 2026-10-22 | Block what pages load with content rules in WebKit's format (#621) | todo-L | content rules (content blocking) |
| `bb54c3dc` | 2026-10-22 | text, ui: cache a large paragraph beside live layouts; look for inline transforms once per text (#640) | n/a | layout cache has no size cap or inline transforms walk |
| `bada9ca8` | 2026-10-22 | Merge branch 'pr/417' into claude/project-thread-cyuo3d | skip |  |
| `65e61503` | 2026-10-22 | Settle Equal's answer after a save by the change count, not the values | n/a | follow-up of the Go mutex fix |
| `5bb0f957` | 2026-10-22 | Merge pull request #641 from egoist/claude/project-thread-cyuo3d | skip |  |
| `321cdfbd` | 2026-10-22 | windows: take WebView2 event token addresses in the call (#647) | n/a | Go-specific |
| `5caa69f2` | 2026-10-22 | windows: keep the task dialog's results off the moving stack (#645) | n/a | Go-specific |
| `c4d36967` | 2026-10-23 | metal: sample the glyph atlases at level 0 explicitly (#650) | n/a | Metal reads atlases with read() |
| `2fde45ad` | 2026-10-23 | ui: take a text field's keys, so Edit › Paste's Ctrl+V pastes once on Windows (#658) | present | accelerator runs once (windows/surface.zig) |
| `15242900` | 2026-10-23 | Release 0.6.3 | skip |  |
| `6e214fb0` | 2026-10-23 | examples/terminal: wait for the window in OnTitle and OnExit (#669) | skip |  |
| `5a134b43` | 2026-10-23 | ui: make each Han ideograph and kana a word of its own (#671) | todo-M | each Han ideograph and kana a word |
| `6a175bd2` | 2026-10-23 | windows: gofmt webview_embed.go (#672) | skip |  |
| `7d2223ef` | 2026-10-23 | Tell a flyout's content no material shows before Windows 11 22H2 (#678) | n/a | flyouts have no material |
| `7a8d3a3c` | 2026-10-24 | Drag the terminal's scroll bar, which shows and hides as macOS's do (#679) | todo-M | terminal scroll bar drag and fade |
| `23e0e56f` | 2026-10-24 | linux: make a GtkGLArea's context current again before drawing into it (#681) | todo-S | GtkGLArea context current before drawing |
| `26a1300f` | 2026-10-24 | text: write Linux font cache through a unique temporary file (#683) | n/a | no font cache file |
| `76ccea0d` | 2026-10-24 | editor: lex Python's single-quoted f-strings without a panic (#684) | n/a | no f-string stack |
| `4b839bc5` | 2026-10-24 | darwin: go back and forward with swipes (#685) | todo-S | macOS swipes go back and forward (router) |
| `c0c4c423` | 2026-10-24 | watch: a file replaced at its path is written (#686) | present | a replaced file is written (watch snapshot.zig) |
| `a7a3be25` | 2026-10-24 | terminal: mirror the mouse's modes in the order that picks them (#688) | n/a | terminal has no Mirror |
| `818f07e2` | 2026-10-24 | terminal: mirror the modes the keys' encoding takes (#689) | n/a | terminal has no Mirror |
| `a39f5439` | 2026-10-24 | linux: destroy a window closed in its own frame after the frame (#674) | todo-S | Linux: destroy a window closed in its own frame after it |
| `53c7746d` | 2026-10-24 | raster: give a frame its own VirtualAlloc on Windows (#691) | n/a | Zig allocators map large frames |
| `165bc985` | 2026-10-24 | l10n: translate MyGo's own strings to Japanese (#692) | ported | Japanese strings (l10n) |
| `150f5bb2` | 2026-10-24 | terminal: draw Powerline's rounded caps to the cell's height (#694) | n/a | terminal uses the font's Powerline glyphs |
| `3032f26b` | 2026-10-24 | linux: shape a drawing area's window so web views show through it (#695) | n/a | web views above the drawing area in an overlay |
| `7a93a9c7` | 2026-10-24 | terminal: show images through Unicode placeholders (Kitty graphics) (#696) | n/a | terminal refuses Kitty graphics |
| `23ac61d8` | 2026-10-24 | darwin: turn off AppKit's AutoFill heuristics (#699) | ported | macOS: AutoFill heuristics off |
| `044b7c85` | 2026-10-24 | cli: take a package.json for a frontend only when it depends on mygo-runtime (#700) | n/a | cli picks the frontend by directory |
| `2317b809` | 2026-10-24 | darwin: turn off AutoFill heuristics on macOS 27 too (#701) | ported | macOS 27: AutoFill heuristics off |
| `189c8b3a` | 2026-10-24 | Define the unregistered MIME types an app names for its files on Linux (#634) | ported | cli: define unregistered x- MIME types |
| `ce9ff87a` | 2026-10-24 | Add linker flags to builds with MYGO_LDFLAGS (#642) | skip |  |
| `d70ef8ec` | 2026-10-24 | windows: fit a line in the width it measured (#661) | n/a | DirectWrite lays out unwrapped |
| `b77083b7` | 2026-10-24 | chore(security): update Go toolchain to 1.27.3 (#616) | skip |  |
| `95fc6466` | 2026-10-24 | Keep the release that comes while its press is handled (#633) | todo-S | Linux: keep a release that comes during its press's frame |
| `7e132cfb` | 2026-10-24 | Find a long line's visual caret stops in linear time (#584) | n/a | no visual caret-stop sweep |
| `1549ce9b` | 2026-10-24 | Show the colors of an element that comes back with a route change at once (#697) | present | route pages keyed by history entry (router_view.zig) |
| `156c6af6` | 2026-10-24 | Fix terminal links for bare filenames (#646) | ported | terminal links for bare filenames |
| `80499935` | 2026-10-24 | Fix edge scrolling during native data drags (#607) | n/a | drag and drop has no edge scrolling |
| `d1a2caf7` | 2026-10-25 | editor: shape bold and italic tokens in their faces (#707) | todo-M | editor bold/italic tokens in their faces |
| `d2907627` | 2026-10-25 | linux: answer the panel's activation with Tray.OnClick (#706) | ported | Linux tray activate signal |
| `9c69cf82` | 2026-10-25 | fix(terminal): ignore momentum scrolling for zoom (#709) | n/a | terminal has no zoom |
| `d4067ac1` | 2026-10-25 | editor: fold a run of imports, per language (#711) | n/a | editor has no folding |
| `4b236c48` | 2026-10-25 | windows: treat web error status 14 as a canceled navigation (#712) | ported |  |
| `a21e138f` | 2026-10-25 | fix(windows): keep window.opener for popups (#710) | n/a | pages open no popup windows of their own |
| `6255ea40` | 2026-10-25 | Release 0.6.4 | skip |  |
| `c1b67c81` | 2026-10-25 | Let a decoded bitmap drop its CPU pixels once the GPU has them (#717) | todo-M | decoded bitmap drops CPU pixels after upload |
| `d918a143` | 2026-10-25 | Give windows macOS 26's Liquid Glass, frameless windows rounded corners, and an active look that keeps the clear glass clear (#719) | todo-L | Liquid Glass, frameless corner radius |
| `30131d62` | 2026-10-25 | Keep DWM's caption buttons off frameless windows with a material (#721) | ported |  |
| `4a08d20d` | 2026-10-25 | Resize frameless windows from their top edge on Windows (#722) | todo-M | Windows: frameless windows resize from the top edge |
| `138c63bf` | 2026-10-25 | Now Playing and the media keys (mygo.NowPlaying) (#654) | todo-L | Now Playing and media keys |
| `c1c7a770` | 2026-10-25 | windows, ui: describe frames to UI Automation without allocating (#724) | present | UIA tree without per-frame allocation (access_tree.zig) |
| `c26e460d` | 2026-10-25 | Cut clips that are only moved as plain rectangles (#726) | present | moved clips as plain rects (paint_xf.zig) |
| `a5eaa8d0` | 2026-10-25 | linux: let GTK draw the shadow of frameless windows on Wayland (#727) | todo-S | Wayland: GTK draws frameless windows' shadow |
| `38c9fa7f` | 2026-10-25 | ui/editor: tint ranges of text within lines, scroll in DIPs, and reveal an app text field's caret on focus (#728) | todo-M | editor: tint text ranges, scroll in DIPs |
| `db14b9d6` | 2026-10-25 | linux: hide the menu bar of a window with a hidden title bar (#734) | n/a | no per-window GTK menu bar |
| `042dfd17` | 2026-10-25 | Maximize windows without a maximize box into the work area on Windows (#723) | ported |  |
| `15a16542` | 2026-10-25 | windows: serve custom scheme URLs with any host, not only localhost (#733) | todo-M | Windows: custom scheme URLs with any host |
| `1954c88b` | 2026-10-25 | docs: state what trusted pages may do, custom schemes included (#731) | n/a | docs only |
| `4047d037` | 2026-10-25 | Let glass panes as large as sidebars be clearer, with Clarity (#736) | todo-S | glass plugin: clarity |
| `610df69c` | 2026-10-25 | Let Markdown draw inline math on the text baseline (#737) | todo-L | markdown inline math |
| `fd65b095` | 2026-10-25 | examples/embed-webview: draw nothing until the web views are made (#740) | skip |  |
| `a58508e3` | 2026-10-25 | Wait for TestGlass's window to draw inactive, not only for the Finder in front (#742) | skip |  |
| `657da349` | 2026-10-25 | Let audio mix further ahead for music, with audio.SetLatency (#743) | todo-S | audio.setLatency |
| `3ebe95cc` | 2026-10-25 | website: add a Showcase page for apps built with mygo (#744) | skip |  |
| `3d452cb5` | 2026-10-25 | Make audio.Player.Position say where a player is heard, not mixed (#746) | todo-M | audio Player.position as heard |
| `a5145e19` | 2026-10-26 | Relaunch through Launch Services on macOS, so the new instance has a coalition of its own (#747) | todo-S | macOS relaunch through Launch Services (open -n) |
| `174a1ca5` | 2026-10-26 | Let drawings ask for fewer frames, with Painter.AnimationFrameRate (#753) | todo-M | Painter.animationFrameRate |
| `88d1f15e` | 2026-10-26 | Redraw several damage rectangles on the GPU, not their union (#754) | todo-M | GPU renderers redraw several damage rects |
| `070096db` | 2026-10-26 | ui: wait on the repaint timer for paced frames on Windows (#756) | todo-S | Windows paced frames on the repaint timer (with 174a1ca5) |
| `780796c6` | 2026-10-26 | Draw rings and shadows with round corners in bands that follow them (#757) | todo-M | renderer: rings and round shadows in bands (hillclimb) |
| `204fca99` | 2026-10-26 | Install scripts for macOS and Windows, and signature checks in install.sh on Linux (#748) | todo-L | cli: install scripts and checksums |
| `587f0c5d` | 2026-10-26 | Hold frames drawn in memory on Windows to the display's refreshes (#758) | present | Windows animation frames from a 16 ms timer (surface.zig) |
| `e39bd36f` | 2026-10-26 | Paint again only the drawings that asked, in frames that only paint (#759) | n/a | immediate mode: no paint-only frames |
| `e9796b74` | 2026-10-26 | Keep a still subtree in a bitmap of its own with Element.Cache (#760) | todo-L | Element.cache subtree bitmap |
| `74f2eedb` | 2026-10-26 | updater: let apps offer prereleases to users who chose a beta (#761) | todo-M | updater: prereleases for beta users |
| `f09d7d2f` | 2026-10-26 | Draw a window's buttons light or dark whatever the app's appearance (#763) | todo-S | window buttons light/dark override (Windows caption) |
| `5780de5c` | 2026-10-26 | Test that bordered cards draw their straight edges as the CPU renderer does (#531) (#762) | skip |  |
| `477eae5f` | 2026-10-26 | Keep a macOS tray title's width steady as its digits change (#766) | ported | macOS tray title monospaced digits |
| `56beb962` | 2026-10-26 | Don't wait twice on a frame latency object that timed out (#767) | present | no double wait on a timed-out frame latency (surface_present.zig) |
| `304f1c5f` | 2026-10-26 | Let apps choose the slug that names their files, and read CJK names into slugs (#768) | todo-M | cli: slug option, CJK names into slugs |
| `ee77c770` | 2026-10-26 | Name disk images and Windows installers after the slug (#769) | ported | cli: name dmg and installer after the slug |
| `e112e5ef` | 2026-10-26 | Paint a window whole after another window moved the glyphs it draws (#770) | n/a | follow-up of paint-only frames |
| `b343bbf7` | 2026-10-26 | Paint a window whole after it drew masks for its frame alone (#771) | n/a | follow-up of paint-only frames |
| `9b0de235` | 2026-10-26 | Add Element.Hidden, which hides an element and takes its room away (#772) | todo-M | Element.hidden (display none) |
| `bae6bfce` | 2026-10-26 | Send mygo-updater as the updater's User-Agent, not the app's name (#773) | present | updater User-Agent myzig-updater (updater.zig) |
| `d9d45f41` | 2026-10-26 | Stroke paths with butt and square caps, miter and bevel joins, and dashes (#774) | present | stroke caps, joins, dashes (path_stroke.zig) |
| `be164835` | 2026-10-26 | Show the update window of a background check as Sparkle does (#775) | todo-M | updater: background check window as Sparkle |
| `6a95d8f8` | 2026-10-26 | Show icons on menu items, tray menus included (#776) | todo-L | menu item icons |
| `15cb4a34` | 2026-10-26 | Add Page.ProcessID, the ID of the process that runs a page (#777) | ported | Page.processId |
| `9bf2ce49` | 2026-10-26 | Add Page.ThemeColor and OnThemeColorChanged (#778) | todo-M | Page.themeColor and its change event |
| `37f56f6b` | 2026-10-26 | Add Page.IsAudible, OnAudibleChanged and SetAudioMuted (#781) | todo-M | Page.isAudible, audible event, setAudioMuted |
| `aa76a3d7` | 2026-10-26 | Let Windows show the app by another name than its executable's (#782) | todo-M | cli: windows.display_name |
| `1bb35e26` | 2026-10-26 | Scroll a terminal three rows a wheel notch on Windows, not seven (#784) | present | terminal wheel notch about 3 rows (view.zig) |
| `07ebe19a` | 2026-10-26 | Tell a window-open handler whether a user's gesture opened the window (#785) | ported | NewWindow.user_gesture |
| `2311f8c2` | 2026-10-26 | Size a flyout or a window to its page's content (#787) | todo-L | size a window or flyout to its page's content |
| `b8a5225d` | 2026-10-26 | editor: highlight Dart, GraphQL, R and Scala (#788) (#791) | present | Dart, GraphQL, R, Scala in highlight_langs.zig, shared by the editor |
| `558e4981` | 2026-10-26 | Delete a Mirror's images by their ids when it starts the other terminal over (#792) | n/a | terminal has no Mirror |
| `8006903c` | 2026-10-26 | ui: let a field's box give AutoFocus and Focus to its input (#793) | present | field box focuses its input (controls_fields.zig) |
| `4dcc873e` | 2026-10-26 | Fold clips that only translate, rather than mask them each frame (#795) | present | translating clips fold into instances (paint_xf.zig) |
| `3407c872` | 2026-10-26 | Let Shift-click extend terminal selections (#590) | ported | terminal: Shift-click extends the selection (view.zig, select.zig) |
| `43199d0b` | 2026-10-27 | linux: scroll, pinch and tap with a touchscreen in native UI (#800) | todo-M | Linux touchscreen scroll/pinch/tap (linux/surface.zig) |
| `b0a8b3f7` | 2026-10-27 | macOS: move the window with a drag region's quick press and drag (#765) | todo-M | macOS drag region quick press-and-drag fallback |
| `2a6c4c59` | 2026-10-27 | Keep child windows above their parent without pinning them to its display on macOS (#764) | n/a | no child windows |
| `91d105a0` | 2026-10-27 | ui: zoom a window's content sharply, with Context.SetZoom (#739) | todo-L | whole-content zoom (Context.setZoom scales text only) |
| `ecc28a27` | 2026-10-27 | darwin: read numbers set as a text field's AXValue (#803) | todo-S | access_mac: read NSNumber AXValue of a text field |
| `ee5f5374` | 2026-10-27 | Windows: keep the accent color off the top of a window with a hidden title bar (#804) | ported |  |
| `1155c96d` | 2026-10-27 | Never stay behind, unable to quit, when the event loop goes on after a quit (#805) | ported |  |
| `e9f98e42` | 2026-10-27 | updater: replace the macOS bundle once the app has exited, so the Dock keeps its tile (#806) | n/a | updater swaps the executable, not a bundle |
| `fc3355d6` | 2026-10-27 | Release 0.7.0 | skip |  |
| `21ad2338` | 2026-10-27 | ui: a line height for text shaped with ShapeText and ShapeRichText (#808) | n/a | no public ShapeText; TextStyle has leading |
| `02d3d795` | 2026-10-27 | website: add Pulse, Kero, Lorca, MyGo 云音乐 and more to the showcase (#809) | skip |  |
| `da3657e7` | 2026-10-27 | macOS: leave a drag region's window to the window server once it begins (#811) | todo-S | macOS drag region: leave the move to the window server (with b0a8b3f7) |
| `76dd068b` | 2026-10-27 | Release 0.7.1 | skip |  |
| `834d3b0d` | 2026-10-27 | macOS: take a Control-click on a tray icon for a right-click (#818) | n/a | tray has no right-click callback |
| `5a374d9c` | 2026-10-27 | cli: hooks for the Windows installer (#819) | ported | cli: Windows installer hooks (.nsh include) |
| `4426e328` | 2026-10-27 | ci: keep the Linux packages in the Actions cache, and cancel superseded runs on main (#812) | skip |  |
| `e8cf6079` | 2026-10-27 | updater: get updates from a source the app supplies (#820) | todo-M | updater: app-supplied update source |
| `c637faed` | 2026-10-27 | windows: show what is behind transparent windows of native UI (#660) | n/a | no transparent windows option |
| `df5074b6` | 2026-10-27 | ui: name rows by the Labels of what is inside them (#826) | present | rows named by their labels (access_tree.zig) |
| `8e7c49cf` | 2026-10-27 | ui: pass the wheel a handler leaves to the handlers around it (#827) | present | wheel passes outward (gesture.zig) |
| `d20c33a9` | 2026-10-27 | netproxy: follow the system's proxy settings in Go's requests (#799) | skip |  |
| `a9b1c1a6` | 2026-10-27 | mygo: let apps show someone else's pages as untrusted (#829) | todo-M | untrusted pages option |
| `8f71c8e6` | 2026-10-27 | windows: hide embedded web views while their window is hidden (#831) | n/a | embedded pages are child HWNDs |
| `8820ebbe` | 2026-10-27 | cli: let macos.icon be an .icns, for an icon drawn per size (#833) | ported | cli: macos.icon as .icns |
| `b553a90a` | 2026-10-27 | cli: describe the .icns of macos.icon in the config types (#835) | n/a | TypeScript config typings only |
| `41ec785c` | 2026-10-27 | ui: play videos in native UI, starting with animated GIFs (#839) | todo-L | GIF/video in native UI |
| `ccb2aef8` | 2026-10-27 | linux: render the GL area only when the content asks (#841) | todo-S | Linux GL area: render only when asked (gl_gtk.zig) |
| `d9d1ef6d` | 2026-10-28 | mygo: HTTP sign-in and certificate errors for pages (#845) | todo-L | HTTP auth and certificate errors for pages |
| `32188db2` | 2026-10-28 | mygo: let pages go back with a swipe and zoom with a pinch (#846) | todo-M | page swipe back/forward and pinch zoom options |
| `f55d12c5` | 2026-10-28 | page: save and restore a page's back/forward list and scroll positions (#844) | todo-M | save/restore back-forward list and scroll |
| `10c50339` | 2026-10-28 | mygo: let pages' videos go into picture in picture (#842) | todo-M | picture in picture for pages |
| `2c515343` | 2026-10-28 | mygo: sessions, website data stores chosen per page (#848) | skip |  |
| `95de2cdc` | 2026-10-28 | mygo: tell and mute a page's camera, microphone and display capture (#843) | todo-L | report/mute page camera, mic, display capture |
| `510c23ba` | 2026-10-28 | Add PageOptions.BackgroundThrottling to keep hidden pages running (#847) | todo-M | PageOptions.background_throttling |
| `2443e26f` | 2026-10-28 | page: change or replace the web view's own context menu (#849) | todo-L | change/replace the web view's context menu |
| `7e510df9` | 2026-10-28 | richtext: indent or space body paragraphs, tell where paragraphs are, keep their IDs (#850) | todo-M | richtext paragraph indent/spacing/ids |
| `fe62eb8c` | 2026-10-28 | Add plugins/automation: drive a running app from another process (#851) | todo-L | plugins/automation |
| `34c735c3` | 2026-10-28 | ui: draw context menus in the window with PopoverMenu (#852) | present | context menus drawn in the window (ui/menu.zig) |
| `a8f25edb` | 2026-10-28 | ui: lines of a TextLayout, justified and indented paragraphs, soft hyphens, baseline shift (#853) | todo-L | TextLayout lines, justify, indent, soft hyphens, baseline shift |
| `39a5ebbc` | 2026-10-28 | cli: name the Windows install folder with windows.installDirName (#854) | ported | cli: windows.install_dir_name |
| `519631ea` | 2026-10-28 | windows: show the content's background, not black, where a window grows (#855) | deferred | needs a visual check on a real machine |
| `03ac0702` | 2026-10-28 | page: let a window's page play audible media without a user gesture (#856) | todo-M | pages play audible media without a gesture |
| `06d3a311` | 2026-10-28 | raster: make the pixels of an image with a transform again (#858) | present | image with transform after pixels released (raster_xf.zig) |
| `002a1ea1` | 2026-10-28 | updater: show an error's detail in full, without a tooltip over the title (#859) | present | updater error detail in full (window_view.zig) |
| `b02f1398` | 2026-10-28 | showcase: MixMusic now uses native UI, add its screenshot (#860) | skip |  |
| `6869c34f` | 2026-10-28 | showcase: add Liubai (留白), a Markdown editor and reader (#861) | skip |  |
| `b7c1f06a` | 2026-10-28 | showcase: add Clipnest, Cleanzo and Little Reef (小海底) (#862) | skip |  |
| `87412519` | 2026-10-28 | showcase: add MyTwig, a Git client (#863) | skip |  |
| `642005fd` | 2026-10-28 | linux: keep a frame asked for within the GL area's render signal (#866) | n/a | frames are not built inside the GL render signal |
| `ceab6416` | 2026-10-28 | ui: add DecodeImage and ImageSize (#868) | todo-S | DecodeImage and ImageSize for SVG too |
| `f9456cc3` | 2026-10-28 | showcase: add Godwit, an AI-native email client (#869) | skip |  |
| `3d9d668c` | 2026-10-28 | page: run the preload script in iframes with PreloadAllFrames (#871) | ported | UserScript.all_frames |
| `e5547238` | 2026-10-28 | ui: center the calendar's month chevrons (#874) | ported | calendar chevrons drawn centered |
| `aa753d22` | 2026-10-29 | linux: defer a window's Hide asked for within its own frame (#877) | n/a | views do not run inside GL render |
| `ac4e0ff0` | 2026-10-29 | editor: continue deletion bars' stripes across lines (#880) | n/a | diff view has no striped bars |
| `a43cfed3` | 2026-10-28 | Release 0.7.2 | skip |  |
| `f27a1253` | 2026-10-29 | ui: forward Placeholder to the input of SearchField, TokenField and Combobox (#884) | present | placeholder forwarded (controls_fields.zig, combobox.zig) |
| `bca8cf33` | 2026-10-29 | macOS: show dialogs opened from a click in native UI (#885) | n/a | click frames run in mouse handlers |
| `d7282567` | 2026-10-29 | ui: draw a menu button's menu in the window with PopoverMenuButton (#886) | present | menuButton draws its menu in the window (menu.zig) |
| `4aca72f1` | 2026-10-29 | ui: run a window's Cmd+V from the Edit menu's Paste on macOS (#889) | present | paste: sends Cmd+V to the view (ui/surface.zig) |
| `cbee0b21` | 2026-10-29 | terminal: scale scrolling with Options.ScrollMultiplier, as Ghostty's mouse-scroll-multiplier (#891) | ported | terminal scroll multiplier |
| `c1467c1a` | 2026-10-29 | windows: stop magnifying a native UI window's frames while it resizes (#893) | deferred | needs a visual check on a real machine |
| `6f28d7bb` | 2026-10-29 | Release 0.7.3 | skip |  |
| `23bef6cc` | 2026-10-29 | windows: show the background, not black, where a native UI window shrinks (#895) | deferred | needs a visual check on a real machine |
| `85fd4bba` | 2026-10-29 | ui: open a drawn menu at the pointer on an element scrolled partly out of view (#896) | present | context menus open at the pointer (menu.zig) |
| `2de039ab` | 2026-10-29 | linux: let linux.command name several commands (#900) | ported | cli: linux.command lists several |
| `4712173a` | 2026-10-29 | idlemem: end a Windows app's processes before the next run, and show why an app exited (#901) | skip |  |
| `b7e6bdd3` | 2026-10-29 | ui: let a Calendar page through months without choosing, with Browse (#903) | ported | calendar browse |
| `c18c0df0` | 2026-10-29 | cli: add mygo build -skip-installer, which makes no Windows installer nor downloads NSIS (#902) | ported | cli: --skip-installer |
| `813ee465` | 2026-10-29 | ui: size a grid child's percentages by its cell, not the grid (#909) | present | grid children sized by cell (grid_layout.zig) |
| `fed2cc29` | 2026-10-29 | ui/editor: hatch a diff's fillers with the stripes in sight, as diagonals (#911) | n/a | diff has no filler rows |
| `34d88970` | 2026-10-29 | windows: read the clipboard's other representations when one can't be read (#912) | n/a | clipboard reads each format alone |
| `977740fc` | 2026-10-29 | ui: radial gradients, with Painter.FillRadialGradient and Element.RadialGradient (#910) | present | radial gradients (gradient.zig, canvas_paint.zig) |
| `44eb2900` | 2026-10-29 | windows: keep a native UI window out of sight until its first frame, and draw it while hidden (#913) | deferred | needs a visual check on a real machine |
| `0cb6d05d` | 2026-10-29 | linux, macOS: draw the first frame of a native UI window made hidden, so it becomes ready to show (#915) | n/a | no ready-to-show event |
| `1a96794e` | 2026-10-29 | windows: show a frameless window's content up to its edges on Windows 10 (#918) | todo-S | Windows 10 frameless content to its edges (frame.zig) |
| `fb326e4e` | 2026-10-29 | showcase: add Video-Downloader app to showcase (#917) | skip |  |
| `e5137a83` | 2026-10-29 | showcase: add Lumilo (#919) | skip |  |
| `64575a41` | 2026-10-30 | windows: keep the items of drawn menus from clipping their labels (#923) | n/a | no owner-drawn menus |
| `003c212e` | 2026-10-30 | terminal: draw block sextants to fix Expo QR code rendering (#920) | todo-M | terminal: block sextants; myzig draws no box characters yet (mygo box.go not ported) |
| `58c3edc2` | 2026-10-30 | Convert disk images with diskutil where hdiutil convert fails (#925) | ported | cli: diskutil when hdiutil convert fails |
| `d40aa879` | 2026-10-30 | ui: let an element ignore the pointer and the keyboard, still pressed by assistive technology (#927) | todo-M | ignore_input style |
| `2b66322a` | 2026-10-30 | macOS: count the run loop's passes only after a frame, so an idle window stops waking Go (#928) | n/a | no repeating run loop observer |
| `afdd70df` | 2026-10-31 | ui: let a subtree use another theme with Themed (#932) | todo-S | themed subtree |
| `43e3a3e6` | 2026-10-31 | linux: write a PKGBUILD next to the archive, so makepkg -si installs the app on Arch Linux (#934) | todo-M | cli: PKGBUILD |
| `ffc3f673` | 2026-10-31 | ui/editor: scroll a diff with the wheel over its separators (#935) | present | wheel over diff separators (wheel.zig) |
| `9b4bcbf1` | 2026-10-31 | ui: DecimalInput, an exact counterpart to NumberInput for money (#937) | todo-M | decimalInput |
| `d5777b2d` | 2026-10-31 | update: cap how far Diff compares a match, so a long shifted one can't hang it (#941) | n/a | no bsdiff |
| `a80b2926` | 2026-10-31 | mygo: mark destructive message buttons and fix Escape when cancel is the default on macOS (#938) | todo-M | message dialog default/cancel/destructive buttons |
| `f3b66cb7` | 2026-10-31 | Take WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS and WEBVIEW2_USER_DATA_FOLDER as WebView2's loader does (#657) | ported |  |
| `402a3cf8` | 2026-10-31 | Label the Windows installer's desktop shortcut check box in the wizard's language (#662) | n/a | installer is English only |
| `b89df065` | 2026-10-31 | macOS: place a tray's flyout under the copy of its icon the user clicked (#942) | todo-S | macOS tray flyout under the clicked copy |
| `2f67b1cc` | 2026-10-31 | webview: ScrollToContainer on every desktop platform (#943) | todo-M | ScrollToContainer for embedded pages |
| `6b172e28` | 2026-10-31 | ui/editor: show the scroll bars' thumbs only while the pointer is over the editor (#944) | todo-S | editor thumbs only while hovered |
| `5e6b2964` | 2026-10-31 | ui/editor: draw no track under the scroll bar's thumb (#945) | present | no track under thumbs (paint.zig) |
| `76e33e7d` | 2026-10-31 | ui/editor: show the horizontal scroll bar of a diff as high as its lines (#947) | n/a | diff has no horizontal bar per side |
| `1caad878` | 2026-10-31 | ui: draw every scroll bar as a scroll container's, with ui.Scrollbar (#949) | todo-M | shared scroll bar helper |
| `1fa27134` | 2026-10-31 | macOS: give a page the first click in a window that is not key (#950) | ported | macOS: page takes the first click (acceptsFirstMouse) |
| `21ae57f9` | 2026-10-31 | windows: retry a package's final rename while a scanner holds its files (#953) | n/a | cli renames no final package |
| `dcf169d9` | 2026-10-31 | plugins/updater: report a pending update with AvailableVersion (#960) | ported | updater availableVersion |
| `7baaf4db` | 2026-10-31 | ui: placeholder color, dotted underline, Context.Instant, markdown Anchor and LinkWeight (#969) | todo-M | placeholder color, dotted underline, Context.instant, markdown anchor, link weight |
| `49cb9a5f` | 2026-10-31 | ui: let assistive technology edit a custom text client (#967) | present | assistive technology edits text fields (access.zig) |
| `430a0914` | 2026-10-31 | e2e: remove the WebView2 variables test's data folder once the browser lets go (#970) | skip |  |
| `58f0248e` | 2026-10-31 | notifications: let ShowContext cancel the permission wait (#952) | n/a | notify does not wait for permission |
| `f69ccfc7` | 2026-10-31 | ui: enable the Edit menu's roles only while the focus can act on them (#971) | todo-L | Edit menu roles enabled by the focus |
| `a91e9bcb` | 2026-11-01 | ui: CaretWidth and Scrollbars(false), with docs (#972) | ported | caretWidth and scrollbars(false) |
| `0d4deffd` | 2026-11-01 | e2e: wheel over ScrollToContainer's pages once they have drawn (#974) | skip |  |
| `7d3f04ca` | 2026-11-01 | windows: set a forced appearance with WebView2's PreferredColorScheme (#975) | ported | WebView2 PreferredColorScheme for a forced appearance |
| `0b9ed5b6` | 2026-11-01 | mygo: document CancelButton's fallback and -1 (#976) | n/a | docs only |
| `33f16102` | 2026-11-01 | watchdriver: run Remove before the test's failure in TestWatch (#977) | skip |  |
| `b0604652` | 2026-11-01 | fix(editor): autoscroll drags past side edges (#735) | todo-S | textarea drag autoscroll past side edges |
| `9bd34e1e` | 2026-11-01 | Release 0.7.4 | skip |  |
| `7d6ed580` | 2026-11-01 | showcase: add Tomoru, live bilingual subtitles for anything you watch (#979) | skip |  |
| `5dbc9d40` | 2026-11-01 | markdown: end extended autolinks at CJK punctuation (#985) | ported | markdown autolinks end at CJK punctuation |
| `c523feea` | 2026-11-01 | Draw the icons of file types without a file (#984) | todo-M | Shell type icons without a file |
| `84a03a50` | 2026-11-01 | docs: Shell.TypeIcon (#991) | n/a | docs only |
| `a0cd2f9f` | 2026-11-01 | text: keep a font's native font until nothing draws with it (#990) | n/a | Go GC font lifetimes |
| `5b50b22e` | 2026-11-01 | ui: keep a composition in one undo step when GTK clears its preedit first (#988) | n/a | GTK surface has no preedit |
| `91423430` | 2026-11-01 | ui/editor: underline what an input method composes (#989) | present | composition underlined (textarea_view.zig) |
| `6bc9ca2c` | 2026-11-01 | Windows: keep maximized caption buttons off a material window's page (#993) | ported |  |
| `c2e47583` | 2026-11-01 | cli: keep delta bases when GitHub releases omit a platform (#995) | n/a | no delta updates |
| `c971c903` | 2026-11-01 | migrate-ui: decide element nil checks from package ui's signatures (#996) | skip |  |
| `06bc6551` | 2026-11-01 | macOS: take a press with the secondary button's number for a secondary click (#997) | ported | macOS secondary button press as right click |
| `3689f548` | 2026-11-01 | ui, editor: keep scroll bars showing, and read a diff's scroll position (#999) | todo-M | keep scroll bars showing; diff scroll position |
| `1ee84625` | 2026-11-02 | ui: release a press whose element is gone before its release (#1003) | n/a | immediate mode press state |
| `143d61df` | 2026-11-02 | gpu: cut clips around content only moved in the shader, not with masks (#1005) | n/a | no clip masks |
| `b0b627e3` | 2026-11-02 | windows: advertise the server-side UIA provider (#1007) | ported | UIA ServerSideProvider option (uia.zig) |
| `1b8a2186` | 2026-11-02 | terminal, macOS: drop what Option-E types after Esc e with OptionAsAlt (#1004) | n/a | terminal has no OptionAsAlt |
| `9de76198` | 2026-11-02 | ui: report a drag's last moves before its release (#1008) | n/a | every drag event runs its own frame |
| `54cb0efd` | 2026-11-02 | notifications: show an image with a notification (Image) (#1011) | todo-M | notification image |
| `ec44c35f` | 2026-11-02 | text: lay a text out at another width from its last layout (#1013) | present | shaping cached apart from width (text_mac.zig) |
| `da6e0fbf` | 2026-11-02 | ui: let shared elements fly (ElementTransition.Fly) (#890) | todo-L | shared element transitions (Fly) |
| `f70614a9` | 2026-11-02 | ui: choose the rows a drag over a list reaches before its release (#1015) | n/a | every drag event runs its own frame |
| `a764031b` | 2026-11-02 | ui: morph text and turn in 3D as shared elements fly (#1016) | todo-L | text morph and 3D turn (needs Fly) |
| `59e00c7b` | 2026-11-02 | Windows: halve native UI's GPU time, show input a refresh sooner, and size glyph atlases by what they hold (#1012) | todo-L | D3D11 GPU time and atlas sizing rework |
| `1f039303` | 2026-11-02 | plugins/permissionflow: the system's permissions, and a guide to System Settings (#655) | todo-L | plugins/permissionflow |
| `8a002b9d` | 2026-11-02 | Showcase: add Quaver Astra (#1018) | skip |  |
| `da4de8ae` | 2026-11-02 | editor: let a split diff's sides be resized by dragging the line between them (#1021) | todo-M | split diff resizable divider |
| `af6cf911` | 2026-11-02 | ui, pages, materials: draw inactive windows as native apps do (#1022) | todo-L | inactive window look |
| `98c4ccbf` | 2026-11-02 | fix(cli): stop draining dev output when the timeout expires (#1024) | n/a | dev children inherit stdout |
| `aeb986e1` | 2026-11-02 | text: draw Linux subpixel glyphs with FreeType's LCD filter on old cairo (#1027) | n/a | no cairo subpixel text |
| `e25ccb49` | 2026-11-02 | Windows: show LoadHTML's document at an about:blank base URL (#1031) | ported |  |
| `928c867c` | 2026-11-02 | windows: show the last pixel of drawn menus' labels in Chinese (#1033) | n/a | no owner-drawn menus |
| `4162c828` | 2026-11-02 | windows: discard the composition the Japanese IME gives up with Esc (#1032) | n/a | no inline IME composition on Windows |
| `5d5e2ea8` | 2026-11-03 | windows: keep windows where they were on displays of different scales (#1038) | n/a | myzig is system-DPI-aware |
| `cb49ab95` | 2026-11-03 | windows: place windows on displays of different scales where their DIPs say (#1042) | n/a | myzig is system-DPI-aware |
| `9e30453d` | 2026-11-03 | webview: give the native UI the keys a web view's page leaves unhandled (#1040) | todo-L | keys an embedded page leaves unhandled go to native UI |
| `5b33c407` | 2026-11-03 | fix(linux): announce tooltip changes with NewToolTip (#1043) | ported | Linux tray tooltip NewToolTip |
| `982590ef` | 2026-11-03 | darwin: draw a resize's frame after one presented with the transaction at the next tick (#1045) | n/a | no updateLayer deferral on resize |
| `9ebb17d9` | 2026-11-03 | editor: highlight each hunk of a patch from the start of its first line (#1048) | n/a | myzig's editor has no patch (diff) highlighting |
| `48da1ba5` | 2026-11-03 | Paste every clipboard format from Windows menus (#837) | todo-M | Windows menu bar's Paste does not reach pages (mygo pastes through DevTools' Input.dispatchKeyEvent) |
| `85009efc` | 2026-11-03 | ui, backends: cut web views to their corners and scale them as pictures (#1034) | todo-L | ui.webView: cut pages to their box's corners, scale them as pictures |
| `64d9abeb` | 2026-11-03 | macOS: close a tray's popover on a press on its icon (#1059) | todo-S | macOS: a press on the tray icon closes its popover (popover_mac.zig; needs a Mac) |
| `0042535d` | 2026-11-03 | ui: make the tooltip delay configurable with Theme.TooltipDelay (#1062) | ported | Theme.tooltip_delay |
| `dd641444` | 2026-11-03 | cmd/mygo: leave Go sources and resourcesExclude out of resources (#1063) | todo-M | cli: resources_exclude patterns (with **) for copied resource folders |
| `b1a5987b` | 2026-11-03 | Fail Eval when its window closes or the app quits (#1065) | n/a | Window.eval returns nothing in myzig |
| `5e08fdc9` | 2026-11-03 | ui: let a toast keep its time running while the window is in the background (#1064) | n/a | myzig's toasts never stop for a window in the background (their time always runs) |
| `c7f4ab8b` | 2026-11-03 | ui/markdown: open and close * and ~ emphasis next to CJK text (#1057) | ported | markdown: * and ~~ emphasis next to CJK text |
| `069f89ad` | 2026-11-03 | ui, text: underline links whole on hover, through descenders (#1058) | present | myzig's underlines never skip ink (paint.zig draws them whole) |
| `e9f0d6a5` | 2026-11-03 | website: add Meiro to the showcase (#1061) | skip | website |
| `7afa6e4c` | 2026-11-03 | ui/markdown, ui: follow-ups to #1057 and #1058 (#1066) | ported | markdown part; link part present |
| `bf357ded` | 2026-11-03 | window: show a native UI window after NewWindow returns (#1068) | todo-M | show a native UI window after newWindow returns, not inside it (windows/window.zig create) |
| `5f263ab5` | 2026-11-03 | flyouts: open a window modal to a flyout, over it (#1067) | todo-L | a window modal to a flyout, shown over it (every backend) |
| `aa54e0e7` | 2026-11-03 | terminal: opt-in zsh shell integration (#1077) | todo-M | terminal: opt-in zsh shell integration (OSC 133, ZDOTDIR shim) |
| `0f8a8dc4` | 2026-11-03 | mygo: document that SetContentSize takes the window's DIPs, whatever the zoom (#1078) | n/a | myzig's zoom scales text only; setSize takes points |
| `22363f12` | 2026-11-03 | mygo: point Window.Update to RunOnMain for polls that rarely change (#1079) | n/a | Go API docs (Window.Update) |
| `c49af2e6` | 2026-11-03 | mygo: document that SetOpenAtLogin starts the app unelevated on Windows (#1080) | ported | docs: Run entry starts the app unelevated |
| `2b98a934` | 2026-11-03 | macOS: keep a frame asked for after one drawn while drawSoon's waited (#1087) | todo-S | macOS: keep a frame asked for while a queued one waits (needs a Mac) |
| `911a5904` | 2026-11-03 | flyout: size native UI to its content with FitContent (#1069) | todo-L | FitContent for flyouts of native UI |
| `64a5bf53` | 2026-11-03 | ui: document how AnimatePose comes in from a pose on an element's first frame (#1081) | present | motion.pose starts at its pose on a box's first frame (motion.zig move) |
| `6850c8ab` | 2026-11-03 | lists: drag rows out with ListState.DragRows, for targets elsewhere to take (#1089) | todo-M | lists drag their rows out (ListState.DragRows); rows can use DragDrop.draggable today |
| `62222a32` | 2026-11-03 | terminal, macOS: keep CJK punctuation in its cells by turning kerning off (#1084) | todo-S | terminal on macOS: kerning off unless features name kern (needs a Mac) |
| `afff19d9` | 2026-11-03 | ui: draw large paths as tiles when the atlas has no room for their masks (#1090) | n/a | canvas paths render into the canvas's own image, not atlas masks |
| `949829c9` | 2026-11-03 | linux: tell Wayland what OpenGL-composited windows repaint at scale 2 (#1092) | pending |  |
| `b832db0b` | 2026-11-03 | macOS: keep a restored page's scroll position as its window shows (#1088) | pending |  |
| `9b633407` | 2026-11-03 | terminal: Alt+click moves the shell prompt's cursor to the clicked cell (#1085) | pending |  |
| `8cb5060d` | 2026-11-03 | ui: keep a tooltip's content out of the pointer's way (#1091) | pending |  |
| `7a3dd93f` | 2026-11-03 | website: add us3ui and repo-hopper to showcase (#1094) | skip |  |
| `2e15cef4` | 2026-11-03 | ui: hide an element and what is inside it from assistive technology with AccessHidden (#1104) | pending |  |
| `624b24b6` | 2026-11-03 | fix(fetch): honor aborts while preparing request bodies (#1105) | ported | fetch.js: an abort while the body is read sends nothing |
| `18d54f7c` | 2026-11-03 | ui: blur and percents in motion, exits decided as they go, one at a time, Oklab colors (#1106) | pending |  |
| `69b1f9dc` | 2026-11-03 | ui: headless menu and accordion bases, a mixed check box base, a settable focus ring (#1108) | pending |  |
| `826384a5` | 2026-11-03 | windows: release the hidden web view of cookie calls once idle in apps showing no page (#1111) | pending |  |
| `7fcffe15` | 2026-11-03 | ui: clip to insets and paths, gradient masks, balanced text, SVG path data (#1110) | pending |  |
| `8c7d8224` | 2026-11-03 | ui: let go of large paths' masks as the atlas fills and they draw as tiles (#1113) | pending |  |
| `873a2237` | 2026-11-04 | docs(ui): clarify editing resets and key scopes (#1114) | skip |  |
| `ce071b4c` | 2026-11-03 | automation: mygo-automation, a CLI for agents with short refs, settle diffs and an embedded SKILL.md (#1117) | pending |  |
| `6842ad5e` | 2026-11-04 | fix(ui): validate named Tester click targets (#1116) | pending |  |
| `03e6ccc1` | 2026-11-04 | fix(cli): read the PKGBUILD license from mygo.json (#1119) | n/a | no PKGBUILD yet (43e3a3e6 is todo-M) |
| `da7e20c8` | 2026-11-03 | linux: App.SetDMABUFRenderer keeps WebKitGTK's DMA-BUF renderer on, everywhere or on safe hosts (#1124) | pending |  |
| `f83d39d5` | 2026-11-03 | linux: follow the settings portal's dark style in GTK and pages (#1123) | pending |  |
| `8871e2f4` | 2026-11-03 | linux: Theme.SetGTKCSS, an app's style sheet for GTK's own widgets (#1126) | pending |  |
| `cf98bb30` | 2026-11-03 | documents: follow a renamed file from a look, not only from the watch (#1127) | present | checkDisk follows a rename (document.zig) |
| `32d95f68` | 2026-11-04 | mygo: prevent document data loss during editing and recovery (#1125) | ported | recovery: release removes only the copies restored (document_recovery.zig); Equal races n/a (no threads) |
| `ca538273` | 2026-11-04 | ui: an invisible child gives its box a baseline (#1133) | pending |  |
| `312669df` | 2026-11-04 | ui: SelectBase passes over disabled options, as MenuBase does (#1135) | pending |  |
| `98986489` | 2026-11-03 | markdown: Options.LinkMenu, a context menu for each link (#1136) | pending |  |
| `442ab5b0` | 2026-11-04 | markdown: Options.LinkIcon, an icon at the start of a link's text (#1131) | pending |  |
| `b8691960` | 2026-11-03 | ui: play Enter and Exit transitions of elements in the overlay layer (#1137) | pending |  |
| `85076ceb` | 2026-11-03 | mygo: read an app file that Windows reports missing while it is replaced (#1138) | todo-S | Windows: retry reading an app file reported missing while replaced (document_file.zig; needs Windows) |
| `2bd03e09` | 2026-11-04 | ui: keep a no-break space ending a line (#1134) | present | only ASCII spaces hang at a line end (text_rows.zig) |
| `d46cc761` | 2026-11-04 | ui: animate layout inside overlays, reattaching only their panels (#1140) | pending |  |
| `5f601797` | 2026-11-04 | ui: draw another frame when the focus moves as a frame reads FocusWithin (#1142) | pending |  |
| `44ff79c5` | 2026-11-04 | website: add RcloneDrive, ApiGo, Silverwing, Nodra and NanoDoll to the showcase (#1144) | skip |  |
| `91b71e07` | 2026-11-03 | terminal: read modifyOtherKeys through a key encoder, not the formatter (#1145) | pending |  |
| `318147a3` | 2026-11-03 | ui: edit styles live in the inspector (#1146) | pending |  |
| `4d10c377` | 2026-11-04 | cli: name the window class in the desktop entry (#1129) | pending |  |
| `99cce99e` | 2026-11-04 | ui: TabsBase passes over disabled tabs; ComboboxBase shows a row of no matches (#1150) | pending |  |
| `d94b66e3` | 2026-11-04 | ui: let a MenuBase item keep its menu open, and group items as one stop (#1154) | pending |  |
| `0fdb586c` | 2026-11-04 | ui: Tab enters a radio group or a tab list at the one chosen (#1153) | pending |  |
| `e1a6c019` | 2026-11-03 | feat(plugins): draw Apple's SF Symbols in native UI with plugins/sfsymbols (#1149) | pending |  |
| `5053983d` | 2026-11-04 | ui: presses follow the primary button, and tell which button presses (#1156) | pending |  |
| `380f2cb9` | 2026-11-04 | ui: a headless tree base (TreeBase), and rows of your own in an outline (Prefix) (#1155) | pending |  |
| `00d6d2b8` | 2026-11-04 | ui: copy what the inspector's Styles tab changed as Go (#1147) | pending |  |
| `f707e9f2` | 2026-11-04 | ui: keep calendar month navigation in the requested month (#1157) | present | Date.addMonths clamps the day (controls_date.zig) |
| `6ec64b01` | 2026-11-04 | ui: end the drag of a press when the text is edited (#1159) | pending |  |
| `e85e2f8f` | 2026-11-04 | ui: force an element's states from the inspector (#1148) | pending |  |
| `acaeefa8` | 2026-11-04 | ui: aria-busy, a navigation landmark, aria-current and text-underline-offset (#1132 sections 4 and 5) (#1158) | pending |  |
| `137c1576` | 2026-11-04 | ui: open the inspector's source link in the editor (#1160) | pending |  |
| `d28fe883` | 2026-11-04 | ui: show flex and grid layouts over the content from the inspector (#1162) | pending |  |
| `02f583c8` | 2026-11-04 | text: give the glyphs of right-to-left runs in visual order on Windows (#1165) | pending |  |
| `499852ef` | 2026-11-04 | ui: give an element held back by AfterExits the focus once it shows (#1174) | pending |  |
| `86ec3b30` | 2026-11-04 | ui: mix colors in Oklab with premultiplied alpha, as CSS does (#1171) | pending |  |
| `73a6c18f` | 2026-11-04 | automation: check wait conditions while a window keeps drawing (#1175) | pending |  |
| `f17c019d` | 2026-11-04 | glass: native panes over web views, merged groups, tint and accessibility (#1107) | pending |  |
| `7d8b4144` | 2026-11-04 | ui: DimDisabled, and minimum and maximum sizes in DIPs and percentages together (#1176) | pending |  |
| `0df3a82b` | 2026-11-04 | ui: snap scroll containers to the places their elements mark (#1187) | pending |  |
| `0b468467` | 2026-11-04 | darwin: tell assistive technology an element is open only where it opens (#1188) | pending |  |
| `f4764324` | 2026-11-04 | ui: let a SelectBase be opened and closed by its caller (#1173, section 1: SetOpen and a caller-owned open flag) (#1183) | pending |  |
| `348771fd` | 2026-11-04 | ui: Up opens a menu button on its last item, as the APG Menu Button pattern says (#1186) | pending |  |
| `e3e42542` | 2026-11-04 | linux: ask OnWillNavigate about main-frame navigations alone (#1189) (#1190) | pending |  |
| `e3ada47e` | 2026-11-04 | ui: sticky positioning inside scroll containers (#1195) | pending |  |
| `e27c9494` | 2026-11-04 | cli: replace web builds before cleaning up old assets (#1196) | pending |  |
| `e0ce2ec6` | 2026-11-04 | ui: draw a translucent line of one segment without a mask (#1197) | pending |  |
| `67ced267` | 2026-11-04 | ui: shortcuts tell their auto-repeat, and window shortcuts from anywhere in the tree (#1198) | pending |  |
| `5aa8091b` | 2026-11-04 | ui: shadow transitions, exit timing, and the side AttachTo put a panel on (#1211) | pending |  |
| `a6dc14a5` | 2026-11-04 | windows: Restore leaves a visible maximized window maximized (#1213) | pending |  |
| `7d3d3903` | 2026-11-04 | linux: give the tray icon to the panel by its absolute path (#1216) | pending |  |
| `6560593f` | 2026-11-04 | ui: read an element's role, name and states in a Tester (#1208) | pending |  |
| `5ba865af` | 2026-11-04 | ui: FocusLeft, the focus leaving an element, and Context.FocusTakesText (#1202) | pending |  |
| `d5b333dc` | 2026-11-04 | ui: object-position for images, and layers of masks with mask-composite (#1210) | pending |  |
| `1868426d` | 2026-11-04 | access: give a range's value text beside its number (#1223) | pending |  |
| `3461f8a7` | 2026-11-04 | ui: ZIndex orders an element's painting among its siblings (#1226) | pending |  |
| `19f23b04` | 2026-11-04 | cli: ship dotfiles inside a resource directory (#1167) | pending |  |
| `6490835b` | 2026-11-04 | website: update NanoDoll showcase entry (#1230) | skip |  |
| `bb1bce83` | 2026-11-04 | fix(watch): keep file grants from becoming directory grants (#1237) | ported | watch: a file root stays a file grant (Service.root_dirs) |
| `7151bc32` | 2026-11-05 | linux: pace native UI's frames at the monitor's refresh rate, not 60 Hz (#1231) | pending |  |
| `60d82a98` | 2026-11-05 | ui: KeyShortcuts tells assistive technology the keys that press an element (#1256) | pending |  |
| `2009f566` | 2026-11-05 | audio: Player.SetPreservesPitch time-stretches instead of resampling (#1254) | pending |  |
| `b0613c16` | 2026-11-05 | ui: spans take no letter spacing and pad their background (#1257) | pending |  |
| `07b22bb1` | 2026-11-05 | ui: an element observes the input inside it (ObserveInput) (#1221) | pending |  |
| `079be548` | 2026-11-05 | i18n: compact numbers and date ranges (#1218) | pending |  |
| `be78bf91` | 2026-11-04 | fix(fetch): filter cookie headers before sending responses to pages (#1235) | ported | fetch: Set-Cookie2 filtered with Set-Cookie (http.zig) |
| `93e43542` | 2026-11-04 | fix(cli): validate build platforms before project work (#1238) | pending |  |
| `fdd89639` | 2026-11-04 | fix(tsgen): represent embedded JSON fallbacks as top-level members (#1252) | pending |  |
| `8b0f4001` | 2026-11-04 | terminal: read sRGB to linear from a table for minimum contrast (#1249) | pending |  |
| `fbcd4311` | 2026-11-04 | linux: call the GL functions of each batch without reflection (#1250) | pending |  |
| `0bf5ba22` | 2026-11-05 | ui: close Local values that are io.Closers as their element goes (#1233) | pending |  |
| `c9438876` | 2026-11-04 | fix(tsgen): reject colliding method and event names (#1234) | n/a | Zig method names are unique (events named apart only by - and _ still share an onX: not checked) |
| `bb4b0c0c` | 2026-11-05 | ui: animate a Transition's width or height alone (#1259) | pending |  |
| `50967203` | 2026-11-05 | terminal: size columns with Font.CellWidth, keeping glyphs their size (#1229) | pending |  |
| `b609844b` | 2026-11-04 | fix(tsgen): honor string tags on numeric pointers (#1243) | pending |  |
| `fbd763ef` | 2026-11-05 | ui: NoShadow takes off the shadows an element has, as box-shadow: none (#1267) | pending |  |
| `6a6fdf7f` | 2026-11-05 | ui: MaxLength limits how long a text input's value can be typed (#1269) | pending |  |
| `ff62fdfa` | 2026-11-05 | ui: grid tracks with a minimum, Track.Min and Track.MinContent (#1255) | pending |  |
| `6257eb88` | 2026-11-05 | ui: leave the text of inline children hidden from assistive technology out of a paragraph's name (#1268) | pending |  |
| `c3f2804e` | 2026-11-04 | fix(websocket): validate subprotocol tokens before connecting (#1236) | ported | websocket.js: subprotocols must be HTTP tokens, refused before Zig sees them |
| `bb14da26` | 2026-11-05 | ui: fade an inline Text's words with its Opacity, transparent color or Invisible (#1272) | pending |  |
| `142fd6a1` | 2026-11-05 | ui: keep an Exit copy's z-index while it leaves (#1271) | pending |  |
| `f0d918e1` | 2026-11-05 | ui: InViewMargin, InView with a root margin (#1274) | pending |  |
| `42dd28c9` | 2026-11-05 | i18n: amounts of money (#1258) | pending |  |
| `4fd021c0` | 2026-11-05 | ui: text stroke and tab size (#1182 items 1 and 2) (#1217) | pending |  |
| `f2e5ad08` | 2026-11-05 | ui: a focused link takes Enter alone, not Space (#1278) | pending |  |
| `080d2d24` | 2026-11-05 | ui: keep what is inside a column header in the accessibility tree (#1279) | pending |  |
| `ee3d4bd9` | 2026-11-05 | ui: line ScrollIntoView up and glide there, as the web's options do (#1273) | pending |  |
| `977ea57e` | 2026-11-05 | ui, mygo: a closed window keeps nothing it showed; ReleasePixels for NewBitmap (#1281) (#1282) | pending |  |
| `5ed8bfad` | 2026-11-05 | terminal, Windows: send what AltGr types as text, not as Control sequences (#1270) | pending |  |
| `f62a30d3` | 2026-11-05 | ui: CaretColor sets the color of a text input's caret (#1215) | pending |  |
| `d76c7475` | 2026-11-05 | ui: PreserveSpaces keeps the spaces of a text (#1201) | pending |  |
| `964f6a2c` | 2026-11-05 | terminal: ask for the frame that shows a synchronized update after a second (#1305) | pending |  |
| `2c1ea332` | 2026-11-05 | fix(tsgen): reserve the runtime Channel type name (#1294) | ported | tsgen: app types named Channel get another name (declName) |
| `59a05371` | 2026-11-05 | ui: give the items of context menus an icon (#1297) | pending |  |
| `3d0c5a5f` | 2026-11-05 | ui: keep heading children in the accessibility tree (#1310) | pending |  |
| `accc4e86` | 2026-11-05 | ui, backends: tell a view the keys held in the window, whatever has the focus (#1177) | pending |  |
| `31226824` | 2026-11-05 | ui: add RoleListBox and RoleOption, and read SelectBase's popup as a list box (#1179) | pending |  |
| `f27b8948` | 2026-11-05 | ui: TabStop(false) keeps a focusable element out of Tab's order (#1314) | pending |  |
| `3b9d6762` | 2026-11-05 | Add Theme.WindowButtons: the window controls the desktop's title bars have (#1320) | pending |  |
| `01dfd8ed` | 2026-11-05 | text: wrap a resized text again without shaping it again on macOS (#1318) | pending |  |
| `1fc1c20b` | 2026-11-05 | ui: NonMotion keeps a fade animating while the desktop asks for less motion (#1312) | pending |  |
| `3a92ba0d` | 2026-11-05 | Give menu items a subtitle (#1299) | pending |  |
| `234df8ec` | 2026-11-05 | ui: pointer type and pressure, more cursors, clipboard write result (#1204) | pending |  |
| `b3efd4b6` | 2026-11-05 | ui: region, log, timer, alert, separator and row header roles (#1199) | pending |  |
| `2fff1567` | 2026-11-05 | ui: LabelledBy ties a label the view draws to its control (#1319) | pending |  |
| `00552881` | 2026-11-05 | editor: lay out fitted diffs without working through every line (#876) | pending |  |
| `41df62e3` | 2026-11-05 | ui: Opacity fades an element and its children as one group, as CSS's (#1321) | pending |  |
| `9b18043c` | 2026-11-05 | text: hold a family the app gives apart from the font's own (#1232) | pending |  |
| `4125808f` | 2026-11-05 | ui: even-odd fills and clips, Path.Contains, and HitTest (#1315) | pending |  |
| `033a156b` | 2026-11-05 | ui: InViewAmount, in view by a share of the element's area (#1324) | pending |  |
| `3e1da8ca` | 2026-11-05 | ui: AlertDialog fits its buttons, or wraps them (#1329) | pending |  |
| `afd7908d` | 2026-11-05 | ui, mygo: WindowHidden, and file filters by MIME type (#1325) | pending |  |
| `5cfc0b7b` | 2026-11-05 | ui: aria-roledescription, aria-controls, aria-haspopup, aria-sort and selected cells (#1209) | pending |  |
| `0cb26cc5` | 2026-11-05 | Cursor/showcase teebots b27b (#1332) | skip |  |
| `3163e297` | 2026-11-05 | text: put numbers together and wrap Latin text from one shaped line on macOS (#1333) | pending |  |
| `1c7beef4` | 2026-11-06 | ci, e2e: let main's runs finish, and fail the test that leaves state behind (#1336) | skip |  |
| `7941458e` | 2026-11-06 | ui: reset a split's size on a double click (#1313) | pending |  |
| `d3288030` | 2026-11-06 | ui: every key reaches HandleInput, by position (InputEvent.Code) [breaking] (#1328) | pending |  |
| `81ddcacc` | 2026-11-06 | editor: lex a long JSON line in one pass, and paint only what's in view of a deleted line (#1335) | pending |  |
| `62692965` | 2026-11-06 | test: wait for the recent documents in TestDocumentWatchStartFollowsRename (#1344) | skip |  |
| `fe01d40b` | 2026-11-05 | i18ngen: keep escaped placeholder names distinct (#1337) | pending |  |
| `85a2d476` | 2026-11-05 | cli: watch the app's Go workspace files (#1338) | pending |  |
| `90b21535` | 2026-11-05 | tsgen: report invalid service export names (#1341) | ported | tsgen: a service named Channel or myzig is a compile error; Zig names are identifiers already |
| `dab96a7d` | 2026-11-05 | bridge: release channels when a call fails before sending (#1342) | ported | bridge.js: a call whose arguments JSON cannot hold leaves nothing pending (myzig channels have no ids to release) |
| `57d46769` | 2026-11-05 | fetch: honor null options when inheriting a Request (#1345) | ported | fetch.js: a null signal or body in init and the Request's |
| `6a231dec` | 2026-11-06 | ui: AutoComplete tells assistive technology what a field's suggestions complete (#1316) | pending |  |
| `2c6e4701` | 2026-11-06 | ui: AccessDisabled tells assistive technology a control is unavailable, still focusable (aria-disabled) (#1322) | pending |  |
| `56cf90f5` | 2026-11-06 | windows: open tray menus above the taskbar and give menus Windows 11's material, corners and shortcuts (#1178) | pending |  |
| `c8465dd4` | 2026-11-06 | ui: pointer and hover in Preferences, and NewTesterWith (#1326) | pending |  |
| `756ad24a` | 2026-11-05 | cli: reload web dev configuration for each build (#1343) | pending |  |
| `a4bfe6b8` | 2026-11-06 | ui, text: TextShadow and Span.Shadow, and Pretty wrapping (#1327) | pending |  |
| `262dec59` | 2026-11-06 | ci: give go test 20 minutes a package on macOS (#1346) | skip |  |
| `bc8a9944` | 2026-11-05 | update: restore file permissions after archive and delta extraction (#1340) | pending |  |
| `41bd3098` | 2026-11-06 | website: compare MyGo with GPUI, GPUI Fast and egui on /benchmarks, move the tracking page to /measures (#1311) | skip |  |
| `690dbf49` | 2026-11-06 | websocket: require requested subprotocols to be acknowledged (#1347) | ported | websocket: a server that picks none of the offered subprotocols fails the handshake (conn.zig) |
| `dcd33c63` | 2026-11-06 | Let an app set when the code editor's hover shows (#433) | pending |  |
| `4be31bac` | 2026-11-06 | i18n: format relative times with CLDR words and plural forms (#1348) | pending |  |
| `45ce5ee7` | 2026-11-06 | Keep a number input's buttons within the width it is given (#1349) | pending |  |
| `48f49145` | 2026-11-06 | Paint a frame whole when the frame before asked from outside a Draw callback (#1350) | pending |  |
| `95af280a` | 2026-11-06 | Tell a drag's source it was let go over no target, and where, with DragMissed (#1351) | pending |  |
| `51f66e5f` | 2026-11-06 | Tell a press inside an element without taking the pointer, PressedInside (#431) | pending |  |
| `3292c8d4` | 2026-11-06 | Let an app build into a table's header cells with HeaderCell (#432) | pending |  |
| `26602642` | 2026-11-06 | Create disk images on APFS where hdiutil fails on HFS+ (#1352) (#1353) | pending |  |
| `f7d98564` | 2026-11-06 | Show what is behind a glass window that is not Transparent (#1355) | pending |  |
| `42602ca8` | 2026-11-06 | ui: AttachEdgeMargin keeps an attached panel a chosen distance from the window's edges (#1285) | pending |  |
| `0bdd54bc` | 2026-11-06 | i18n: NumberOptions.SignDisplay writes a plus, or hides a negative zero (#1287) | pending |  |
| `218f76c2` | 2026-11-06 | docs: show SplitReset in the split preview (#1358) | skip |  |
| `3f999b87` | 2026-11-06 | ui: draw every menu of a window in the window with SetMenuPresentation (#1359) | pending |  |
| `42c1a43e` | 2026-11-06 | gl: return NewOffscreen's error instead of panicking as it undoes setup (#1360) | pending |  |
| `8b0dd917` | 2026-11-06 | editor: insert snippets with linked fields and Tab stops (#1361) | pending |  |
| `acf2fdd3` | 2026-11-06 | fix(ui): wheel reversing at the end of content turns at once (#1356) | ported | wheel.zig: notches against the travel left turn at once |
| `dc64b5d3` | 2026-11-06 | ui: TranslationZ and Translation3D move content along Z (#1364) | pending |  |
| `bbda2ef8` | 2026-11-06 | ui: tell a cancelled pointer from a release (#1365) | pending |  |
| `dae77b15` | 2026-11-06 | ui: grid and tree grid roles, row and column counts and indexes, and Multiselectable (#1181 a-c) (#1280) | pending |  |
| `35f52345` | 2026-11-06 | ui: DescribedBy, Invalid, Orientation, deletion and insertion roles, and search fields (#1181) (#1366) | pending |  |
| `6121009b` | 2026-11-06 | ui: always keep a toast's time running while the window is in the background (#1369) | pending |  |
| `3ffebb93` | 2026-11-06 | website: add Screenpin to the showcase (#1370) | skip |  |
| `dee64ce3` | 2026-11-06 | ui: give menu items a tooltip with MenuItem.Tooltip (#1367) | pending |  |
| `b466c566` | 2026-11-06 | ui: tell an item's place in its set, and its selection without the look (#1181) (#1371) | pending |  |
| `3ece477d` | 2026-11-06 | ui: show an active descendant's tooltip as the keys rest on it (#1368) | pending |  |
| `7ddd2522` | 2026-11-06 | ui: paint nothing of a group faded out, rather than its layer whole (#1373) | pending |  |
| `8ec59d3a` | 2026-11-06 | ui: size a group's, a blur's and a Cache's layer by what it paints (#1375) | pending |  |
| `79c8b777` | 2026-11-06 | darwin: repeat a held key in an input without text for press and hold (#1374) | pending |  |
| `3418a6a7` | 2026-11-06 | ui: hover what the pointer rests on in the frame the element it hovered goes (#1377) | pending |  |
| `8a07344d` | 2026-11-06 | macOS: leave a drag region's window to the window server when it begins late (#1378) | pending |  |
| `9092c954` | 2026-11-06 | terminal: link paths in Chinese prose, quoted paths, and (line,col) and #L places (#1302) | pending |  |
| `2f93076a` | 2026-11-06 | ui: show an Enter's X and Y on a panel placed with AttachTo (#1192) | pending |  |
| `4abb83d8` | 2026-11-06 | ui/markdown: tell when a Stream has revealed all of its text (#1381) | pending |  |
| `78c6ab78` | 2026-11-07 | ui: CellsStyle paints chosen cells, their rows and stripes (#1379) | pending |  |
| `58580d72` | 2026-11-07 | docs(website): add Sotto to the showcase (#1382) | skip |  |
| `3d46dbb2` | 2026-11-07 | fix(linux): keep first WebKit calls on the main thread (#1384) | pending |  |
| `3a3eb30f` | 2026-11-06 | Release 0.8.0 | skip |  |
| `16bab2ae` | 2026-11-06 | fix(tsgen): avoid shadowing the runtime call function (#1388) | n/a | the generated client passes ...a, no named parameters |
| `442d09c2` | 2026-11-07 | ui: read FollowEnd at each layout, add ListState.HoldPlace (#1390) | pending |  |
| `f494a2c6` | 2026-11-07 | ui, mygo: place and open drawn menu buttons' menus; SVG menu icons, icon colors (#1392) | pending |  |
| `487bc349` | 2026-11-07 | darwin: sweep idle textures after frames drawn once their drawable comes (#1393) | pending |  |
| `44c946bf` | 2026-11-06 | Release 0.8.1 | skip |  |
| `8f07b6f2` | 2026-11-07 | ui: danger, subtitle, trailing, content, ID, highlight and width for drawn menu items (#1391) | pending |  |
| `01769a2b` | 2026-11-07 | windows: sweep once 120 frames went by since the last sweep (#1394) | pending |  |
| `2a59272c` | 2026-11-07 | updater: remove the files that the new version no longer has (#1400) | pending |  |
| `591b2c81` | 2026-11-07 | Add Page.GPUProcessID, the ID of the process that does a page's graphics and media (#1401) | pending |  |
| `3674af80` | 2026-11-07 | darwin: send the key an input method passes on after it commits (#1404) | pending |  |
| `018e4dbc` | 2026-11-07 | text: break Korean lines between words, as CSS's word-break: keep-all (#1405) | pending |  |
| `f843d3ed` | 2026-11-07 | gpu, scene: keep idle clip masks' memory within the budget (#1408) | pending |  |
| `2a9c3a6b` | 2026-11-07 | ui: keep a turn far from the window's origin in front of the viewer (#1409) | pending |  |
| `13865c32` | 2026-11-07 | ui: don't page a scroll view with Space while the focus takes text (#1411) | pending |  |
| `a45b899e` | 2026-11-07 | ui/editor: keep a split diff's hunk header to the old side (#1415) | pending |  |
| `674814aa` | 2026-11-07 | ui: let Tester.RightClick reach a row's content menu (#1416) | pending |  |
| `b332e259` | 2026-11-07 | gpu: cut clips reaching into an outer clip's rounded corners with its mask (#1420) | pending |  |
| `d6d0df14` | 2026-11-07 | linux: let clicks through a window with SetIgnoreMouseEvents (#1419) | pending |  |
| `9ea2a2ab` | 2026-11-06 | website: add TanGit to the showcase (#1424) | skip |  |
| `c9a7ed56` | 2026-11-06 | fix(tsgen): reserve built-in Promise and Record type names (#1421) | ported | tsgen: app types named Promise or Record get another name (declName) |
| `1dfa5a1f` | 2026-11-07 | feat(markdown): GitHub alerts, mentions and issue references (#1423) | pending |  |
| `0657b3b2` | 2026-11-07 | Native modules: Go interfaces implemented in Swift (#1425) | n/a | Go-specific |
| `6a9ae286` | 2026-11-07 | gpu: keep a growing clip's mask instead of allocating it every frame (#1428) | pending |  |
| `31245094` | 2026-11-07 | Release 0.8.2 | skip |  |
| `c4d767e5` | 2026-11-07 | Revert "Native modules: Go interfaces implemented in Swift (#1425)" | n/a | Go-specific |
| `5add3817` | 2026-11-07 | Release 0.8.3 | skip |  |
| `62e74204` | 2026-11-07 | text: draw grayscale glyphs in grayscale where fontconfig asks for subpixels (#1429) | pending |  |
| `e36f00fc` | 2026-11-07 | showcase: add CurlGo, a local-first API client (#1431) | skip |  |
| `4219d257` | 2026-11-07 | Decode AAC, FLAC and Apple Lossless, in MP4 too (#1432) | pending |  |
| `41b7d999` | 2026-11-07 | ui: Tester.AccessAll reads what assistive technology sees of every element (#1437) | pending |  |
| `d443b369` | 2026-11-07 | update: ask again when a server or gateway fails for a moment (#1436) | pending |  |
| `ba157a00` | 2026-11-07 | richtext: open attachment links across their full bounds (#1435) | pending |  |
| `132e3f44` | 2026-11-07 | text: put numbers together and wrap Latin text from one shaped line on Windows (#1427) | pending |  |
| `b87bf329` | 2026-11-07 | ui: tell assistive technology that menu buttons open a menu (#1438) | pending |  |
| `435d9411` | 2026-11-07 | editor: keep the caret in place when another goroutine edits far ahead (#1440) | pending |  |
| `de13e8b4` | 2026-11-07 | ui: keep the caret of right-aligned inputs inside the box (#1442) | present | text field keeps 2 points for the caret (textfield.zig) |
| `8065a78b` | 2026-11-07 | ui: let a List row's content know when the row is hovered or pressed (#1441) | pending |  |
| `64f1df18` | 2026-11-07 | fix(fetch): reject URLs containing credentials (#1458) | ported | fetch.js: URLs with credentials refused |
| `94f22c38` | 2026-11-07 | text: draw Chinese text in one font on English Windows (#1459) | pending |  |
| `1db4e93b` | 2026-11-07 | mygo dev: sign the development app with an Apple Development identity on macOS (#1460) | pending |  |
| `7343aad4` | 2026-11-08 | ui: read out a status when its text changes (ARIA status) (#1462) | pending |  |
| `0c281198` | 2026-11-08 | docs(ui): say when a list writes -1 into Selected (#1465) | skip |  |
| `46089cb2` | 2026-11-08 | terminal: let an app take dropped files first (Options.OnDrop) (#1466) | pending |  |
| `19a64d15` | 2026-11-08 | 添加 GoRequest 到应用展示列表 (#1468) | skip |  |
| `35611e7f` | 2026-11-08 | Add Window.SetInputRegion, for windows that take clicks only on parts of them (#1467) | pending |  |
| `739ace3e` | 2026-11-08 | windows: ask where the cursor is at each clock tick for an input region (#1473) | pending |  |
| `80013ac3` | 2026-11-08 | ui: keep a Split drag's overshoot past a pane's limit (#1475) | pending |  |
| `c97fbd06` | 2026-11-08 | Add Ferry to showcase (#1477) | skip |  |
| `dd14cc3a` | 2026-11-08 | website: describe Ferry in English, as the other showcase entries (#1478) | skip |  |
| `27b3abf5` | 2026-11-08 | ui/video: native video with the system's media engines (#1469) | pending |  |
| `659a325e` | 2026-11-07 | showcase: add MyVNC (#1480) | skip |  |
| `46f8473c` | 2026-11-08 | examples/video: loop the trailer in TestTrailer so it can't end before the clicks (#1483) | skip |  |
| `3dcfc626` | 2026-11-07 | terminal: end a URL printed as text at its first character that is not ASCII (#1481) | pending |  |
| `de0966c4` | 2026-11-08 | text: take Han characters' language from the user's profile languages too (#1482) | pending |  |
| `8cf1afe5` | 2026-11-08 | automation: build the frame a window out of sight waits for, so a press reaches its view (#1485) | pending |  |
| `cc6f6e7a` | 2026-11-08 | ui: let named Tester clicks reach inline links with duplicate labels (#1488) | pending |  |
| `92336637` | 2026-11-08 | gpu: evaluate reducible stationary clip chains without pixel masks (#1489) | pending |  |
| `cef266af` | 2026-11-08 | editor: highlight Nix (#1484) | pending |  |
| `9868d86b` | 2026-11-08 | Add Power.KeepRunning, which keeps App Nap off and lets the computer sleep (#1486) | pending |  |
| `698082b1` | 2026-11-08 | ui: show frames of video in NV12 and I420 without converting them (Bitmap.UpdateYUV) (#1487) | pending |  |
| `6f73a2a0` | 2026-11-08 | Read back the language SetLocale chose (App.ChosenLocale) (#1470) | pending |  |
| `c8e911e3` | 2026-11-08 | Add ClipboardOptions.Concealed, for passwords and other secrets on the clipboard (#1476) | pending |  |
| `c57f6660` | 2026-11-08 | ui: take a DragWindow handle's double click with WindowDoubleClicked (#1490) | pending |  |
| `9795e066` | 2026-11-08 | ui: hide a button's tooltip while its menu or popover shows (#1491) | pending |  |
| `b5db0b40` | 2026-11-08 | ui: report read-only and multi-line on text boxes MyGo doesn't edit (#1493) | pending |  |
| `29c8444f` | 2026-11-08 | i18n: preserve __proto__ placeholders when binding messages (#1492) | pending |  |
| `c44ef478` | 2026-11-08 | ui/editor: keep highlighting within its budget when lines are long (#1497) | pending |  |
| `60580dcc` | 2026-11-09 | ui: skip Affine.Mul in Painter.add when the painter has no transform (#1500) | pending |  |
| `2d2cbbe4` | 2026-11-09 | Native modules: Go interfaces implemented in Swift, Rust or Zig (#1430) | n/a | Go-specific |
| `b9cbe08d` | 2026-11-09 | ui: report read-only on grid cells, sliders and the other roles ARIA allows it on (#1495) | pending |  |
| `a3764f27` | 2026-11-09 | ui: a tab panel role (ARIA tabpanel) (#1456) | pending |  |
| `905f3e56` | 2026-11-09 | ui/chart: add logarithmic and symmetric log scales (#1501) | pending |  |
| `cbded0c2` | 2026-11-09 | windows: stream custom scheme responses to WebView2 (#1504) | pending |  |
| `29acf0b6` | 2026-11-09 | ui: draw in memory after a frame the GPU did not finish in time (#1505) | pending |  |
| `f33c6e71` | 2026-11-09 | ui: report a row's single click with RowClicked (#1513) | pending |  |
| `58ebcf00` | 2026-11-09 | markdown: copy a shared view's text as its own Markdown (#1512) | pending |  |
| `f30b4d38` | 2026-11-09 | ui: stop per-frame allocations in Outline rows and ContextMenu (#1514) | pending |  |
| `2463ff82` | 2026-11-09 | ui: hover the row a scroll brings under the pointer in the frame that scrolls (#1508) (#1515) | pending |  |
| `c4197b7f` | 2026-11-09 | gpu: cut panes in a continuous frame's corners in Metal's shader (#1516) | pending |  |
| `f234638d` | 2026-11-09 | ui: main, banner, content info and complementary landmarks (#1519) | pending |  |
| `2a3f59b6` | 2026-11-09 | terminal: send Tab, Enter and Esc for Ctrl+I, Ctrl+M and Ctrl+[ (#1523) | pending |  |
| `7c453ff0` | 2026-11-09 | d3d11: share one device across the windows' renderers (#1520) | pending |  |
| `a30c1da5` | 2026-11-08 | windows: reclaim the temporary icons of notifications on a timer (#1524) | pending |  |
| `ba4fa533` | 2026-11-08 | darwin: keep what assistive technology writes to a password field unreadable (#1527) | pending |  |
| `1b9e905e` | 2026-11-09 | ui/editor: don't panic on a pointer move before a reset diff is laid out (#1528) | pending |  |
| `6a730f12` | 2026-11-09 | updater: install an update of an app at the root of a drive (#1531) | pending |  |
| `55df1aee` | 2026-11-09 | audio: low-pass before downsampling, so 30 kHz no longer plays at 18 kHz (#1536) | pending |  |
| `4a142351` | 2026-11-09 | ui: keep a layer's scaled and rotated descendants in their place (#1533) | pending |  |
| `83030abc` | 2026-11-09 | ui/editor: show an empty side of a diff without line numbers (#1534) | pending |  |
| `6dfdff6a` | 2026-11-09 | macOS: give a native popover the app's appearance, not its anchor's (#1530) | pending |  |
| `a3b07219` | 2026-11-09 | ui: open the chosen row's context menu for the menu key in a list (#1539) | pending |  |
| `9b283020` | 2026-11-09 | ui: let a transition's Exit wait its own delay (ElementTransition.ExitDelay) (#1540) | pending |  |
| `9b28c28c` | 2026-11-09 | ui/editor: give a Language.Highlighter the lines a patch's hunks start at (#1544) | pending |  |
| `2cb5152c` | 2026-11-09 | ui: cut a text's middle with TruncateMiddle, keeping its start and end (#1537) | pending |  |
| `0823afe7` | 2026-11-09 | ui/editor: paint a unified diff's deleted lines from the first in view (#1549) | pending |  |
| `41bc9954` | 2026-11-09 | macOS: count a minimized window as visible, as Windows and Linux do (#1542) (#1552) | pending |  |
| `34c35478` | 2026-11-09 | ui: report a column moved or resized once the drag ends (#1553) | pending |  |
| `2731fbc3` | 2026-11-09 | text: draw symbols presented as text in the text's color on Windows (#1551) | pending |  |
| `d40dda45` | 2026-11-09 | Let App.Relaunch pass arguments to the new instance (#1556) | pending |  |
| `7ac8b25e` | 2026-11-09 | Run the quit listeners when the OS ends the session (#1555) | pending |  |
| `983c59a9` | 2026-11-08 | terminal: keep glyphs shrunk to fit a cell in the middle of the line (#1550) | pending |  |
| `e82f6f7d` | 2026-11-09 | ui: share a segmented control's width equally with FillEqually (#1554) | pending |  |
| `24f8dde1` | 2026-11-09 | ui: let Meter and Progress fill in colors of the app's own (#1558) | pending |  |
| `d8fba9bb` | 2026-11-09 | Add App.ClearWindowStates, and say when window states are saved (#1557) | pending |  |
| `b6a6200b` | 2026-11-09 | shell: preview items with Quick Look on macOS (#1561) | pending |  |
| `dae2115c` | 2026-11-09 | ui: let a child's own Transition follow its parent's Size transition (#1562) | pending |  |
| `799e754d` | 2026-11-09 | windows: preserve native opening transitions for ready windows (#1563) | pending |  |
| `4ceb5883` | 2026-11-09 | ui/editor: forget a unified diff's deleted lines once frames stop showing them (#1559) | pending |  |
| `45bcc6a4` | 2026-11-09 | clipboard: prefer UTF-8 targets over a bare text/plain (#1564) | pending |  |
| `6e965739` | 2026-11-09 | ci: pin Bun, so setup-bun keeps it in the Actions cache (#1569) | skip |  |
| `d58db724` | 2026-11-09 | richtext: let an app take keys, draw spans and build the menu of the editor (#1567) | pending |  |
| `89f61a07` | 2026-11-09 | Let a read of an app file share its deletion, so it never blocks a save (#1573) | todo-S | Windows: share delete on app file reads (document_file.zig; needs Windows) |
| `ccd885bd` | 2026-11-09 | fix(fetch): preserve response metadata when cloning (#1570) | pending |  |
| `eadf1fce` | 2026-11-09 | ci: keep the SQLite native module in the Actions cache (#1574) | skip |  |
| `1c232860` | 2026-11-09 | showcase: add Golder (#1580) | skip |  |
| `24c44052` | 2026-11-09 | editor: fit wrapped rows to their shaped width, and keep closing punctuation off row starts (#1584) | pending |  |
| `a364e922` | 2026-11-09 | updater: add OnInstalled, called once an update is installed (#1577) | pending |  |
| `d0bfee2c` | 2026-11-09 | fix(ui): show edit items in the context menu of a HandleTextInput element (#1582) | pending |  |
| `be46dcc0` | 2026-11-10 | ui/editor: find a script's language by its #! line (#1586) | pending |  |
| `434ef095` | 2026-11-09 | ui: repaint for hover that only changes looks, and do less per element each frame (#1590) | pending |  |
| `25891783` | 2026-11-09 | fix(showcase): clarify Golder interfaces and computer use (#1592) | skip |  |
| `10edac95` | 2026-11-10 | ui/editor: highlight ERB and Jinja templates (#1585) | pending |  |
| `46702473` | 2026-11-09 | ui: present frames without display pacing with MYGO_UNCAPPED=1 (#1498) | pending |  |
| `ce8116e3` | 2026-11-10 | fix(richtext): move the caret and take the focus on a right-click (#1596) | pending |  |
| `1cdf900d` | 2026-11-10 | fix: show a window whose first frame waits on the main thread (#1595) | pending |  |
| `63603193` | 2026-11-09 | raster: convert Oklab mixes through a table of toSRGB, built on first use (#1589) | pending |  |
| `48680f9c` | 2026-11-09 | ui: style scroll bars, as VS Code's editor (#1594) | pending |  |
| `3355a2a7` | 2026-11-09 | claude: allow gh api calls that manage PRs and workflow runs | pending |  |
| `c101dc94` | 2026-11-09 | ui/editor: highlight Svelte and HCL/Terraform files (#1597) | pending |  |
| `5b5a25be` | 2026-11-10 | windows: keep a composed native UI window cloaked until DWM composed its first frame (#1591) (#1598) | pending |  |
| `e6562e99` | 2026-11-10 | ui: add SplitButton, a button joined to a menu of related actions (#1600) | pending |  |
| `5a2f9c65` | 2026-11-10 | ui: journal what frames write into built fields after the build (#1601) | pending |  |
| `afb7d5f1` | 2026-11-10 | perf(ui): return early from computeBox for a box with no children (#1603) | pending |  |
| `58f31630` | 2026-11-10 | perf(ui): give a row's stretched items its height without measuring them (#1604) | pending |  |
| `9d363427` | 2026-11-10 | feat(richtext): add Document.CaretRect, where the editor shows the caret (#1607) | pending |  |
| `f4892b10` | 2026-11-10 | Tell apps when a quit they started was canceled (#1606) | pending |  |
| `255655c8` | 2026-11-09 | darwin: hear NSCurrentLocaleDidChangeNotification under the name Foundation posts it (#1611) | pending |  |
| `34c3a8cd` | 2026-11-10 | feat(dev): add mygo dev -background, to keep the app from taking the focus (#1609) | pending |  |
| `4d205d66` | 2026-11-10 | fix(ui): keep a text area from panicking when its text shrinks under a drag (#1614) | pending |  |
| `6325e0a9` | 2026-11-10 | darwin, windows: draw a hidden or minimized window's frame at once (#1613) | pending |  |
| `93f50772` | 2026-11-10 | fix(ui): keep a GridView from asking for keys of items the app took out (#1615) | pending |  |
| `490715e2` | 2026-11-10 | feat(ui/editor): highlight a template's text in the language its name gives (#1619) | pending |  |
| `819683b2` | 2026-11-10 | updater: offer a release that came out while the update window was open (#1618) | pending |  |
| `ce52b009` | 2026-11-10 | feat(ui/editor): show a patch with its files (#1623) | pending |  |
| `8146909a` | 2026-11-10 | feat(ui): replace an input's text as a step of undo of its own (#1622) | pending |  |
| `a4b6734f` | 2026-11-10 | showcase: add Vole (#1624) | skip |  |
| `4354c827` | 2026-11-10 | feat(permissionflow): localise the Guide panel and permission names (#1579) | pending |  |
| `9b265767` | 2026-11-10 | showcase: add MiguWave (#1625) | skip |  |
| `5ae20dc8` | 2026-11-10 | linux: build RPM packages and accept per-format linux.depends (#1621) | pending |  |
| `9d5423fa` | 2026-11-10 | fix: 修复 Windows 透明 WebView 背景与无阴影边框 (#1626) | pending |  |
| `0e8b26eb` | 2026-11-10 | ui: scroll the element the app focuses into view (#1629) | pending |  |
| `b04a273f` | 2026-11-10 | fix: preserve grayscale glyphs with Cairo 1.16 (#1627) | pending |  |
| `c799cbc6` | 2026-11-10 | fix(ui): take a CRLF as one line break in ReplaceText (#1630) | pending |  |
| `0b016ebb` | 2026-11-10 | feat(shell): add Shell.DefaultApp to query the default handler for a URL (#1565) | pending |  |
| `28347149` | 2026-11-10 | fix(ui/editor): end a read-only diff at the final newline (#1631) | pending |  |
| `3ea00a77` | 2026-11-10 | richtext: EditorOptions.Space leaves room above a paragraph (#1632) | pending |  |
| `727b26da` | 2026-11-10 | feat(ui): add Theme.WithAccent and Theme.WithPreferences (#1633) | pending |  |
| `a91f511e` | 2026-11-10 | fix(ui): keep the scroll when Focus follows a press (#1635) | pending |  |
| `e98410d0` | 2026-11-10 | feat(ui): report where the window controls end (#1636) | pending |  |
| `afffa9ef` | 2026-11-10 | feat(ui): let a menu button style its drawn menu's panel (#1637) | pending |  |
| `96334a46` | 2026-11-10 | fix(editor): mark no newline at end of file in read-only diffs (#1638) | pending |  |
| `9e85d643` | 2026-11-10 | fix(linux): find the default app of a folder and of a file without an extension (#1639) | pending |  |
| `14f552b0` | 2026-11-10 | fix(linux): keep the app one program when a command of another name starts it (#1640) | pending |  |
| `90a1f06e` | 2026-11-10 | feat(editor): add Inlay.Trailing so end-of-line text does not capture the caret (#1641) | pending |  |
| `8c80db3a` | 2026-11-10 | website: use the new analytics script | skip |  |
| `d4a6da45` | 2026-11-10 | test: set the clock for the sliding bar in TestProgressColor (#1643) | skip |  |
| `daf6341a` | 2026-11-10 | feat(ui): add Element.OnUnmount (#1644) | pending |  |
| `fececd37` | 2026-11-11 | docs(ui): say that a minimized window draws no frames on Windows and X11 (#1645) | skip |  |
| `9cf55cc7` | 2026-11-11 | perf(ui): find a flex item's cross size once, in flexLayout's first walk (#1646) | pending |  |
| `8c7d7ba9` | 2026-11-10 | richtext: EditorOptions.NoScrollbar draws no scroll bar of the editor's own (#1647) | pending |  |
| `51f61264` | 2026-11-10 | richtext: VisibleParagraphs and CaretRect give the editor built last (#1648) | pending |  |
| `bd590bb4` | 2026-11-11 | ui: allow hiding scrollbar indicators per axis (#1650) | pending |  |
| `f5c3a6e1` | 2026-11-11 | mygo: choose the client certificate a server asks for (#1649) | pending |  |
| `ec11ad71` | 2026-11-11 | richtext: paint only the paragraphs the clip shows, their starts counted on (#1653) | pending |  |
| `13336a06` | 2026-11-11 | docs(ui): show OnPaste inserting text of its own with ReplaceText (#1656) | skip |  |
| `48bb0170` | 2026-11-11 | feat(ui): add ListState.Choose for the app to choose a row (#1657) | pending |  |
| `038f0aca` | 2026-11-11 | ui: build again when what InView read changes after a scroll (#1661) | pending |  |
| `d062d085` | 2026-11-11 | ui: let Focus keep the scroll with FocusOptions.PreventScroll (#1660) | pending |  |
| `929aa537` | 2026-11-11 | fix(darwin): keep the main thread running when a window hides in its own frame (#1663) | pending |  |
| `c75abdde` | 2026-11-11 | fix(ui): let a ListState move to another window (#1664) | pending |  |
| `b4882ccc` | 2026-11-11 | fix(linux): show template tray icons white on a dark desktop (#1665) | pending |  |
| `4f6e464a` | 2026-11-11 | fix(ui): reject PNG sizes that overflow the frame buffer (#1668) | present | png_decode.zig refuses sizes past max_pixels |
| `b5077f66` | 2026-11-11 | ui: let a Tester hear what live regions read out (UseScreenReader, Alerts) (#1667) | pending |  |
| `9171337c` | 2026-11-11 | fix(darwin): draw a resize's frame at the link's tick after a pause, so it shows (#1669) | pending |  |
| `1f15ace2` | 2026-11-11 | fix(terminal): wait for output on EAGAIN instead of ending the program (#1671) | pending |  |
| `7cd44cbe` | 2026-11-11 | gpu/metal: keep older GPUs on the general pipeline (#1572) | pending |  |
| `5847fa7b` | 2026-11-11 | editor: EditRemote edits a Buffer outside the undo history (#1654) | pending |  |
| `6bd276dd` | 2026-11-11 | editor: show ranges of the text as something else (#1655) | pending |  |
| `065300a7` | 2026-11-11 | fix(terminal): turn off a killed job's mouse and key reports (#1673) | pending |  |
| `3f52033d` | 2026-11-11 | editor: hover and ellipsize trailing inlays (#1675) | pending |  |
| `95768c87` | 2026-11-11 | markdown: Options.CodeLink makes code within text a link (#1678) | pending |  |
| `24170c28` | 2026-11-11 | ui: allow themes to disable automatic disabled dimming (#1676) | pending |  |
| `d9f76c99` | 2026-11-11 | ui: skip the layout's walks that have nothing to do (#1684) | pending |  |
| `2801275c` | 2026-11-11 | ui: let a row coming into a list that was there come in (#1683) | pending |  |
| `51d5a505` | 2026-11-11 | fix: round glyph positions on Linux as GTK does (#1685) | pending |  |
| `f8daf210` | 2026-11-11 | i18n: cache Match for the lists it matched before (#1686) | pending |  |
| `a822f6bc` | 2026-11-11 | website: sponsors page at /sponsors, with the README's sponsors on the home page | skip |  |
| `d331ca52` | 2026-11-11 | terminal: take scrolled rows from the last frame instead of making them again (#1687) | pending |  |
| `4811a286` | 2026-11-11 | Release 0.9.0 | skip |  |
| `49976a60` | 2026-11-11 | fix(audio): bound what ReadSound reserves from a decoder's length (#1688) | pending |  |
| `e3ebaa5b` | 2026-11-11 | website: add Chinese localization and polish translated docs | skip |  |
| `0f54da5b` | 2026-11-11 | website: redirect the old domain to mygo.run | skip |  |
| `d40e0b7a` | 2026-11-11 | website: shorten the Chinese slogan and keep hero text clear of animation | skip |  |
| `99f392a9` | 2026-11-11 | website: publish the docs of a tree that is there (#1694) | skip |  |
| `66c09887` | 2026-11-11 | feat(richtext): scroll the editor from the app, keep the caret's line in place (#1692) | pending |  |
| `892bb9ef` | 2026-11-11 | richtext: walk a Text's paragraphs and runs in one pass (#1695) | pending |  |
| `f651b106` | 2026-11-11 | ui: copy an element, its styles and its values from the inspector (#1696) | pending |  |
| `90d83768` | 2026-11-11 | docs: review Simplified Chinese translations and fix section links | skip |  |
| `6548cd3e` | 2026-11-11 | showcase: add OpenBee (#1697) | skip |  |
| `8f3f5718` | 2026-11-12 | ci: look up Ubuntu's mirrors over DNS over HTTPS when the runner can't resolve them (#1719) | skip |  |
| `0d644f4a` | 2026-11-12 | ui: leave inert copies out of names from content (#1710) | pending |  |
| `24350946` | 2026-11-12 | ui, internal/svg: draw var(), dark media queries, text and markers (#1698) | pending |  |
| `4b37fded` | 2026-11-12 | fix(editor): put the caret after typed text that has CRLF line endings (#1701) | pending |  |
| `50664e80` | 2026-11-12 | fix(editor): keep carets on characters after sorting lines, and a moved line's selection in the text (#1703) | pending |  |
| `1244979e` | 2026-11-12 | fix(editor): convert the case of a word once when several carets are in it (#1704) | pending |  |
| `a71c87eb` | 2026-11-12 | ui: a commit pass takes what a measuring pass resolved (#1705) | pending |  |
| `fa858042` | 2026-11-12 | fix(richtext): take the CRLF of an input method's text as one line break (#1711) | pending |  |
| `3e3c6534` | 2026-11-12 | feat(linux): tell the desktop what a global shortcut does, and the app its keys (#1715) | pending |  |
| `807740bf` | 2026-11-12 | ui: PopoverMenuButtonOptions.Item styles the menu's rows (#1742) | pending |  |
| `b91d67b2` | 2026-11-12 | ui: keep a drag going when the frame builds its source no more (#1736) | pending |  |
| `dbda16a0` | 2026-11-12 | fix(editor): close the completions when the caret goes elsewhere than by typing (#1737) | pending |  |
| `cb55021d` | 2026-11-12 | fix(dev): sign with the Apple Development identity of macos.signingIdentity's team (#1739) | pending |  |
| `33e543b6` | 2026-11-12 | ui: give a Tester its own text system, so Testers run in parallel (#1730) | pending |  |
| `72c98be3` | 2026-11-12 | feat(editor): show the word Cmd+click goes to the definition of as a link, with options to turn it off (#1729) | pending |  |
| `d7da9418` | 2026-11-12 | fix(richtext): preserve quotation depth independently of list indentation (#1731) | pending |  |
| `0d9ce43b` | 2026-11-12 | editor: draw lines in other fonts (#1702) | pending |  |
| `7342ceb5` | 2026-11-12 | markdown: hand task check boxes to the app and resolve anchors to blocks (#1716) | pending |  |
| `e147c899` | 2026-11-12 | ui: TokenField exposes the text being typed with Query (#1717) | pending |  |
| `ac5ad4c7` | 2026-11-12 | Select all of a text input's text with Handle.SelectAll, as Tab into it does, even when it has the focus already (#825) | pending |  |
| `440523d3` | 2026-11-12 | fix(editor): leave no room for the annotation of a collapsed line in a split diff (#1734) | pending |  |
| `a968da17` | 2026-11-12 | chart: index append-only data for repeated min/max queries (#648) | pending |  |
| `9e9d5d53` | 2026-11-12 | Keep a file too big for the recycle bin instead of deleting it on Windows (#629) | pending |  |
| `f740842f` | 2026-11-12 | showcase: add Ferry Drive, Snapover, Xylring and Mojian (#1708) | skip |  |
| `3bb9b092` | 2026-11-12 | ui: give a box with nothing in it its padding without measuring it (#1735) | pending |  |
| `5333229d` | 2026-11-12 | Retry transient failures when fetching published updates (#836) | pending |  |
| `fc16e09e` | 2026-11-12 | fix(markdown): reparse from the block above when editing a paragraph that ends in a table (#1727) | pending |  |
| `ea3fc082` | 2026-11-12 | fix(video): never load an AVURLAsset's tracks on the main thread (#1743) (#1747) | pending |  |
| `e1658dfa` | 2026-11-12 | windows: build tag mygo_nowebview leaves WebView2 out (#1748) | pending |  |
| `16720376` | 2026-11-13 | linux: draw in memory when MYGO_GPU=1 finds no libepoxy (#786) | pending |  |
| `91dd8912` | 2026-11-12 | fix(cli): give the dev build an icon on Linux (#725) | pending |  |
| `bb86e69b` | 2026-11-12 | fix(cli): validate file association MIME types and escape their XML (#1241) | ported | cli: mime_type validated, escaped in the MIME package |
| `87b82398` | 2026-11-12 | terminal: leave out the line about the program's end (Options.NoExitMessage) (#1738) | pending |  |
| `1c40ba32` | 2026-11-12 | Make TrashItem fail when Windows deletes the item for good all the same (#1750) | pending |  |
| `42785c80` | 2026-11-12 | Tell apps when the clipboard changes (Clipboard.OnChanged) (#342) | pending |  |
| `9d5a91b0` | 2026-11-12 | Keep TestVibrancy and TestDiffFrameAllocs passing whatever the system's default font (#752) | pending |  |
| `ebb6cb4f` | 2026-11-12 | shell: return resulting trash path on macOS via TrashItemResult (#1453) | pending |  |
| `648838f3` | 2026-11-12 | showcase: add MyGO Wallhaven and goFinder (#1751) | skip |  |
| `ce627fe0` | 2026-11-12 | fix(cli): reject query strings and fragments in update base URLs (#1753) | ported | cli: updates.url without a query or fragment |
| `ac5473d8` | 2026-11-12 | video: open a file by its path on Windows, so a non-ASCII path plays (#1754) | pending |  |
| `8e3f70c9` | 2026-11-12 | ui: a frame built anew for input does not wait for a drawing's lower rate (#1755) | pending |  |
| `19e58fc2` | 2026-11-13 | fix(cli): say what codesign waits for when it signs for long (#1757) | pending |  |
| `5aaf41b5` | 2026-11-12 | fix(linux): keep the program name an app set before Run (#1761) | pending |  |
| `c3ed3ca3` | 2026-11-13 | fix(dev): keep the signatures of code among the resources (#1765) | pending |  |
| `69f0eea4` | 2026-11-13 | feat(window): let the mouse through a window from its creation, and ask whether it does (#1758) | pending |  |
| `c58e609c` | 2026-11-13 | ui: List calls EndReached after layout as the user scrolls near the end (#1767) | pending |  |
| `a2ebf54d` | 2026-11-13 | linux: keep dispatching after a post made while Init runs (#1771) | pending |  |
| `b1fcd3b3` | 2026-11-13 | ui: read an element in fewer lines when laying it out (#1728) | pending |  |
| `ebc1b06c` | 2026-11-13 | Play audio without allocating, and wake far less while it plays (#499) | pending |  |
| `e5a505ed` | 2026-11-13 | fix(editor): fit the find bar in narrow editors, and draw a diff's bars above its separators (#1775) | pending |  |
| `a2f9e0f4` | 2026-11-12 | richtext: follow an edit's replacements one by one to keep the view (#1774) | pending |  |
| `6eaa7fb4` | 2026-11-13 | ui: avoid persistent path tiling after atlas growth (#1766) | pending |  |
| `5e68fd3c` | 2026-11-13 | raster: sample aligned images directly from their pixels (#1779) | pending |  |
| `9da1a8e0` | 2026-11-13 | raster: reuse canvas redraw buffers (#1778) | pending |  |
| `31ec0edd` | 2026-11-13 | docs: say that only the user's next scroll calls EndReached again (#1783) | skip |  |
| `d69ca878` | 2026-11-13 | perf(ui): keep the flexible lengths of a flex item in the item (#1780) | pending |  |
| `a676ee14` | 2026-11-13 | richtext: keep the tests' windows open while they read the document (#1788) | pending |  |
| `614ea7a6` | 2026-11-13 | linux: keep a tray from crashing the app when the shell restarts (#1790) | pending |  |
| `a04e1c35` | 2026-11-13 | showcase: add 划词翻译 (#1789) | skip |  |
| `9560d804` | 2026-11-13 | perf(raster): reuse solid bounds for rectangular clips (#1791) | pending |  |
| `d5c76cf8` | 2026-11-13 | [ImgBot] Optimize images (#810) | pending |  |
| `0ed4da70` | 2026-11-13 | perf(raster): parallelize dense fills on small targets (#1794) | pending |  |
| `18705ffb` | 2026-11-13 | d3d11: start refusing with the resize's last frame in TestUncappedRefusedThroughSettle (#1797) | pending |  |
| `e67040c2` | 2026-11-13 | richtext: move Up and Down past wide room between lines (#1799) | pending |  |
| `090ac1b1` | 2026-11-13 | windows: keep the keyboard in the menu bar's loop while the page has it (#1802) | pending |  |
| `e8bd4162` | 2026-11-13 | ui/editor: keep each line's own line ending (#1801) | pending |  |
| `651e73d2` | 2026-11-13 | d3d11: let TestUncappedSwapChain's resize frame wait to present when DXGI refuses it (#1805) | pending |  |
| `c4dcaca3` | 2026-11-13 | updater: end a request the network abandoned (#1803) | pending |  |
| `129fb92b` | 2026-11-13 | fix(ui): use current surface size after a view resizes its host (#1806) | pending |  |
| `3ccc6b13` | 2026-11-13 | fix(editor): keep a letter typed while another goroutine edits the buffer (#1807) | pending |  |
| `523d7c1e` | 2026-11-13 | fix(darwin): serialize reentrant accessibility updates (#1808) | pending |  |
| `a12959d2` | 2026-11-13 | richtext: leave Space's room above a block of code outside it (#1817) | pending |  |
| `d60cccb7` | 2026-11-14 | ui: Tester withholds keys typed while an input method composes (#1820) | pending |  |
| `f2df9192` | 2026-11-13 | richtext: move Left and Right through a padded span or a wrap (#1823) | pending |  |
| `bdb49185` | 2026-11-13 | ui: draw the fonts an app registers in a Tester's window too (#1827) | pending |  |
| `f31d37f4` | 2026-11-13 | richtext: keep a heading's room inside the quotation it starts (#1825) | pending |  |
| `cb821412` | 2026-11-14 | richtext: start the placeholder where the first paragraph's text starts (#1828) | pending |  |
| `b8a643c3` | 2026-11-14 | richtext: EditorOptions.OnCommand, asked about the menus' edit commands (#1831) | pending |  |
| `4ab72ccb` | 2026-11-14 | ui/video: wake the window for AVFoundation's first picture (#1832) | pending |  |
| `217fbc06` | 2026-11-14 | richtext: compare a paragraph's marks to check its Markdown, not print them (#1833) | pending |  |
| `617ceed0` | 2026-11-14 | richtext: lay out only what the clip shows when a tall editor's look changes (#1834) | pending |  |
| `c9230a51` | 2026-11-14 | ui: let an Outline keep its rows between frames (Generation) (#1818) | pending |  |
| `7eeeec17` | 2026-11-14 | fix(editor): compare large diffs off the main thread (#1819) | pending |  |
| `385ed06a` | 2026-11-14 | ui/editor: read every diff line as what it is, and lines on macOS (#1821) | pending |  |
| `d862143d` | 2026-11-14 | linux: give the tray icon its TrayOptions.ID (#1836) | pending |  |
| `b12b6dfd` | 2026-11-14 | editor: compare the long diff before TestDiffAccessLinesInView's window (#1837) | pending |  |
| `ec96dbe0` | 2026-11-14 | ui: backspace takes a combining mark alone, and a click lands between graphemes (#1838) | pending |  |
| `de4d0cfa` | 2026-11-14 | fix(terminal): open a link that wraps onto the next rows whole (#1677) | pending |  |
| `16d30c5b` | 2026-11-14 | updater: give TestHTTPGetKeepsASlowBody room on slow runners (#1844) | pending |  |
| `daf9c2e5` | 2026-11-14 | ui: rasterize text and Cache layers at the scale a transform shows them at (#1846) | pending |  |
| `970eaac2` | 2026-11-14 | d3d11: give a slow runner's frames 500 ms in TestUncappedResizeWhileDWMStalls (#1850) | pending |  |
| `111c8898` | 2026-11-14 | cli: get the archives of delta updates from updates.s3, and retry stalled downloads (#875) | pending |  |
| `23497040` | 2026-11-14 | text: lay out a trailing empty line after U+2028 (#1845) | pending |  |
| `6ac8c829` | 2026-11-14 | ui: Span.PaddingStart, room at the start of a span alone (#1829) | pending |  |
| `46c97276` | 2026-11-14 | ui: draw on the CPU the paths the mask atlas has no room for (#1841) (#1847) | pending |  |
| `832a4e64` | 2026-11-14 | markdown/parser: preserve closed MathBlock End in finalize (#1856) | pending |  |
| `abd656bd` | 2026-11-14 | editor: auto-pair brackets and quotes around CJK characters and punctuation (#1854) | pending |  |
| `203930fb` | 2026-11-14 | richtext: collapse selection in travel direction before vertical move (#1857) | pending |  |
| `015f979a` | 2026-11-15 | fix(parser): end childless list items at their line end (#1855) | pending |  |
| `966b2823` | 2026-11-15 | perf(ui): reuse polyline style and pixel transform across segments (#1839) | pending |  |
| `39a034b7` | 2026-11-15 | fix(richtext): ignore idle empty SetMarkedText and preserve composition undo (#1859) | pending |  |
| `267ebab4` | 2026-11-15 | richtext: measure full same-line ranges in BoundsForRange (#1858) | pending |  |
| `3511b05c` | 2026-11-15 | macOS: show a popover flyout in a closed one's NSPopover (#1843) | pending |  |
| `2dd01b4a` | 2026-11-14 | ui: cut a text's start with TruncateStart, keeping its end (#1869) | pending |  |
| `3737de09` | 2026-11-15 | ui: give a Table rows of one height with ListState.RowHeight (#1870) | pending |  |
| `7519c5aa` | 2026-11-15 | linux: bind global shortcuts through the portal under XWayland (#1865) (#1868) | pending |  |
| `b615f295` | 2026-11-15 | linux: keep frameless always-on-top windows above others on Wayland (#1864) (#1867) | pending |  |
| `7ff61616` | 2026-11-15 | editor: draw a split diff's divider over its separators (#1871) | pending |  |
| `6fb5ce9c` | 2026-11-15 | window: CornerRadius, the radius the window's corners are rounded to on screen (#1849) | pending |  |
| `d9072e0c` | 2026-11-15 | Add trailing badges to menu items, aligned on macOS (#738) | pending |  |
| `ba3a3319` | 2026-11-15 | ui/shader: draw many quads in one call, each with data of its own (DrawInstances) (#1851) | pending |  |
| `cb03c2d2` | 2026-11-15 | render: videos of native UI, drawn on the GPU (plugins/render) (#1873) | pending |  |
| `13a0b3e7` | 2026-11-15 | Release 0.9.1 | skip |  |
| `1fbf0c6e` | 2026-11-15 | fix(render): give every frame of a macOS video its exact duration (#1883) | pending |  |
| `6a64c844` | 2026-11-15 | fix(tray): keep a macOS tray title's width as its letters change (#1882) | pending |  |
| `3fa6d805` | 2026-11-15 | showcase: add Leafmark (#1886) | skip |  |
| `8798f02a` | 2026-11-15 | website: read the showcase from egoist/mygo-showcase, through /api/showcase.json | skip |  |
| `21bffed1` | 2026-11-15 | ui: every finger on a touchscreen, by an ID of its own (Element.Touches) (#1884) | pending |  |
| `72dbdcb3` | 2026-11-16 | website: let browsers revalidate the showcase's list | skip |  |
| `32f07ef7` | 2026-11-16 | Keep a menu open when choosing an item, on macOS (#741) | pending |  |
| `ea02bc6b` | 2026-11-15 | fix(cli): staple the notarization ticket to the app inside the disk image (#1898) | pending |  |
| `d6b9a0bd` | 2026-11-16 | windows: destroy the app's windows before the process exits (#1896) (#1897) | pending |  |
| `31bf65e6` | 2026-11-16 | ui: PopoverMenu takes Panel and Item options, as PopoverMenuButton (#1889) | pending |  |
| `61eaaa46` | 2026-11-16 | linux: keep a native menu open on the release that opened it under XWayland (#1890) (#1893) | pending |  |
| `9b6e3eb7` | 2026-11-16 | linux: give apps that Shell opens the display's launch context (#1892) (#1895) | pending |  |
| `690d5a7c` | 2026-11-16 | linux: show the global shortcuts dialog over the app's window (#1891) (#1894) | pending |  |
| `54229b2c` | 2026-11-16 | cli: sync a development build's resources instead of replacing them (#1908) | pending |  |
| `fbe85487` | 2026-11-16 | mygo: hold the single instance lock until the process exits (#1909) | pending |  |
| `8eb67503` | 2026-11-16 | windows: serve custom schemes to iframes of other origins (#1914) | pending |  |
| `9a1c3776` | 2026-11-16 | ui: the size of a finger's contact (Touch.Width, Height) (#1907) | pending |  |
| `62c15032` | 2026-11-16 | ui: fade a translucent web view's page over what is behind the window (#1793) | pending |  |
| `644caa51` | 2026-11-16 | ui: ListState.MoveAnimation glides rows as rows come, go or move around them (#1904) | pending |  |
| `f4392689` | 2026-11-16 | mygo: let a page cancel a call with an AbortSignal (#1781) | pending |  |
| `9db28d4e` | 2026-11-16 | Draw badge backgrounds with colors for KeepOpen items, on macOS (#1913) | pending |  |
| `a0f85319` | 2026-11-16 | mygo: Now Playing lists each artist, and MPRIS raises the player (#1924) | pending |  |
| `25ce62f4` | 2026-11-16 | Release 0.9.2 | skip |  |
| `f7ca0452` | 2026-11-17 | Windows: open local file URLs as native paths (#1917) | pending |  |
| `d6326495` | 2026-11-17 | ui: take a lone \r as a line break in text inputs (#1918) | pending |  |
| `8e7371ae` | 2026-11-17 | ui: keep a submenu open while the pointer heads for it (#1916) (#1919) | pending |  |
| `ac48cf91` | 2026-11-17 | ui: capture paints again after another window moved the shared atlas (#1921) | pending |  |
| `ed9df332` | 2026-11-17 | darwin: hover in panels and flyouts of native UI while another app is active (#1922) | pending |  |
| `fb7e10ab` | 2026-11-17 | fix(windows): keep the pointers passed to Media Foundation calls valid (#1927) | pending |  |
| `7f6965bf` | 2026-11-17 | ui: lay out a tree with fewer reads of its elements (#1928) | pending |  |
| `06b69ea8` | 2026-11-17 | ui: draw glyphs off the baseline where shaping puts them (#1925) (#1929) | pending |  |
| `f1da6e8b` | 2026-11-17 | fix(linux): name a tray icon of no ID after the program, not the process (#1934) | pending |  |
| `8b07ce8c` | 2026-11-17 | markdown/parser: scale incremental edits with reparsed tail (#1936) | pending |  |
| `6ef21918` | 2026-11-17 | richtext: compare paragraph marks without slice allocations (#1938) | pending |  |
| `1604ffe6` | 2026-11-17 | markdown/parser: scale incremental edits with reparsed tail (#1936) | pending |  |
| `0bbb025f` | 2026-11-17 | macOS: order a closing window out before its content goes (#1931) (#1932) | pending |  |
| `0afabc00` | 2026-11-17 | Leave no room after a badge in a menu that stays open, on macOS (#1935) | pending |  |
| `6fbc3c53` | 2026-11-16 | Fix calls and events that waited for good, a window that never showed, and a download's panic (#1941) | pending |  |
| `12e8babd` | 2026-11-17 | feat(editor): let a diff scroll past its end, and focus its active side (#1971) | pending |  |
| `6e712c6e` | 2026-11-17 | Run apps on iOS and Android (#940) | n/a | no mobile backend |
| `0f955b38` | 2026-11-18 | feat(editor): make vertical scroll margin configurable (#1965) | pending |  |
| `6fd33ee0` | 2026-11-18 | richtext: a heading's own line height, Space that takes room away, and quotation bars that join (#1966) | pending |  |
| `d8286ea9` | 2026-11-18 | fix(ui): keep any attached popup within the room the window has (#1958) | pending |  |
| `a875933d` | 2026-11-18 | ui: a triple click selects a paragraph, not the line it wrapped onto (#1943) | pending |  |
| `85ef6db6` | 2026-11-18 | fix(bridge): answer an eval that ran as WebKit froze its page (#1957) | pending |  |
| `158f8dcc` | 2026-11-18 | ui: read a child a container walks in four lines of the element (#1975) | pending |  |
| `55b50cfa` | 2026-11-18 | windows: scroll, pinch and tap with a touchscreen in native UI (carries #1718) (#1911) | pending |  |
| `ebde9399` | 2026-11-17 | Release 0.10.0 | skip |  |
| `ea632323` | 2026-11-18 | darwin: drops reach the page of a web view in native UI (#1946) | pending |  |
| `fc0ae412` | 2026-11-17 | fix(ui): keep a canvas's glyphs and masks for renderers that draw it later (#1977) | pending |  |
| `5be633ac` | 2026-11-17 | Ask WebView2 once for a web view it is creating, and free what the Linux backend left behind (#1978) | pending |  |
| `e88574c8` | 2026-11-18 | ui: Painter.RichText stops re-encoding the spans of an unchanged frame (#1979) | pending |  |
| `76516b5f` | 2026-11-18 | ui: flicking again and again keeps touch content scrolling (#2005) | pending |  |
| `6b66daee` | 2026-11-18 | mobile: pace frames by the display rather than wait for a drawable on the main thread (#2009) | n/a | no mobile backend |
| `b528dac4` | 2026-11-18 | mobile: the iOS display link ticks at the frame rate the content asks for (#2008) | n/a | no mobile backend |
| `a1f55783` | 2026-11-18 | fix(dev): keep rebuilt apps' windows where they were, and behind the editor under -background (#2010) | pending |  |
| `aad9dbc4` | 2026-11-18 | cli: ios.extensions embeds and signs prebuilt app extensions (#2006) | n/a | no mobile backend |
| `d8fc2b07` | 2026-11-18 | cli: android.extractNativeLibs extracts an app's native libraries on install (#2007) | n/a | no mobile backend |
| `513885ed` | 2026-11-18 | render: draw frames on several cores at once (Options.Workers) (#2036) | pending |  |
| `e8aa66f0` | 2026-11-18 | docs: an Android executable shipped as a native library is linked for 16 KB pages (#2015) | skip |  |
| `e1e4364c` | 2026-11-18 | fix(cli): sign simulator apps with their application identifier, which the keychain needs (#2014) | n/a | no mobile backend |
| `ad4cba43` | 2026-11-18 | fix(android): register the fonts an app's main adds before App.Run (#2011) | n/a | no mobile backend |
| `ffa1faf1` | 2026-11-18 | fix(android): keep every face registered under a family (#2012) | n/a | no mobile backend |
| `992cb284` | 2026-11-18 | fix(ui): name the months of the date wheels in the app's language (#2013) | pending |  |
| `24806022` | 2026-11-18 | ui/editor: a diff's find matches the lines it shows (#2001) | pending |  |
| `91835a12` | 2026-11-18 | windows: folder dialogs no longer freeze on WSL shares (#2029) | pending |  |
| `e75b3448` | 2026-11-18 | ui, text: keep parallel Testers' frame stats setting and inline objects apart (#2042) | pending |  |
| `8d72678c` | 2026-11-18 | metal: give back the drawables of windows out of sight half a second after their last frame (#2040) (#2048) | pending |  |
| `b3c62a5d` | 2026-11-18 | ui: clip Tester.AccessInfo.Bounds to visible rect (#1999) | pending |  |
| `9665e789` | 2026-11-18 | ui: DottedUnderline draws dots, as text resolving its style and text morphing dropped them for a solid line (#2026) | pending |  |
| `9eec79ae` | 2026-11-18 | editor: cut the last line whole, and comment a blank line (#2039) | pending |  |
| `aa1d3a10` | 2026-11-18 | ui: report Element.Key after state reads, panicking in Tester (#1993) | pending |  |
| `3aab9bbc` | 2026-11-18 | ui: keep what the layout reads of a child in the item it makes of it (#2020) | pending |  |
| `c805346c` | 2026-11-18 | editor: the horizontal scroll follows lines that get narrower (#2047) | pending |  |
| `23b3b8d5` | 2026-11-18 | fix(mobile): run a script of statements in Page.Eval on iOS and Android (#2023) | n/a | no mobile backend |
| `df45c969` | 2026-11-18 | render: frames that hold still are neither drawn nor encoded again (#2052) | pending |  |
| `f5b6e55f` | 2026-11-18 | render: a video without motion blur draws on one worker (#2058) | pending |  |
| `400ba3b1` | 2026-11-18 | fix(darwin): draw a popover flyout's held frame as it shows again (#2054) | pending |  |
| `c23e036c` | 2026-11-19 | text: browsers get a registered font's weights, widths and style, and lay out again once it loads (#2070) (#2071) | pending |  |
| `e20d2031` | 2026-11-19 | fix(editor): move what Select Smaller and a drag return to with the text (#2072) | pending |  |
| `f168b778` | 2026-11-20 | fix(mobile): type a hardware keyboard's letters into native UI on iOS (#2074) | n/a | no mobile backend |
| `3873650f` | 2026-11-19 | mobile/android: a hardware keyboard's letters type into native UI's text inputs (#2077) | n/a | no mobile backend |
| `4ba6e647` | 2026-11-19 | fix(android): leave the text as it is when the keyboard reports a correction (#2079) | n/a | no mobile backend |
| `d25ed916` | 2026-11-19 | ui: clip a text field's text to its rounded corners (#2069) | pending |  |
| `0b66bc5b` | 2026-11-19 | mobile/android: ship gradlew.bat so Android builds run on Windows (#2063) (#2065) | n/a | no mobile backend |
| `20d551d1` | 2026-11-19 | mobile/android: build with JDK 17 through 25 (#2064) (#2066) | n/a | no mobile backend |
| `6ad8e710` | 2026-11-19 | mobile: Eval runs on Android in a page whose Content Security Policy forbids eval (#2035) | n/a | no mobile backend |
| `119426eb` | 2026-11-19 | richtext: keep scrolled text inside the editor's box (#2031) | pending |  |
| `6f1eab78` | 2026-11-19 | fix(build): keep delta work beside the stage, out of %TEMP% (#2046) | pending |  |
| `61ea5567` | 2026-11-20 | fix(ui): follow the Mac's keys on iOS, where Cmd is Command (#2076) | n/a | no mobile backend |
| `49c8bc4c` | 2026-11-20 | Treat an unset badge alignment as the right default, on macOS (#2038) | pending |  |
| `1bf621c1` | 2026-11-20 | fix(android): ask for the next frame early, vote harder for 120 Hz, hold the splash until Go's frame shows (#2059) | n/a | no mobile backend |
| `ecc89aef` | 2026-11-20 | fix(ui): let a Tester take the text system an ended Tester left (#2087) | pending |  |
| `9af06548` | 2026-11-20 | fix(examples): take Enter from the focused input in the launcher and the flyout, and let the launcher quit (#2092) | skip |  |
| `5da883c0` | 2026-11-20 | fix(windows): normalize Unicode clipboard and drag text line endings (#2021) | pending |  |
| `e55cec57` | 2026-11-20 | fix(richtext): a <br> that ends a block adds no empty paragraph (#2095) (#2096) | pending |  |
| `7d87cf65` | 2026-11-20 | windows: take a window full screen when its page goes full screen (#1872) | pending |  |
| `ceb1b992` | 2026-11-20 | fix(darwin): let the Korean input method take Backspace back a jamo (#2100) | pending |  |
| `9d250927` | 2026-11-20 | feat: PageOptions.ZoomControl, the user's zoom, off by default (#2097) | pending |  |
| `a937351b` | 2026-11-20 | fix(ui): show an app-set NumberInput value on the next build (#2102) | pending |  |
| `84c83bb7` | 2026-11-20 | Size a staying-open menu by its widest row, and give a boxed badge 12pt (#2049) | pending |  |
| `641de152` | 2026-11-20 | Skip a menu relayout when an update changes only a check mark (#2050) | pending |  |
| `f8a45e37` | 2026-11-20 | fix: write the panic that ends the app to crash.log, and show it on phones (#2116) | pending |  |
| `9bfaa2c4` | 2026-11-20 | darwin: WasOpenedAtLogin tells a login item's launch (#2033) | pending |  |
| `bab1ea50` | 2026-11-20 | windows: keep the alpha of images on the clipboard (#2032) | pending |  |
| `5615dcaa` | 2026-11-20 | ui: accept FocusOptions in AutoFocus and Handle.FocusWith (#1995) | pending |  |
| `993b4590` | 2026-11-20 | ui: show a disabled drawn menu item's tooltip, reaching it per platform (#1372) | pending |  |
| `bf9b5cbf` | 2026-11-20 | test(permissionflow): expect the name macOS 27 gives Accessibility (#2086) | skip |  |
| `89e2d883` | 2026-11-20 | ui: leave a button its click in a row DragRows leaves out (#2062) | pending |  |
| `98311208` | 2026-11-20 | feat(editor): show a panel below the caret, and expose the caret's Rect (#1972) | pending |  |
| `75d4e155` | 2026-11-20 | markdown: Options.LinkColor colors a link's text by its destination (#2022) | pending |  |
| `f8f8a8df` | 2026-11-19 | ui: keep moving text locked to its resting pixel phase (#2017) | pending |  |
| `ee97486b` | 2026-11-20 | ui: add SplitGap for spaced or flush Split panes without a divider line (#1997) | pending |  |
| `17c67272` | 2026-11-20 | ui.Table: column virtualization and frozen columns (#1973) | pending |  |
| `f098a223` | 2026-11-19 | editor: show elements between lines (#1662) | pending |  |
| `5778d86f` | 2026-11-20 | text: keep one copy of an app's font, not one an engine or registration (#1948) | pending |  |
| `3a6ad8db` | 2026-11-20 | darwin: a panel takes the keyboard on Show while another app is active (#1284) | pending |  |
| `4b1aa44e` | 2026-11-20 | ui,terminal: pass unhandled zoom and horizontal scroll to outer handlers (#2117) | pending |  |
| `8edef676` | 2026-11-20 | windows: add a thumbnail toolbar under the taskbar preview (#2084) | pending |  |
| `7ba76ed9` | 2026-11-20 | text: add each app font file to fontconfig once a process on Linux (#1947) | pending |  |
| `024dd334` | 2026-11-20 | terminal: report a sideways wheel to a program that takes the mouse (#2118) | pending |  |
| `fd23e445` | 2026-11-20 | test(windows): find a trashed item in the recycle bin by its path, not by counting (#2119) | skip |  |
| `71f6c08b` | 2026-11-20 | ui/editor: bring a fitted viewer's find and go to line into view (#2105) | pending |  |
| `c3bc3a99` | 2026-11-20 | test(ui): find decorations drawn faint, as GTK draws them on Pango 1.50 (#2121) | skip |  |
| `aa6875f0` | 2026-11-20 | test(d3d11): never settle the swap chain in TestUncappedHeldFrameGivenUp (#2122) | skip |  |
| `96dcfd62` | 2026-11-20 | fix(page): an Eval pending in a page left returns an error (#1811) | pending |  |
| `cf6e3605` | 2026-11-20 | fix(windows): a tray icon the notification area refuses stays unadded, and the log says so (#2125) | pending |  |
| `9976b9bc` | 2026-11-20 | fix(text): mirror brackets in right-to-left runs in browsers and on Android (#2129) | n/a | no mobile backend |
| `a87592ba` | 2026-11-20 | fix(ui): ask for the next frame ahead when the view animates as it builds (#2135) | pending |  |
| `c29d682e` | 2026-11-20 | metal: keep two drawables on displays of 60 Hz or less (#2132) | pending |  |
| `044e6ca9` | 2026-11-20 | Revert "metal: keep two drawables on displays of 60 Hz or less (#2132)" | pending |  |
| `1a89ba22` | 2026-11-20 | richtext: hit links only where their text is drawn (#2134) | pending |  |
| `af21abe5` | 2026-11-21 | fix(android): toolbars follow the system's theme, and fit their title under the status bar (#2141) | n/a | no mobile backend |
| `e04a7798` | 2026-11-21 | text: draw a variable font's weights between its named instances on Windows (#2142) | pending |  |
| `2ca120e9` | 2026-11-21 | shell: report where the trash put an item on Windows and Linux (#2147) | pending |  |
| `54bca49c` | 2026-11-21 | ui: Enter clicks a button inside a list's rows, and Tab reaches sortable headers (#2149) | pending |  |
| `f7076071` | 2026-11-21 | fix(darwin): tray 的 flyout 开在图标下方，而不是点击落点 (#2136) | pending |  |
| `66963e44` | 2026-11-21 | window: support WindowOptions.ConsumeActivationClick on Windows and macOS (#1888) (#2094) | pending |  |
| `da283c39` | 2026-11-21 | fix: mark browser touch pointer events for UI gestures (#2133) | pending |  |
| `8ab52a39` | 2026-11-21 | terminal: link a Windows path as a whole, from its drive (#2120) | pending |  |
| `2d814ef1` | 2026-11-21 | ui/editor: show lines deleted after a final newline in a unified diff (#2124) | pending |  |
| `2956c3cf` | 2026-11-21 | fix(examples): open the dialog the Text page's email field promises on that page (#2152) | skip |  |
| `2ec1ac2d` | 2026-11-21 | linux: let a hidden title bar decorate itself on KDE Plasma (#2153) (#2154) | pending |  |
| `3611b55b` | 2026-11-21 | fix(web): show ⌘D, not Ctrl+D, for Cmd+D in a browser on a Mac (#2155) | pending |  |
| `7aaf69f5` | 2026-11-21 | fix(android): pause a web view that native UI doesn't show (#2156) | n/a | no mobile backend |
| `00bd763d` | 2026-11-21 | docs: say in the native modules skill that Kotlin implements views too (#2157) | skip |  |
| `1384cfab` | 2026-11-21 | fix(android): don't pause a ThrottlingOff page native UI doesn't show (#2158) | n/a | no mobile backend |
| `352daf0d` | 2026-11-21 | fix(examples): keep the legend of Users by platform inside its card (#2159) | skip |  |
| `11e3c673` | 2026-11-21 | fix(ui): preserve HoldModifiers across pointer events (#2160) | pending |  |
| `84b3bd6d` | 2026-11-21 | feat(editor): split lines on multi-cursor paste (#2161) | pending |  |
| `26a1657f` | 2026-11-21 | fix(web): only prevent default wheel when scroll is consumed (#2162) | pending |  |
| `3f787aca` | 2026-11-21 | fix(ui,text): avoid ellipsis overflow at zero or narrow widths (#2164) | n/a | no ellipsis truncation in myzig text |
| `a40c02ef` | 2026-11-21 | fix(android): serve Range requests of the app's schemes (video seeking) (#2166) | n/a | no mobile backend |
| `b8249d84` | 2026-11-21 | fix(richtext): don't carry a Markdown mark closed at the end into the next list (#2167) | pending |  |
| `f98751c6` | 2026-11-21 | fix(markdown): indent code blocks with tabs of 4 columns on every system (#2168) | todo-S | markdown code blocks with tabs of 4: needs a tab size in text styles (1217) |
| `edf2ac39` | 2026-11-21 | fix(darwin,ui): accept text inserted while window is non-key (Character Viewer) (#2170) | pending |  |
| `efb83d98` | 2026-11-21 | fix(android): lay a piece of a word out within the word, in its run's direction (#2173) | n/a | no mobile backend |
| `8414e12d` | 2026-11-21 | fix(linux): give web pages a sane screen resolution when GDK has none (#2180) | pending |  |
| `15c6cf6e` | 2026-11-21 | windows: round the corners of transparent Windows 10 windows (#2176) | pending |  |
| `e6d1f440` | 2026-11-21 | fix(text): keep kashidas and ayah numbers in their words, ligatures on Android, and Core Text's widths of right-to-left lines (#2174) | n/a | no mobile backend |
| `e1a96e8e` | 2026-11-21 | fix(protocol): handlers see the length of a request's body (#2181) | pending |  |
| `93c5b897` | 2026-11-21 | test(updater): don't miss the download's progress in TestInstallAndRelaunch (#2182) | skip |  |
| `abb4de88` | 2026-11-21 | fix(ipc): start and stop streaming calls with AbortSignal (#1960) | pending |  |
| `6284bd92` | 2026-11-21 | fix(darwin): keep Dock.SetIcon's icon when the app turns regular (#2185) | pending |  |
| `21b016d7` | 2026-11-21 | fix(examples): pad the Right-click me card on its start side, right to left too (#2187) | skip |  |
| `3021dee3` | 2026-11-21 | d3d11: release textures of collected images when idle (#1926) | pending |  |
| `628ce8c0` | 2026-11-22 | fix(linux): drop the hidden title bar's empty title, so the controls' room is the buttons (#2189) | pending |  |
| `0802b26f` | 2026-11-22 | editor: highlight Astro files, their frontmatter as TypeScript (#2190) | pending |  |
| `9b0ae9ef` | 2026-11-22 | markdown: escape the raw tags a browser reads to their end, as GitHub's tagfilter does (#2193) | ported | markdown HTML: GFM tagfilter (Extensions.tagfilter) |
| `4628106e` | 2026-11-22 | platform: say what a backend cannot do, and still be ErrUnsupported (#2196) | pending |  |
| `a665dd70` | 2026-11-22 | power: keep a Windows app at full speed while it runs out of sight (#2197) | pending |  |
| `a7ffb51a` | 2026-11-22 | i18n: write the quarter of a date, not the letters of its pattern (#2200) | pending |  |
| `827e680f` | 2026-11-22 | tray: say what an empty Bounds means (#2201) | pending |  |
| `dc4a7ea9` | 2026-11-22 | fix(i18n): keep a quarter in words when a number of it is asked, as ICU does (#2202) | pending |  |
| `15d9bc0e` | 2026-11-22 | fix(ui): keep the caret of a text area inside its box at the right edge (#2203) | present | text area wraps 6 points inside its box (textarea_view.zig) |
| `41f31d50` | 2026-11-22 | fix(ui): let a keyboard move a selection made with Shift and the arrows (#2204) | pending |  |
| `8e5c8f9d` | 2026-11-22 | ui: forward Radius and Padding from inline Text elements to their spans (#2211) | pending |  |
| `d5503941` | 2026-11-22 | fix(richtext): let an on-screen keyboard move the editor's selection (#2210) | pending |  |
| `67bf9295` | 2026-11-22 | fix(ui): Space holds a focused button down and clicks it as it goes up (#2212) | todo-M | Space presses a focused button and clicks on key up: needs key up for focused widgets (context.zig interact) |
| `94fda721` | 2026-11-22 | fix(editor): let an on-screen keyboard move the editor's selection (#2214) | pending |  |
| `13f2d99f` | 2026-11-22 | fix(darwin): a two-finger swipe between pages goes back and forward (#2218) | pending |  |
| `ef0b2517` | 2026-11-23 | mobile: draw again after an Android surface resizes, on a new EGL surface (#2221) | n/a | no mobile backend |
| `a0eaaaaf` | 2026-11-23 | fix(cli): pass the inherited environment to process.execve (#2222) | n/a | npm launcher; the myzig CLI is a Zig binary |
