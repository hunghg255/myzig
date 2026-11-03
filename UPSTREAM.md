# Upstream: mygo

myzig ports [mygo](https://github.com/egoist/mygo). This page records how far
it follows it, so the next review starts where this one ended.

**Reviewed through mygo `982590ef` (2026-11-03).** Every mygo commit up to it
is listed below with what myzig did with it. The next review starts from:

```sh
cd ../mygo && git fetch && git log --reverse --oneline 982590ef..origin/main
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
| `165bc985` | 2026-10-24 | l10n: translate MyGo's own strings to Japanese (#692) | todo-S | Japanese strings (l10n) |
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
| `156c6af6` | 2026-10-24 | Fix terminal links for bare filenames (#646) | todo-S | terminal links for bare filenames |
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
| `ee77c770` | 2026-10-26 | Name disk images and Windows installers after the slug (#769) | todo-S | cli: name dmg and installer after the slug |
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
| `b8a5225d` | 2026-10-26 | editor: highlight Dart, GraphQL, R and Scala (#788) (#791) | todo-S | highlight Dart, GraphQL, R, Scala |
| `558e4981` | 2026-10-26 | Delete a Mirror's images by their ids when it starts the other terminal over (#792) | n/a | terminal has no Mirror |
| `8006903c` | 2026-10-26 | ui: let a field's box give AutoFocus and Focus to its input (#793) | present | field box focuses its input (controls_fields.zig) |
| `4dcc873e` | 2026-10-26 | Fold clips that only translate, rather than mask them each frame (#795) | present | translating clips fold into instances (paint_xf.zig) |
| `3407c872` | 2026-10-26 | Let Shift-click extend terminal selections (#590) | todo-S | terminal: Shift-click extends the selection (view.zig, select.zig) |
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
| `5a374d9c` | 2026-10-27 | cli: hooks for the Windows installer (#819) | todo-S | cli: Windows installer hooks (.nsh include) |
| `4426e328` | 2026-10-27 | ci: keep the Linux packages in the Actions cache, and cancel superseded runs on main (#812) | skip |  |
| `e8cf6079` | 2026-10-27 | updater: get updates from a source the app supplies (#820) | todo-M | updater: app-supplied update source |
| `c637faed` | 2026-10-27 | windows: show what is behind transparent windows of native UI (#660) | n/a | no transparent windows option |
| `df5074b6` | 2026-10-27 | ui: name rows by the Labels of what is inside them (#826) | present | rows named by their labels (access_tree.zig) |
| `8e7c49cf` | 2026-10-27 | ui: pass the wheel a handler leaves to the handlers around it (#827) | present | wheel passes outward (gesture.zig) |
| `d20c33a9` | 2026-10-27 | netproxy: follow the system's proxy settings in Go's requests (#799) | skip |  |
| `a9b1c1a6` | 2026-10-27 | mygo: let apps show someone else's pages as untrusted (#829) | todo-M | untrusted pages option |
| `8f71c8e6` | 2026-10-27 | windows: hide embedded web views while their window is hidden (#831) | n/a | embedded pages are child HWNDs |
| `8820ebbe` | 2026-10-27 | cli: let macos.icon be an .icns, for an icon drawn per size (#833) | todo-S | cli: macos.icon as .icns |
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
| `e5547238` | 2026-10-28 | ui: center the calendar's month chevrons (#874) | todo-S | calendar chevrons drawn centered |
| `aa753d22` | 2026-10-29 | linux: defer a window's Hide asked for within its own frame (#877) | n/a | views do not run inside GL render |
| `ac4e0ff0` | 2026-10-29 | editor: continue deletion bars' stripes across lines (#880) | n/a | diff view has no striped bars |
| `a43cfed3` | 2026-10-28 | Release 0.7.2 | skip |  |
| `f27a1253` | 2026-10-29 | ui: forward Placeholder to the input of SearchField, TokenField and Combobox (#884) | present | placeholder forwarded (controls_fields.zig, combobox.zig) |
| `bca8cf33` | 2026-10-29 | macOS: show dialogs opened from a click in native UI (#885) | n/a | click frames run in mouse handlers |
| `d7282567` | 2026-10-29 | ui: draw a menu button's menu in the window with PopoverMenuButton (#886) | present | menuButton draws its menu in the window (menu.zig) |
| `4aca72f1` | 2026-10-29 | ui: run a window's Cmd+V from the Edit menu's Paste on macOS (#889) | present | paste: sends Cmd+V to the view (ui/surface.zig) |
| `cbee0b21` | 2026-10-29 | terminal: scale scrolling with Options.ScrollMultiplier, as Ghostty's mouse-scroll-multiplier (#891) | todo-S | terminal scroll multiplier |
| `c1467c1a` | 2026-10-29 | windows: stop magnifying a native UI window's frames while it resizes (#893) | deferred | needs a visual check on a real machine |
| `6f28d7bb` | 2026-10-29 | Release 0.7.3 | skip |  |
| `23bef6cc` | 2026-10-29 | windows: show the background, not black, where a native UI window shrinks (#895) | deferred | needs a visual check on a real machine |
| `85fd4bba` | 2026-10-29 | ui: open a drawn menu at the pointer on an element scrolled partly out of view (#896) | present | context menus open at the pointer (menu.zig) |
| `2de039ab` | 2026-10-29 | linux: let linux.command name several commands (#900) | ported | cli: linux.command lists several |
| `4712173a` | 2026-10-29 | idlemem: end a Windows app's processes before the next run, and show why an app exited (#901) | skip |  |
| `b7e6bdd3` | 2026-10-29 | ui: let a Calendar page through months without choosing, with Browse (#903) | todo-S | calendar browse |
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
| `003c212e` | 2026-10-30 | terminal: draw block sextants to fix Expo QR code rendering (#920) | todo-S | terminal block sextants |
| `58c3edc2` | 2026-10-30 | Convert disk images with diskutil where hdiutil convert fails (#925) | todo-S | cli: diskutil when hdiutil convert fails |
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
| `dcf169d9` | 2026-10-31 | plugins/updater: report a pending update with AvailableVersion (#960) | todo-S | updater availableVersion |
| `7baaf4db` | 2026-10-31 | ui: placeholder color, dotted underline, Context.Instant, markdown Anchor and LinkWeight (#969) | todo-M | placeholder color, dotted underline, Context.instant, markdown anchor, link weight |
| `49cb9a5f` | 2026-10-31 | ui: let assistive technology edit a custom text client (#967) | present | assistive technology edits text fields (access.zig) |
| `430a0914` | 2026-10-31 | e2e: remove the WebView2 variables test's data folder once the browser lets go (#970) | skip |  |
| `58f0248e` | 2026-10-31 | notifications: let ShowContext cancel the permission wait (#952) | n/a | notify does not wait for permission |
| `f69ccfc7` | 2026-10-31 | ui: enable the Edit menu's roles only while the focus can act on them (#971) | todo-L | Edit menu roles enabled by the focus |
| `a91e9bcb` | 2026-11-01 | ui: CaretWidth and Scrollbars(false), with docs (#972) | todo-S | caretWidth and scrollbars(false) |
| `0d4deffd` | 2026-11-01 | e2e: wheel over ScrollToContainer's pages once they have drawn (#974) | skip |  |
| `7d3f04ca` | 2026-11-01 | windows: set a forced appearance with WebView2's PreferredColorScheme (#975) | ported | WebView2 PreferredColorScheme for a forced appearance |
| `0b9ed5b6` | 2026-11-01 | mygo: document CancelButton's fallback and -1 (#976) | n/a | docs only |
| `33f16102` | 2026-11-01 | watchdriver: run Remove before the test's failure in TestWatch (#977) | skip |  |
| `b0604652` | 2026-11-01 | fix(editor): autoscroll drags past side edges (#735) | todo-S | textarea drag autoscroll past side edges |
| `9bd34e1e` | 2026-11-01 | Release 0.7.4 | skip |  |
| `7d6ed580` | 2026-11-01 | showcase: add Tomoru, live bilingual subtitles for anything you watch (#979) | skip |  |
| `5dbc9d40` | 2026-11-01 | markdown: end extended autolinks at CJK punctuation (#985) | todo-S | markdown autolinks end at CJK punctuation |
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
