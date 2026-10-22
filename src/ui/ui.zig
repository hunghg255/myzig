//! Native UI: views are Zig functions of the app's state, drawn by myzig
//! on the GPU. No HTML, no JavaScript, no webview.
//!
//! Texts given to widgets are copied into the frame's memory (`c.leaf`):
//! a view may free them at once. Other slices (a picture's bytes, an
//! icon's name, a gradient) are read after the view returns: pass the
//! app's own memory or the frame's (`c.print`, `c.alloc()`), never a
//! buffer on the stack.
//!
//!     fn view(s: *Counter, c: *ui.Context) void {
//!         ui.column(c, .{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .gap = 12 });
//!         defer ui.end(c);
//!         ui.textf(c, .{ .size = 40, .weight = .bold }, "{d}", .{s.n});
//!         if (ui.button(c, "Increment", .{ .variant = .primary }).clicked) s.n += 1;
//!     }
const std = @import("std");
const types = @import("types.zig");
const widgets = @import("widgets.zig");
const textfield = @import("textfield.zig");
const ctx_mod = @import("context.zig");

pub const Context = ctx_mod.Context;
pub const Interaction = ctx_mod.Interaction;
pub const FrameStats = ctx_mod.FrameStats;
pub const Shortcut = ctx_mod.Shortcut;
pub const Cursor = ctx_mod.Cursor;
pub const Theme = @import("theme.zig").Theme;
/// Key combinations as the platform writes them: `ui.keys.label("⌘P")`.
pub const keys = @import("keys.zig");
/// A monotonic clock in seconds.
pub const clock = @import("clock.zig");
/// PNG files from pixels (and back, `png_decode`).
pub const png = @import("png.zig");

pub const Point = types.Point;
pub const Size = types.Size;
pub const Rect = types.Rect;
pub const Color = types.Color;
pub const Edges = types.Edges;
pub const Length = types.Length;
pub const Style = types.Style;
pub const TextStyle = types.TextStyle;
pub const Shadow = types.Shadow;
pub const Corners = types.Corners;
pub const Weight = types.Weight;

pub const key = widgets.key;
pub const keyed = widgets.keyed;
pub const column = widgets.column;
pub const row = widgets.row;
pub const end = widgets.end;
pub const pressable = widgets.pressable;
pub const card = widgets.card;
pub const scroll = widgets.scroll;
pub const spacer = widgets.spacer;
pub const divider = widgets.divider;
pub const image = widgets.image;
pub const imageSize = widgets.imageSize;
pub const ImageOptions = widgets.ImageOptions;
pub const text = widgets.text;
pub const textf = widgets.textf;
pub const richText = widgets.richText;
pub const Span = types.Span;
pub const heading = widgets.heading;
pub const icon = widgets.icon;
pub const IconOptions = widgets.IconOptions;
pub const label = widgets.label;
pub const button = widgets.button;
pub const ButtonOptions = widgets.ButtonOptions;
pub const checkbox = widgets.checkbox;
pub const toggle = widgets.toggle;
pub const slider = widgets.slider;
pub const SliderOptions = widgets.SliderOptions;
pub const progress = widgets.progress;
pub const segmented = widgets.segmented;
pub const badge = widgets.badge;
pub const kbd = widgets.kbd;
pub const textField = textfield.textField;
pub const TextFieldOptions = textfield.Options;
pub const TextFieldResult = textfield.Result;
pub const TextBuffer = textfield.TextBuffer;
pub const div = @import("div.zig").div;
pub const Div = @import("div.zig").Div;
pub const list = @import("list.zig").list;
pub const ListOptions = @import("list.zig").Options;
/// A scrolling box's glide to its end (`Style.follow_glide`).
pub const FollowGlide = @import("follow_glide.zig").FollowGlide;
/// The rows chosen in a list or a table (`ListOptions.choice`,
/// `TableState.selection`): `selection_set.zig`.
pub const Selection = @import("selection_set.zig").Selection;
pub const SelectionKey = @import("selection_set.zig").Key;
pub const ListChoice = @import("selection_set.zig").Choice;
pub const ListResult = @import("list_select.zig").Result;
pub const rowDoubleClicked = @import("list_select.zig").rowDoubleClicked;
pub const ListRows = @import("list.zig").Rows;
pub const webView = @import("webview.zig").webView;
pub const WebView = @import("webview.zig").WebView;
pub const WebViewOptions = @import("webview.zig").Options;
pub const WebViewProbe = @import("webview.zig").Probe;
pub const WebViewCoverProbe = @import("webview.zig").CoverProbe;
pub const Tester = @import("tester.zig").Tester;
pub const TesterOptions = @import("tester.zig").Options;

// Overlays: popovers, tooltips, dialogs, toasts, menus, selects.
pub const overlays = @import("overlay_base.zig");
pub const OverlayState = overlays.OverlayState;
pub const popover = @import("popover.zig").popover;
pub const PopoverOptions = @import("popover.zig").PopoverOptions;
pub const PopoverPanel = @import("popover.zig").Panel;
pub const tooltip = @import("popover.zig").tooltip;
pub const tooltipBase = @import("popover.zig").tooltipBase;
pub const tooltipEnd = @import("popover.zig").tooltipEnd;
pub const dialog = @import("dialog.zig").dialog;
pub const Dialog = @import("dialog.zig").Dialog;
pub const DialogOptions = @import("dialog.zig").DialogOptions;
pub const alertDialog = @import("dialog.zig").alertDialog;
pub const AlertResult = @import("dialog.zig").AlertResult;
pub const Toasts = @import("toast.zig").Toasts;
pub const Toast = @import("toast.zig").Toast;
pub const ToastKind = @import("toast.zig").Kind;
pub const ToastResult = @import("toast.zig").Result;
pub const toasts = @import("toast.zig").toasts;
pub const Menu = @import("menu.zig").Menu;
pub const MenuPanel = @import("menu.zig").MenuPanel;
pub const MenuItemOptions = @import("menu.zig").ItemOptions;
pub const menu = @import("menu.zig").menu;
pub const contextMenu = @import("menu.zig").contextMenu;
pub const buttonMenu = @import("menu.zig").buttonMenu;
pub const menuButton = @import("menu.zig").menuButton;
pub const MenuButtonOptions = @import("menu.zig").MenuButtonOptions;
pub const select = @import("select.zig").select;
pub const SelectState = @import("select.zig").SelectState;
pub const SelectOptions = @import("select.zig").SelectOptions;
pub const SelectResult = @import("select.zig").SelectResult;
pub const combobox = @import("combobox.zig").combobox;
pub const ComboboxState = @import("combobox.zig").ComboboxState;
pub const ComboboxResult = @import("combobox.zig").ComboboxResult;
pub const autocomplete = @import("combobox.zig").autocomplete;
pub const AutocompleteState = @import("combobox.zig").AutocompleteState;
pub const AutocompleteResult = @import("combobox.zig").AutocompleteResult;
pub const ComboFieldOptions = @import("combobox.zig").FieldOptions;

// Controls: choices, ranges, fields, dates, times, colors, forms.
const choice = @import("controls_choice.zig");
const range = @import("controls_range.zig");
const fields = @import("controls_fields.zig");
const dates = @import("controls_date.zig");
const times = @import("controls_time.zig");
const colors = @import("controls_color.zig");
const forms = @import("controls_form.zig");
pub const radio = choice.radio;
pub const radioGroup = choice.radioGroup;
pub const Choice = choice.Choice;
pub const RadioGroupOptions = choice.RadioGroupOptions;
pub const rating = choice.rating;
pub const RatingOptions = choice.RatingOptions;
pub const link = choice.link;
pub const LinkOptions = choice.LinkOptions;
pub const historyButtons = choice.historyButtons;
pub const HistoryOptions = choice.HistoryOptions;
pub const HistoryAction = choice.HistoryAction;
pub const rangeSlider = range.rangeSlider;
pub const RangeSliderOptions = range.RangeSliderOptions;
pub const stepper = range.stepper;
pub const StepperOptions = range.StepperOptions;
pub const numberInput = range.numberInput;
pub const NumberInputOptions = range.NumberInputOptions;
pub const meter = range.meter;
pub const MeterOptions = range.MeterOptions;
pub const spinner = range.spinner;
pub const SpinnerOptions = range.SpinnerOptions;
pub const searchField = fields.searchField;
pub const SearchFieldOptions = fields.SearchFieldOptions;
pub const SearchResult = fields.SearchResult;
pub const tokenField = fields.tokenField;
pub const TokenFieldOptions = fields.TokenFieldOptions;
pub const Tokens = fields.Tokens;
pub const avatar = fields.avatar;
pub const AvatarOptions = fields.AvatarOptions;
pub const Date = dates.Date;
pub const calendar = dates.calendar;
pub const CalendarOptions = dates.CalendarOptions;
pub const dateInput = dates.dateInput;
pub const DateInputOptions = dates.DateInputOptions;
pub const DateFormat = dates.DateFormat;
pub const Time = times.Time;
pub const timeInput = times.timeInput;
pub const TimeInputOptions = times.TimeInputOptions;
pub const colorPicker = colors.colorPicker;
pub const colorWell = colors.colorWell;
pub const ColorPicker = colors.ColorPicker;
pub const parseHex = colors.parseHex;
pub const field = forms.field;
pub const Field = forms.Field;
pub const FieldOptions = forms.FieldOptions;
pub const form = forms.form;
pub const Form = forms.Form;
pub const FormOptions = forms.FormOptions;
pub const fieldset = forms.fieldset;
pub const FieldsetOptions = forms.FieldsetOptions;
pub const validate = forms.validate;
pub const Validation = forms.Validation;

// Structures: tabs, disclosures, splits, sidebars, toolbars, trees, tables, grids.
pub const tabs = @import("tabs.zig").tabs;
pub const TabsOptions = @import("tabs.zig").Options;
pub const collapsible = @import("collapsible.zig").collapsible;
pub const Disclosure = @import("collapsible.zig").Disclosure;
pub const accordion = @import("collapsible.zig").accordion;
pub const Accordion = @import("collapsible.zig").Accordion;
pub const AccordionOptions = @import("collapsible.zig").AccordionOptions;
pub const split = @import("split.zig").split;
pub const Split = @import("split.zig").Split;
pub const SplitOptions = @import("split.zig").Options;
pub const sidebar = @import("sidebar.zig").sidebar;
pub const Sidebar = @import("sidebar.zig").Sidebar;
pub const SidebarOptions = @import("sidebar.zig").Options;
pub const SidebarItemOptions = @import("sidebar.zig").ItemOptions;
pub const toolbar = @import("toolbar.zig").toolbar;
pub const Toolbar = @import("toolbar.zig").Toolbar;
pub const ToolbarOptions = @import("toolbar.zig").Options;
pub const breadcrumbs = @import("breadcrumbs.zig").breadcrumbs;
pub const BreadcrumbsOptions = @import("breadcrumbs.zig").Options;
pub const tree = @import("tree.zig").tree;
pub const Tree = @import("tree.zig").Tree;
pub const TreeOptions = @import("tree.zig").Options;
pub const outline = @import("outline.zig").outline;
pub const OutlineState = @import("outline.zig").OutlineState;
pub const OutlineOptions = @import("outline.zig").Options;
pub const OutlineRow = @import("outline.zig").Row;
pub const table = @import("table.zig").table;
pub const Table = @import("table.zig").Table;
pub const TableColumn = @import("table.zig").Column;
pub const TableState = @import("table.zig").TableState;
pub const TableCellMenu = @import("table.zig").CellMenu;
pub const TableSort = @import("table.zig").Sort;
pub const TableOptions = @import("table.zig").Options;
pub const gridView = @import("gridview.zig").gridView;
pub const GridView = @import("gridview.zig").GridView;
pub const GridState = @import("gridview.zig").GridState;
pub const GridViewOptions = @import("gridview.zig").Options;

// Drawing: canvases of paths, SVG pictures, charts.
pub const canvas = @import("canvas.zig").canvas;
/// The canvas's visible part from the previous paint, for animation culling.
pub const canvasVisibility = @import("canvas_visible.zig").of;
pub const CanvasOptions = @import("canvas.zig").CanvasOptions;
pub const Painter = @import("canvas.zig").Painter;
pub const Path = @import("path.zig").Path;
pub const PathData = @import("path.zig").Data;
pub const FillRule = @import("path.zig").Rule;
pub const Transform = @import("path.zig").Transform;
pub const Paint = @import("canvas_paint.zig").Paint;
pub const GradientStop = @import("canvas_paint.zig").Stop;
pub const LinearGradient = @import("canvas_paint.zig").Linear;
pub const RadialGradient = @import("canvas_paint.zig").Radial;
pub const Stroke = @import("path_stroke.zig").Stroke;
pub const LineJoin = @import("path_stroke.zig").Join;
pub const LineCap = @import("path_stroke.zig").Cap;
pub const svg = @import("svg.zig").svg;
pub const SvgOptions = @import("svg.zig").SvgOptions;
pub const rasterizeSvg = @import("svg.zig").rasterize;
pub const chart = @import("chart/chart.zig");

// Markdown: CommonMark and GitHub's extensions, streaming.
pub const markdown = @import("markdown/view.zig").markdown;
pub const Markdown = @import("markdown/view.zig").Markdown;
pub const MarkdownOptions = @import("markdown/view.zig").Options;
pub const MarkdownImage = @import("markdown/view.zig").Image;
pub const MarkdownImageReader = @import("markdown/view.zig").ImageReader;
pub const MarkdownResult = @import("markdown/view.zig").Result;
pub const MarkdownHighlighter = @import("markdown/view.zig").Highlighter;
pub const MarkdownDocument = @import("markdown/document.zig").Document;
pub const MarkdownExtensions = @import("markdown/document.zig").Extensions;

// Multi-line text, the code editor and the diff viewer.
pub const TextArea = @import("textarea.zig").TextArea;
pub const textArea = @import("textarea_view.zig").textArea;
pub const TextAreaOptions = @import("textarea_view.zig").Options;
pub const TextAreaResult = @import("textarea_view.zig").Result;
pub const TextDoc = @import("textdoc.zig").TextDoc;
pub const TextSel = @import("textdoc.zig").Sel;
pub const Rope = @import("rope.zig").Rope;
pub const CodeEditor = @import("editor/editor.zig").CodeEditor;
/// Whether a field of a find bar of the app's own took Escape (`CodeEditor.own_find_bar`).
pub const findBarEscaped = @import("editor/findbar.zig").escaped;
pub const codeEditor = @import("editor/editor.zig").codeEditor;
pub const CodeEditorOptions = @import("editor/editor.zig").Options;
pub const languageFor = @import("editor/syntax.zig").languageFor;
/// A background of a run of a line, as the code editor's `extra.marks` return them.
pub const TextMark = @import("textarea_view.zig").Mark;
/// Text after a line's end, as the code editor's `extra.after` returns it.
pub const TextAfter = @import("textarea_view.zig").After;
/// A line a text area built and its top in the view (`Result.lines`).
pub const TextLineTop = @import("textarea_decor.zig").LineTop;
/// The code editor's regular expressions (find, and the app's searches).
pub const Regex = @import("editor/regex.zig").Regex;
/// The colors of the highlighter's tokens (`CodeEditor.syntax.colors`).
pub const SyntaxColors = @import("markdown/highlight.zig").Colors;
pub const DiffView = @import("diffview_model.zig").DiffView;
pub const DiffMode = @import("diffview_model.zig").Mode;
pub const diffView = @import("diffview.zig").diffView;
/// One row of a diff, and the rows' height, for lists of several diffs.
pub const diffRow = @import("diffview.zig").diffRow;
pub const diffRowHeight = @import("diffview.zig").rowHeight;
/// A diff's row wrapped: one of its pieces, how many it takes, and how many
/// characters a side has room for.
pub const diffRowPart = @import("diffview.zig").diffRowPart;
pub const diffRowParts = @import("diffview.zig").rowParts;
pub const diffWrapColumns = @import("diffview.zig").wrapColumns;
pub const DiffViewOptions = @import("diffview.zig").Options;
pub const diff = @import("diff.zig");

// Rich text: the editor of paragraphs with styles and marks.
pub const richtext = @import("richtext/richtext.zig");
pub const RichText = richtext.RichText;
pub const richTextEditor = richtext.editor;
pub const richTextEditorBase = richtext.editorBase;
pub const RichTextOptions = richtext.Options;
pub const RichTextResult = richtext.Result;
pub const richTextToolbar = richtext.toolbar;
pub const RichTextToolbarOptions = richtext.ToolbarOptions;
pub const RichTextToolbarResult = richtext.ToolbarResult;

// Drag and drop within a window, and out of it.
pub const DragDrop = @import("dragdrop.zig").DragDrop;
pub const Draggable = @import("dragdrop.zig").Draggable;
pub const DraggableOptions = @import("dragdrop.zig").DraggableOptions;
pub const DropTargetOptions = @import("dragdrop.zig").TargetOptions;
pub const DropTargetResult = @import("dragdrop.zig").TargetResult;
pub const Drop = @import("dragdrop.zig").Drop;
pub const DragFinished = @import("dragdrop.zig").Finished;
pub const DragExternalEnd = @import("dragdrop.zig").ExternalEnd;
pub const DragExternal = @import("dragdrop.zig").External;

// Transforms, gradients, blur, backdrop effects, motion.
pub const Affine = types.Affine;
pub const Gradient = types.Gradient;
pub const Stop = types.Stop;
pub const Effect = types.Effect;
pub const effect = @import("effect.zig");
pub const motion = @import("motion.zig");
/// GPU renderers against the CPU one, for plugins' tests.
pub const gpu_testing = @import("gpu_fx_test.zig");
/// What changed between frames, for renderers that draw only that.
pub const damage = @import("damage.zig");
/// The Direct3D 11 renderer (Windows), for benchmarks.
pub const d3d11 = if (@import("builtin").os.tag == .windows) @import("d3d11.zig") else struct {};

// Right to left, grids, focus groups, actions, navigation, preferences, themes, the inspector.
pub const direction = @import("direction.zig");
pub const Direction = direction.Direction;
pub const grid = @import("grid.zig").grid;
pub const Grid = @import("grid.zig").Grid;
pub const GridTrack = @import("grid.zig").Track;
pub const GridCell = @import("grid.zig").Cell;
pub const GridOptions = @import("grid.zig").Options;
pub const GridAlign = @import("grid.zig").Align;
pub const focusGroup = @import("focusgroup.zig").focusGroup;
pub const FocusGroup = @import("focusgroup.zig").FocusGroup;
pub const FocusGroupOptions = @import("focusgroup.zig").Options;
pub const FocusGroupResult = @import("focusgroup.zig").Result;
pub const Orientation = @import("focusgroup.zig").Orientation;
pub const Actions = @import("actions.zig").Actions;
pub const Action = @import("actions.zig").Action;
pub const shortcutLabel = @import("actions.zig").label;
pub const Router = @import("router.zig").Router;
pub const Route = @import("router.zig").Route;
pub const RouterPages = @import("router.zig").Pages;
pub const RouterOptions = @import("router.zig").Options;
pub const RouteTransition = @import("router.zig").Transition;
pub const preferences = @import("preferences.zig");
pub const Preferences = preferences.Preferences;
pub const themes = @import("themes.zig");
pub const ThemeSwitcher = themes.Switcher;
pub const Inspector = @import("inspector.zig").Inspector;
pub const inspector = @import("inspector.zig").inspector;
pub const oklch = @import("oklch.zig").oklch;
pub const toOklch = @import("oklch.zig").toOklch;
pub const Handle = @import("handle.zig").Handle;
pub const checkboxGroup = @import("checkgroup.zig").checkboxGroup;

// Accessibility: what assistive technology reads of the view.
pub const access = @import("access.zig");
pub const AccessRole = access.Role;
pub const AccessDescription = access.Description;
pub const AccessTree = @import("access_tree.zig").Tree;

// Shaders apps write once, drawn by every renderer.
pub const shader = @import("shader/shader.zig");
pub const Shader = shader.Shader;
pub const shaderBox = shader.box.shaderBox;
pub const shaderBoxWith = shader.box.shaderBoxWith;
pub const shaderEffect = shader.box.effectOf;
pub const ShaderBoxOptions = shader.box.Options;
/// Keys by their place on the keyboard, whatever its layout.
pub const KeyCode = @import("keycode.zig").KeyCode;

/// What text input brings, for views that take it themselves.
pub const TextOp = ctx_mod.TextOp;
pub const TextCommand = ctx_mod.Command;
pub const Input = ctx_mod.Input;
pub const InputEvent = @import("gesture.zig").InputEvent;

/// What a window of native UI shows: `build` runs on every frame.
pub const View = struct {
    ptr: *anyopaque,
    build: *const fn (ptr: *anyopaque, c: *Context) void,

    /// `View.init(&state, State.view)` where `fn view(s: *State, c: *ui.Context) void`.
    pub fn init(ptr: anytype, comptime build_fn: fn (@TypeOf(ptr), *Context) void) View {
        const P = @TypeOf(ptr);
        return .{
            .ptr = @ptrCast(ptr),
            .build = struct {
                fn call(p: *anyopaque, c: *Context) void {
                    build_fn(@as(P, @ptrCast(@alignCast(p))), c);
                }
            }.call,
        };
    }
};

test {
    _ = @import("tests_gesture.zig");
    _ = @import("tests_window_buttons.zig");
    _ = types;
    _ = @import("layout.zig");
    _ = textfield;
    _ = @import("tests.zig");
    _ = @import("tests_cursor.zig");
    _ = @import("tests_overlay.zig");
    _ = @import("tests_focus.zig");
    _ = @import("tests_webview.zig");
    _ = @import("tests_webview_covers.zig");
    _ = @import("input.zig");
    _ = @import("overlay_base.zig");
    _ = @import("listbox.zig");
    _ = @import("tests_overlays_popover.zig");
    _ = @import("tests_overlays_menu.zig");
    _ = @import("tests_overlays_select.zig");
    _ = @import("controls_state.zig");
    _ = @import("tests_controls_choice.zig");
    _ = @import("tests_controls_range.zig");
    _ = @import("tests_controls_fields.zig");
    _ = @import("tests_controls_date.zig");
    _ = @import("tests_controls_color.zig");
    _ = @import("tests_controls_form.zig");
    _ = @import("structure.zig");
    _ = @import("tests_structures_panes.zig");
    _ = @import("tests_structures_nav.zig");
    _ = @import("tests_structures_lists.zig");
    _ = @import("tests_outline_keys.zig");
    _ = @import("d3d11_test.zig");
    _ = @import("gl_test.zig");
    _ = @import("gl_gtk_test.zig");
    _ = @import("rope.zig");
    _ = @import("textdoc.zig");
    _ = @import("textarea.zig");
    _ = @import("editor/regex.zig");
    _ = @import("editor/syntax.zig");
    _ = @import("tests_textarea.zig");
    _ = @import("tests_keys.zig");
    _ = @import("tests_motion_exits.zig");
    _ = @import("tests_access_insert.zig");
    _ = @import("tests_editor_bounds.zig");
    _ = @import("tests_select_long.zig");
    _ = @import("tests_wheel.zig");
    _ = @import("tests_layout_css.zig");
    _ = @import("tests_baseline.zig");
    _ = @import("tests_form_baselines.zig");
    _ = @import("tests_layout_cache.zig");
    _ = @import("tests_frame_strings.zig");
    _ = @import("tests_scroll_check.zig");
    _ = @import("tests_table_cells.zig");
    _ = @import("tests_table_select.zig");
    _ = @import("tests_list_select.zig");
    _ = @import("selection_set.zig");
    _ = @import("tests_follow_glide.zig");
    _ = @import("tests_canvas_visible.zig");
    _ = @import("tests_textarea_long.zig");
    _ = @import("textlayout_long.zig");
    _ = @import("raster_corner.zig");
    _ = @import("gpu_corners.zig");
    _ = @import("gpu_corners_test.zig");
    _ = @import("layout_flex.zig");
    _ = @import("table_cells.zig");
    _ = @import("textarea_view.zig");
    _ = @import("damage_test.zig");
    _ = @import("tests_paint_cull.zig");
    _ = @import("tests_idle.zig");
    _ = @import("tests_text_shaping.zig");
    _ = @import("tests_text_rtl.zig");
    _ = @import("tests_editor.zig");
    _ = @import("tests_diff.zig");
    _ = @import("richtext/richtext.zig");
    _ = @import("tests_richtext.zig");
    _ = @import("tests_richtext_marks.zig");
    _ = @import("tests_richtext_clip.zig");
    _ = @import("tests_dragdrop.zig");
    _ = @import("transform.zig");
    _ = @import("hit.zig");
    _ = @import("paint_xf.zig");
    _ = @import("gradient.zig");
    _ = @import("effect.zig");
    _ = @import("backdrop.zig");
    _ = @import("motion.zig");
    _ = @import("motion_keyframes.zig");
    _ = @import("tests_transform.zig");
    _ = @import("tests_motion.zig");
    _ = @import("gpu_fx_test.zig");
    _ = @import("tests_direction.zig");
    _ = @import("tests_grid.zig");
    _ = @import("focusgroup.zig");
    _ = @import("tests_focusgroup.zig");
    _ = @import("tests_press_check.zig");
    _ = @import("actions.zig");
    _ = @import("tests_actions.zig");
    _ = @import("preferences.zig");
    _ = @import("themes.zig");
    _ = @import("tests_themes.zig");
    _ = @import("router.zig");
    _ = @import("router_view.zig");
    _ = @import("tests_router.zig");
    _ = @import("tests_inspector.zig");
    _ = @import("oklch.zig");
    _ = @import("handle.zig");
    _ = @import("checkgroup.zig");
    _ = @import("access.zig");
    _ = @import("tests_access.zig");
    _ = @import("tests_access_widgets.zig");
    _ = @import("shader/ir.zig");
    _ = @import("shader/lex.zig");
    _ = @import("shader/parse.zig");
    _ = @import("shader/ops.zig");
    _ = @import("shader/tests_compile.zig");
    _ = @import("shader/tests_gpu.zig");
    _ = @import("tests_raster_dither.zig");
    _ = @import("tests_widgets_more.zig");
    _ = @import("keycode.zig");
    _ = @import("shader_min.zig");
    _ = @import("path.zig");
    _ = @import("path_raster.zig");
    _ = @import("path_stroke.zig");
    _ = @import("canvas_paint.zig");
    _ = @import("tests_canvas.zig");
    _ = @import("svg_xml.zig");
    _ = @import("svg_colors.zig");
    _ = @import("svg_style.zig");
    _ = @import("svg_pathdata.zig");
    _ = @import("tests_svg.zig");
    _ = @import("chart/chart.zig");
    _ = @import("tests_chart.zig");
    _ = @import("markdown/scan.zig");
    _ = @import("markdown/block_scan.zig");
    _ = @import("markdown/autolink.zig");
    _ = @import("markdown/heal.zig");
    _ = @import("markdown/highlight.zig");
    _ = @import("markdown/highlight_langs.zig");
    _ = @import("markdown/highlight_markup.zig");
    _ = @import("textarea_decor.zig");
    _ = @import("textarea_rows.zig");
    _ = @import("markdown/tests_spec_a.zig");
    _ = @import("markdown/tests_spec_b.zig");
    _ = @import("markdown/tests_spec_gfm.zig");
    _ = @import("markdown/tests_parser.zig");
    _ = @import("markdown/tests_view.zig");
    _ = @import("markdown/tests_stream.zig");
    // CoreText's fast path, on macOS.
    if (!@import("text.zig").portable) _ = @import("shaper.zig");
    _ = @import("raster.zig");
    _ = @import("raster_lanes.zig");
    _ = @import("raster_fill.zig");
    _ = @import("tests_raster.zig");
    _ = @import("tt/raster.zig");
    _ = @import("tt/tests.zig");
    _ = @import("png.zig");
    _ = @import("png_decode.zig");
    _ = @import("images.zig");
    _ = @import("icons.zig");
    _ = keys;
}
