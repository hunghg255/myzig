//! What the page's JavaScript (`host.js`) gives the app in a browser: the
//! functions it imports from the module "myzig". Strings and buffers are
//! a pointer and a length into the WebAssembly memory; windows are known
//! by their address (`id`).
pub extern "myzig" fn window_open(id: u32, title: [*]const u8, title_len: usize) void;
pub extern "myzig" fn window_close(id: u32) void;
pub extern "myzig" fn window_title(id: u32, title: [*]const u8, title_len: usize) void;
/// One `requestAnimationFrame` for the window (once, until it runs).
pub extern "myzig" fn request_frame(id: u32) void;
pub extern "myzig" fn set_cursor(id: u32, cursor: u32) void;
/// Where the caret is, for the input method's text area out of sight
/// (in CSS pixels of the canvas); `focused` false when no text has focus.
pub extern "myzig" fn text_area(id: u32, x: f32, y: f32, w: f32, h: f32, focused: bool) void;
/// Calls `myzig_web_timer(token)` after `ms` milliseconds.
pub extern "myzig" fn set_timeout(ms: f64, token: u32) void;
pub extern "myzig" fn clipboard_write(text: [*]const u8, len: usize) void;
pub extern "myzig" fn open_url(url: [*]const u8, len: usize) bool;
/// `alert` (`buttons` <= 1) or `confirm`: the index of the button pressed.
pub extern "myzig" fn message(text: [*]const u8, len: usize, buttons: u32) u32;
pub extern "myzig" fn is_dark() bool;
pub extern "myzig" fn beep() void;
/// Ends `main` without returning (an exception the host catches): the
/// browser's events drive the app from then on, and `main`'s stack stays.
pub extern "myzig" fn run() noreturn;
/// The app quit: the host takes its canvases away.
pub extern "myzig" fn quit() void;

/// Shows BGRA premultiplied pixels drawn on the CPU (no WebGL 2).
pub extern "myzig" fn blit(id: u32, pixels: [*]const u8, width: u32, height: u32) void;
/// `navigator.languages` joined by commas into `buf`; the bytes written.
pub extern "myzig" fn languages(buf: [*]u8, cap: usize) usize;
