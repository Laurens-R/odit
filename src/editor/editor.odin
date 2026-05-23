package editor

import "vendor:sdl3"
import "vendor:sdl3/ttf"

import "../dap"
import "../document"
import binding_pkg "./binding"
import breakpoint_condition_pkg "./breakpoint_condition"
import browse_pkg "./browse"
import close_confirm_pkg "./close_confirm"
import debug_pkg "./debug"
import diff_pkg "./diff"
import completion_popup_pkg "./completion_popup"
import find_in_files_pkg "./find_in_files"
import git_history_pkg "./git_history"
import help_pkg "./help"
import hover_pkg "./hover"
import menu_pkg "./menu"
import open_docs_pkg "./open_docs"
import replace_in_files_pkg "./replace_in_files"
import save_as_pkg "./save_as"
import signature_popup_pkg "./signature_popup"
import symbols_pkg "./symbols"
import tasks_dialog_pkg "./tasks_dialog"
import terminal_picker_pkg "./terminal_picker"
import "../keybindings"
import "../lsp"
import "../markdown"
import "../syntax"
import "../terminal"
import "../ui"

// --- Pane types -----------------------------------------------------------
//
// A `Pane` is a generic container that occupies a rectangle in the window.
// Each pane holds exactly one piece of `PaneContent` — currently only an
// editor, but the union is the place to add browser panes, terminal panes,
// settings panes, etc. without touching the rest of the codebase. Routing
// of input/render based on content type happens at well-defined dispatch
// points in `input.odin` and `render.odin`.

// `EditorPane` is the per-document state for a pane displaying a text buffer:
// its document, cursor, scroll position, and selection. Multiple editor panes
// can coexist (each is independent), and a pane's content can be swapped to a
// different content type later without disturbing this struct.
EditorPane :: struct {
	document:        document.Document,
	file_path:       string, // owned absolute path; "" for an untitled doc
	// Optional title-bar override; when non-empty the pane shows this label
	// instead of `filepath_base(file_path)`. Used by F3's git-history viewer
	// to surface "filename @ short-hash" without retargeting the pane at a
	// fake on-disk path that Ctrl+S would then happily overwrite.
	display_title_override: string, // owned, "" when not overridden
	language:        ^syntax.Definition, // nil → plain text rendering
	symbols:         [dynamic]syntax.Symbol,           // declarations found in this doc (owned names)
	symbol_names:    map[string]syntax.SymbolKind,     // set view of `symbols` for fast highlighter lookup

	// Cursor position (in document coordinates)
	cursor_line:     u32,
	cursor_column:   u32, // byte offset within the line
	cursor_offset:   u32, // absolute byte offset in document

	// Viewport (which portion of the document is visible)
	scroll_line:     u32, // first visible line (derived from scroll_y)
	visible_lines:   u32, // how many lines fully fit on screen
	scroll_y:        f32, // current vertical scroll, in pixels (animated)
	scroll_y_target: f32, // target vertical scroll, in pixels

	// Horizontal scroll, in pixels. Used only when `wrap_mode == false`;
	// flipping to wrap clears `scroll_x_target` to 0. Animated identically
	// to scroll_y for parity.
	scroll_x:        f32,
	scroll_x_target: f32,

	// When true, lines that exceed the pane's available text width are
	// broken into multiple visual rows that fit the pane. When false,
	// long lines remain on a single row and the user pans horizontally
	// with scroll_x. Toggled by Ctrl+W.
	wrap_mode:       bool,

	// Interactive scrollbar state. The renderer writes the current
	// `track_rectangle` / `thumb_rectangle` here every frame; mouse
	// handlers in `mouse.odin` read those rects to hit-test hover and
	// drag. `is_hovered` widens the next paint; `is_dragging` locks scroll
	// updates onto the thumb under the cursor.
	scrollbar:       ui.Scrollbar,

	// Selection
	selection_active:  bool,
	selection_anchor:  u32, // byte offset of selection anchor (other end is cursor_offset)
	mouse_dragging:    bool, // left mouse button held; motion extends selection

	gutter_width:    i32, // line-number gutter width in pixels (set during render)

	// Symbol re-analysis bookkeeping. `symbols_dirty` flips true whenever the
	// pane's document is mutated; `last_analysis_time` is `editor.clock` at the
	// last rebuild. Together with `Editor.last_keystroke_time` they gate the
	// auto-reanalyze pass in `editor_update`.
	symbols_dirty:        bool,
	last_analysis_time:   f64,

	// Same idea as `symbols_dirty` but for the markdown preview's idle
	// auto-refresh. Set on every document mutation; cleared once the preview
	// re-parses the source (or eagerly when no preview is open).
	markdown_dirty:       bool,

	// LSP sync bookkeeping. `lsp_did_open_sent` flips true once a didOpen
	// notification has been issued for the pane's current file path; the
	// close path uses it to know whether a matching didClose is required.
	// `lsp_dirty` + `lsp_last_edit_time` debounce didChange so the editor
	// doesn't spam the server on every keystroke.
	lsp_did_open_sent:    bool,
	lsp_dirty:            bool,
	lsp_last_edit_time:   f64,
}

// A pane that hosts an embedded terminal emulator instead of a document.
// The terminal owns a child shell process, a read thread, and a cell-grid
// screen — see the `terminal` package. We store a pointer rather than the
// terminal by value so the union variant stays a single word and the
// terminal's internal pointers (mutex, thread handle) are address-stable.
//
// Tagged union of all pane content kinds. Add variants here as new pane types
// are introduced. `TerminalPane` lives in `terminal.odin`.
PaneContent :: union {
	EditorPane,
	TerminalPane,
	MarkdownPreviewPane,
	OutputPane,
}

// A pane is a generic container that owns a screen rectangle and one piece of
// content. The renderer/input dispatcher type-switches on `content`.
//
// `saved_content` is a stash slot. When F9 turns a pane into a terminal we
// move the previous content (typically an EditorPane) into `saved_content`
// so the original document is preserved untouched while the terminal runs.
// `saved_split_active` remembers `Editor.split_active` at the same moment so
// F9-close can put the editor back into single- vs split-pane mode exactly
// the way the user left it.
Pane :: struct {
	rectangle:           sdl3.Rect,
	content:             PaneContent,
	saved_content:       PaneContent, // zero-value when nothing stashed
	saved_split_active:  bool,
	has_saved_content:   bool,
}

// Top-level editor state. Shared resources (font, modals, palette) live here;
// per-pane state lives in `panes`. `active_pane_index` selects which pane
// receives keyboard input and is shown with the visible cursor (when its
// content is an editor pane).
Editor :: struct {
	panes:             [2]Pane,
	active_pane_index: int,  // 0 or 1
	split_active:      bool, // when false, only panes[0] is rendered (full width)

	// Active keybinding table. Populated from the per-platform default JSON
	// (`src/keybindings/defaults/<os>.json`) at startup; consulted by
	// `editor_handle_event` and a couple of modal handlers to map raw
	// (key, modifier) chords to named `keybindings.Action` values.
	keybindings: keybindings.Bindings,

	// Split divider position when `split_active`. Stored as a fraction of
	// the full window width (left pane share), so the layout adapts to
	// window resizes for free. Initialized in `editor_init`; updated by the
	// drag handler in `mouse.odin`.
	split_ratio:      f32,
	divider_dragging: bool,

	// System cursors cached at startup so we can swap shapes on hover /
	// drag of the pane divider without paying the per-frame cost of
	// CreateSystemCursor. `current_cursor` lets us avoid redundant
	// SetCursor calls each frame.
	cursor_default:   ^sdl3.Cursor,
	cursor_resize_ew: ^sdl3.Cursor,
	cursor_resize_ns: ^sdl3.Cursor,
	current_cursor:   ^sdl3.Cursor,

	// Last-seen mouse position from the SDL event stream. Threaded into
	// every `ui.Context` (via `editor_make_ui_context`) so generic UI
	// primitives — buttons, list rows — can auto-detect hover without
	// callers having to track it themselves.
	last_mouse_x:    f32,
	last_mouse_y:    f32,

	// Per-render TTF text cache. The editor renders many short strings
	// (one per syntax token) every frame, most of which repeat from one
	// frame to the next; caching avoids the GPU-texture churn that comes
	// from `ttf.CreateText` + `ttf.DestroyText` round-trips.
	text_cache: ui.TextCache,

	// Frame-skip flag. The main loop calls `editor_render` + `RenderPresent`
	// only when this is set, then clears it via `editor_mark_clean`. Setters
	// are scattered: every input handler, the cursor-blink toggle, terminal
	// output drains, smooth-scroll animation, window resize. When nothing's
	// happening, the entire render path is skipped and we just `Sleep(16)`.
	needs_redraw: bool,

	// Rendering (shared between panes)
	font:             ^ttf.Font,
	text_engine:      ^ttf.TextEngine,
	font_size:        f32,
	character_width:  i32,
	line_height:      i32,
	padding_x:        i32,
	padding_y:        i32,

	// Blink (shared rhythm; cursor only drawn in the active pane's editor)
	cursor_visible:  bool,
	cursor_timer:    f64,

	// Monotonic clock (seconds) accumulated from `editor_update`'s delta_time.
	// Used as the time base for auto-reanalysis debouncing.
	clock:                f64,
	last_keystroke_time:  f64,

	// Render-rate counter for the debug-build FPS readout in the status bar.
	// Ticked from `editor_record_frame_presented` (called by main.odin right
	// after `sdl3.RenderPresent`), so the number reflects frames actually
	// pushed to the screen — not loop iterations, which would be pinned at
	// ~60 by main.odin's sleep regardless of whether anything redrew. A dip
	// here is real and indicates a slow render path.
	fps_window_seconds:   f64,
	fps_window_frames:    i32,
	fps_last_value:       i32,

	// Modal UI
	// Plugin-style modal registry. Each subpackage installs a
	// `binding.Binding` into `bindings` in `editor_init`; input.odin
	// iterates them in priority order, render.odin paints them on
	// top of everything else. `editor_api` is the editor-side
	// surface every binding receives on each dispatch call.
	editor_api: binding_pkg.EditorAPI,
	bindings:   [dynamic]binding_pkg.Binding,

	// F1 help dialog. Self-owned by the `help` subpackage — visibility,
	// scroll offset, and scrollbar state all live inside `help.State`. The
	// editor only knows about it as one of the modal states in
	// `editor_is_modal_open` and as a render dispatch case.
	help: help_pkg.State,
	// F2 file browser. UI + filter + sub-popup + fs ops + undo stack
	// all live in the `browse` subpackage; the editor only owns the
	// State and registers the subpackage with the binding registry
	// below.
	browse_view:         browse_pkg.State,

	// Diff mode (compares views[0]'s doc against views[1]'s doc)
	diff_state:      diff_pkg.State,

	// Colors (terminal palette)
	background_color:  sdl3.FColor,
	foreground_color:  sdl3.FColor,
	cursor_color:      sdl3.FColor,
	line_number_color: sdl3.FColor,
	selection_color:   sdl3.FColor,
	status_bar_background: sdl3.FColor,
	status_bar_foreground: sdl3.FColor,
	divider_color:     sdl3.FColor,

	// Diff-mode row backgrounds
	diff_delete_background:  sdl3.FColor, // line only on the left (red-tinted)
	diff_insert_background:  sdl3.FColor, // line only on the right (green-tinted)
	diff_gap_background:     sdl3.FColor, // gap on this side aligning the other pane
	diff_change_background:  sdl3.FColor, // line content differs but line exists on both sides
	diff_change_inline_highlight: sdl3.FColor, // alpha-blended overlay on the differing bytes only

	// File-browser git status tints
	git_modified_foreground:  sdl3.FColor,
	git_added_foreground:     sdl3.FColor,
	git_untracked_foreground: sdl3.FColor,
	git_renamed_foreground:   sdl3.FColor,
	git_deleted_foreground:   sdl3.FColor,

	// Syntax-highlighting palette (used by render when a pane has a language)
	syntax_keyword_foreground:      sdl3.FColor,
	syntax_type_foreground:         sdl3.FColor,
	syntax_string_foreground:       sdl3.FColor,
	syntax_number_foreground:       sdl3.FColor,
	syntax_comment_foreground:      sdl3.FColor,
	syntax_preprocessor_foreground: sdl3.FColor,
	syntax_symbol_foreground:       sdl3.FColor,

	// Symbol-jump (F6) dialog state
	// F6 symbol picker. State + render live in the `symbols`
	// subpackage; the symbol data itself lives on the source pane.
	symbols_dialog: symbols_pkg.State,

	// All open terminal sessions. F9 toggles visibility of the active
	// entry (and creates the first one when the list is empty); Ctrl+F9
	// always creates a fresh session; Ctrl+Shift+F9 opens a picker over
	// `terminals` so the user can switch between them. Ctrl+F4 in a
	// terminal pane destroys the active entry — when the last one goes
	// away the terminal slot collapses back to whatever was in pane[1]
	// before the first show. Whether a terminal is currently visible is
	// derived from `editor.panes[1].content` (see `editor_is_terminal_visible`),
	// so we don't carry a separate boolean that could go out of sync.
	terminals:                   [dynamic]TerminalEntry,
	active_terminal_index:       int,  // index into `terminals`; 0 when the list is empty
	next_terminal_display_number: int, // monotonically incremented; assigned at create-time

	// Ctrl+Shift+F9 picker. Lists open terminal sessions so the user can
	// jump between them.
	// Ctrl+Shift+F9 picker. State + render + dispatch live in the
	// `terminal_picker` subpackage; the host trampolines below bridge
	// the picker's callbacks to editor state.
	terminal_picker:       terminal_picker_pkg.State,
	terminal_picker_hooks: terminal_picker_pkg.Hooks,

	// Find mode (Ctrl+F). Attached to a single pane at a time; closes on
	// click outside the bar, on Esc, or on pane switch.
	find:                       FindState,
	find_match_background:      sdl3.FColor, // all matches
	find_match_active_background: sdl3.FColor, // currently selected match

	// Find-and-replace mode (Ctrl+R). Lives at the same bottom-of-pane spot
	// as Find; opening one closes the other. Live preview is rolled back on
	// Esc and coalesced into one Compound undo entry on Enter.
	replace:                    ReplaceState,

	// Find-in-files dialog (Ctrl+Shift+F). Modal: takes over input while
	// Ctrl+Shift+F recursive grep. State + render in the
	// `find_in_files` subpackage; visibility flag is inside the State.
	find_in_files: find_in_files_pkg.State,

	// Replace-in-files dialog (Ctrl+Shift+R). Modal companion to the find
	// dialog — does destructive on-disk writes when the user commits.
	replace_in_files:           replace_in_files_pkg.State,

	// Save-As path-input modal. Opens directly via Ctrl+Shift+S, indirectly
	// via Ctrl+S on an untitled doc, and from the Yes branch of the close
	// confirmation when the file has no path yet.
	// Save-As text-input modal. State + render + dispatch in the
	// `save_as` subpackage; host trampolines below.
	save_as_dialog: save_as_pkg.State,
	save_as_hooks:  save_as_pkg.Hooks,

	// Yes/No/Cancel prompt fired by Ctrl+F4 on a dirty document.
	// "Unsaved changes — save before closing?" prompt. State + render +
	// dispatch in the `close_confirm` subpackage; host trampolines below.
	close_confirm_dialog: close_confirm_pkg.State,

	// F3 git history modal. Subpackage owns everything: dialog state,
	// git CLI invocations, opposite-pane open via EditorAPI.
	git_history_dialog: git_history_pkg.State,

	// Open-documents picker (F4). Lists every EditorPane that's open but
	// not currently displayed — selecting one swaps it into the active
	// pane (stashing whatever was there first via the same mechanism).
	// F4 open-documents picker. State + render + dispatch live in
	// the `open_docs` subpackage; the host trampolines bridge the
	// picker's callbacks to editor state.
	open_docs_dialog: open_docs_pkg.State,
	open_docs_hooks:  open_docs_pkg.Hooks,

	// Documents that are open but not currently displayed in any pane.
	// Populated whenever an EditorPane is replaced via
	// `editor_open_string_in_pane` (the "switch" path); drained when the
	// user picks one back via F4 or opens the same file from the browser.
	// EditorPane values are stored by value — the slot owns its document,
	// file_path, display_title_override, symbols, and symbol_names.
	background_documents:       [dynamic]EditorPane,

	// Fonts loaded lazily for the markdown preview pane. Proportional (Arial-
	// like) for body / headings; monospace for inline code and code blocks.
	// Loaded on the first F5 press, freed in `editor_destroy`.
	markdown_fonts:             markdown.Fonts,

	// Top-of-window menu bar. Always visible; clicking a title opens the
	// dropdown, clicking outside or pressing Esc closes it. While a menu is
	// open, `menu_bar.open_menu_index >= 0` — this also counts as a modal
	// for the purpose of `editor_is_modal_open` so global hotkeys are
	// suppressed.
	menu_bar:                    menu_pkg.State,

	// Set by the File > Quit menu entry. main.odin polls this each frame
	// and exits the main loop when it flips true. Mirrors the existing
	// Ctrl+Q-in-main-loop path without needing the menu to reach into SDL.
	quit_requested:              bool,

	// User config loaded from settings.json at init. Currently holds the
	// per-language LSP command lookup; expected to grow.
	settings:                    EditorSettings,

	// Running LSP clients, keyed by lowercase language id ("odin"). Lazily
	// spawned the first time a file with that language is opened; torn
	// down on editor_destroy. Pointers are owned by this map.
	lsp_clients:                 map[string]^lsp.Client,

	// Hover popup state. Set by Ctrl+K → editor sends the LSP hover
	// request → next frame's poll surfaces a result → we copy it here for
	// rendering. Cleared on Esc / next keystroke / cursor move.
	hover_popup: hover_pkg.State,

	// Completion popup state — see `completion.odin` for the lifecycle.
	completion_popup: completion_popup_pkg.State,

	// Signature-help popup — fires on `(`, refreshes on `,` while inside
	// the same argument list, auto-closes on `)` / Esc / cursor row change.
	signature_popup: signature_popup_pkg.State,

	// Project root, set by Ctrl+P in the file browser. Owned absolute path;
	// "" when unset. When set:
	//   - The F2 browser defaults to it on next open if the cached cwd has
	//     wandered outside the root.
	//   - The F9 terminal spawns with it as the working directory.
	//   - The status bar shows it at all times.
	project_root:               string,

	// Right-side debug panel (F7). Owns the breakpoint list and the DAP
	// session snapshot. See debug.odin and dap_integration.odin.
	debug_state:                debug_pkg.State,
	debug_hooks:                debug_pkg.Hooks,
	breakpoint_color:           sdl3.FColor,
	breakpoint_disabled_color:  sdl3.FColor,
	debug_current_line_color:   sdl3.FColor, // background tint on the line where execution is paused

	// Running DAP adapter processes, keyed by adapter id ("lldb", ...).
	// `active_dap_client` aliases whichever entry is the one a session is
	// running against (or `nil` when no session is active). Owned by this
	// map; pointers freed in `editor_destroy`.
	dap_clients:                map[string]^dap.Client,
	active_dap_client:          ^dap.Client,

	// Per-project build + debug profiles (loaded from
	// `<project_root>/.odit/project.json`). Reloaded any time the project
	// root changes — empty when there's no project root or no file.
	project_config:              ProjectConfig,

	// F7 tasks dialog. Build profiles run inside a fresh terminal session
	// (see `editor_terminal_create_for_build`); the terminal entry is
	// tagged as a build job so the per-frame poll knows to watch its child
	// process and chain a queued debug launch when a build-then-debug
	// pairing completes successfully.
	// F7 Tasks modal — build / debug profile picker. State + render
	// in the `tasks_dialog` subpackage.
	tasks_dialog: tasks_dialog_pkg.State,

	// Selected index into `project_config.debug_profiles`. -1 means "no
	// selection yet" — the Tasks dialog (F7) seeds it on activation.
	active_debug_configuration_index: int,

	// Shift+click-in-gutter conditional-breakpoint editor. State +
	// render + dispatch all live in the `breakpoint_condition`
	// subpackage; we register a `Host` callback set at editor_init so
	// the subpackage can fire breakpoint mutations against editor
	// state without importing the editor package.
	breakpoint_condition_dialog: breakpoint_condition_pkg.State,
	breakpoint_condition_hooks:  breakpoint_condition_pkg.Hooks,

	// Shared scrolling log for the debug-output pane. Owned line strings;
	// trimmed at DEBUG_OUTPUT_MAX_LINES. The OutputPane in pane[1] reads
	// from this buffer, so opening / closing the pane never loses history.
	debug_output_lines:          [dynamic]string,
}

CURSOR_BLINK_RATE :: 0.53 // seconds
SCROLL_SMOOTHNESS :: 18.0 // higher = snappier; lower = floatier

// Hard upper bound for a single document load. Anything beyond this is treated
// as a corrupt input rather than being passed to the piece tree.
EDITOR_MAX_DOCUMENT_BYTES :: 1024 * 1024 * 1024 // 1 GiB

editor_init :: proc(editor: ^Editor, text_engine: ^ttf.TextEngine, font: ^ttf.Font, font_size: f32) {
	// Both panes start as empty, untitled editor panes — the user lands on
	// a blank document they can immediately type into, no welcome text, no
	// pre-loaded buffer. `editor_open_string_in_pane` later swaps these
	// out (or stashes them into `background_documents`) when a real file
	// is opened.
	for pane_index in 0..<len(editor.panes) {
		editor_pane: EditorPane
		document.document_init(&editor_pane.document, "")
		editor.panes[pane_index].content = editor_pane
	}
	editor.active_pane_index = 0
	editor.split_active = false
	editor.split_ratio  = 0.5 // default 50/50 when the split is opened

	// Load shortcut bindings from the platform-appropriate embedded JSON.
	// Failure means the embedded defaults are malformed (only happens
	// during dev when editing the JSON) — fail loud rather than silently
	// running with an empty table.
	if !keybindings.bindings_load_defaults(&editor.keybindings) {
		// Empty table is the only safe fallback — every shortcut will resolve
		// to `.None`, callers will fall through to default key handling.
		editor.keybindings.entries = make([dynamic]keybindings.Binding)
	}

	// Cache the two cursors we ever swap between. `EW_RESIZE` is the
	// closest system cursor to a "grab the column divider" indicator; SDL3
	// doesn't expose a dedicated grab/grabbing shape, and on Windows it
	// renders as the familiar double-headed left/right arrow.
	editor.cursor_default   = sdl3.CreateSystemCursor(.DEFAULT)
	editor.cursor_resize_ew = sdl3.CreateSystemCursor(.EW_RESIZE)
	editor.cursor_resize_ns = sdl3.CreateSystemCursor(.NS_RESIZE)
	editor.current_cursor   = editor.cursor_default
	if editor.cursor_default != nil { _ = sdl3.SetCursor(editor.cursor_default) }

	ui.text_cache_init(&editor.text_cache, text_engine, font, 1024)

	// Force an initial render so the first frame paints, then keep the
	// flag accurate via the various setters below.
	editor.needs_redraw = true

	editor.font = font
	editor.text_engine = text_engine
	editor.font_size = font_size
	editor.cursor_visible = true
	editor.cursor_timer = 0

	editor.padding_x = 8
	editor.padding_y = 4

	menu_pkg.init(&editor.menu_bar)
	append(&editor.bindings, menu_pkg.make_binding(&editor.menu_bar))
	editor_settings_init(&editor.settings)

	// Measure monospace character dimensions
	editor.line_height = i32(ttf.GetFontLineSkip(font))
	measured_width: i32
	ttf.GetStringSize(font, "M", 1, &measured_width, nil)
	editor.character_width = measured_width

	// Terminal dark theme
	editor.background_color       = sdl3.FColor{0.11, 0.11, 0.14, 1.0}
	editor.foreground_color       = sdl3.FColor{0.85, 0.85, 0.85, 1.0}
	editor.cursor_color           = sdl3.FColor{0.9, 0.9, 0.9, 1.0}
	editor.line_number_color      = sdl3.FColor{0.4, 0.45, 0.5, 1.0}
	editor.selection_color        = sdl3.FColor{0.22, 0.36, 0.60, 1.0}
	editor.status_bar_background  = sdl3.FColor{0.18, 0.20, 0.25, 1.0}
	editor.status_bar_foreground  = sdl3.FColor{0.7, 0.75, 0.8, 1.0}
	editor.divider_color          = sdl3.FColor{0.30, 0.34, 0.42, 1.0}
	editor.diff_delete_background = sdl3.FColor{0.28, 0.10, 0.12, 1.0}
	editor.diff_insert_background = sdl3.FColor{0.10, 0.28, 0.14, 1.0}
	editor.diff_gap_background    = sdl3.FColor{0.07, 0.08, 0.11, 1.0}
	editor.diff_change_background        = sdl3.FColor{0.24, 0.20, 0.08, 1.0}  // dim amber tint over the whole row
	editor.diff_change_inline_highlight  = sdl3.FColor{0.78, 0.60, 0.18, 0.55} // brighter amber on the differing bytes

	editor.git_modified_foreground  = sdl3.FColor{0.95, 0.78, 0.42, 1.0} // amber
	editor.git_added_foreground     = sdl3.FColor{0.45, 0.85, 0.50, 1.0} // green
	editor.git_untracked_foreground = sdl3.FColor{0.50, 0.78, 0.95, 1.0} // light blue
	editor.git_renamed_foreground   = sdl3.FColor{0.78, 0.62, 0.95, 1.0} // purple
	editor.git_deleted_foreground   = sdl3.FColor{0.92, 0.45, 0.45, 1.0} // red

	editor.find_match_background          = sdl3.FColor{0.55, 0.50, 0.15, 0.55} // muted yellow
	editor.find_match_active_background   = sdl3.FColor{0.95, 0.78, 0.20, 0.85} // bright amber

	editor.syntax_keyword_foreground      = sdl3.FColor{0.55, 0.70, 0.95, 1.0} // soft blue
	editor.syntax_type_foreground         = sdl3.FColor{0.48, 0.82, 0.85, 1.0} // teal
	editor.syntax_string_foreground       = sdl3.FColor{0.65, 0.85, 0.55, 1.0} // soft green
	editor.syntax_number_foreground       = sdl3.FColor{0.92, 0.70, 0.45, 1.0} // orange
	editor.syntax_comment_foreground      = sdl3.FColor{0.45, 0.50, 0.58, 1.0} // dim grey
	editor.syntax_preprocessor_foreground = sdl3.FColor{0.88, 0.55, 0.78, 1.0} // magenta
	editor.syntax_symbol_foreground       = sdl3.FColor{0.95, 0.90, 0.55, 1.0} // pale yellow

	editor.breakpoint_color           = sdl3.FColor{0.92, 0.35, 0.35, 1.0} // saturated red
	editor.breakpoint_disabled_color  = sdl3.FColor{0.55, 0.40, 0.40, 1.0} // muted red
	editor.debug_current_line_color   = sdl3.FColor{0.28, 0.22, 0.12, 1.0} // dim amber

	debug_pkg.init(&editor.debug_state)
	editor.debug_hooks = debug_pkg.Hooks{
		user_data       = editor,
		menu_bar_height = debug_hooks_menu_bar_height,
	}
	append(&editor.bindings, debug_pkg.make_binding(&editor.debug_state, editor.debug_hooks))
	editor.dap_clients = make(map[string]^dap.Client)

	// Wire the breakpoint-condition modal's host callbacks. The modal
	// uses these to read + mutate the editor's breakpoint table
	// without taking a build-time dependency on the editor package.
	editor.breakpoint_condition_hooks = breakpoint_condition_pkg.Hooks{
		user_data             = editor,
		existing_condition_at = breakpoint_condition_host_existing,
		set_condition_at      = breakpoint_condition_host_set,
	}
	append(&editor.bindings, breakpoint_condition_pkg.make_binding(&editor.breakpoint_condition_dialog, editor.breakpoint_condition_hooks))

	editor.terminal_picker_hooks = terminal_picker_pkg.Hooks{
		user_data         = editor,
		list_entries      = terminal_picker_host_list_entries,
		initial_selection = terminal_picker_host_initial_selection,
		activate          = terminal_picker_host_activate,
	}
	append(&editor.bindings, terminal_picker_pkg.make_binding(&editor.terminal_picker, editor.terminal_picker_hooks))

	append(&editor.bindings, tasks_dialog_pkg.make_binding(&editor.tasks_dialog))

	append(&editor.bindings, hover_pkg.make_binding(&editor.hover_popup))

	append(&editor.bindings, signature_popup_pkg.make_binding(&editor.signature_popup))

	append(&editor.bindings, completion_popup_pkg.make_binding(&editor.completion_popup))

	append(&editor.bindings, git_history_pkg.make_binding(&editor.git_history_dialog))

	append(&editor.bindings, find_in_files_pkg.make_binding(&editor.find_in_files))
	append(&editor.bindings, replace_in_files_pkg.make_binding(&editor.replace_in_files))

	editor.open_docs_hooks = open_docs_pkg.Hooks{
		user_data    = editor,
		list_entries = open_docs_host_list_entries,
		activate     = open_docs_host_activate,
	}
	append(&editor.bindings, open_docs_pkg.make_binding(&editor.open_docs_dialog, editor.open_docs_hooks))

	append(&editor.bindings, close_confirm_pkg.make_binding(&editor.close_confirm_dialog, close_confirm_pkg.Hooks{
		user_data         = editor,
		subject_name      = close_confirm_host_subject_name,
		save_and_close    = close_confirm_host_save_and_close,
		discard_and_close = close_confirm_host_discard_and_close,
	}))

	editor.save_as_hooks = save_as_pkg.Hooks{
		user_data    = editor,
		default_path = save_as_host_default_path,
		commit       = save_as_host_commit,
	}
	append(&editor.bindings, save_as_pkg.make_binding(&editor.save_as_dialog, editor.save_as_hooks))

	editor.editor_api = binding_pkg.EditorAPI{
		editor                    = editor,
		find_open_document        = editor_api_find_open_document,
		open_string_in_pane       = editor_api_open_string_in_pane,
		swap_background_into_pane = editor_api_swap_background_into_pane,
		active_pane_index         = editor_api_active_pane_index,
		set_active_pane_index     = editor_api_set_active_pane_index,
		set_split_active          = editor_api_set_split_active,
		project_root              = editor_api_project_root,
		set_project_root          = editor_api_set_project_root,
		path_inside_project_root  = editor_api_path_inside_project_root,
		line_height               = editor_api_line_height,
		character_width           = editor_api_character_width,

		open_file_at_path            = editor_api_open_file_at_path,
		jump_active_pane_to          = editor_api_jump_active_pane_to,
		active_pane_file_path        = editor_api_active_pane_file_path,
		active_pane_short_selection  = editor_api_active_pane_short_selection,
		open_string_in_opposite_pane = editor_api_open_string_in_opposite_pane,

		project_loaded_path  = editor_api_project_loaded_path,
		list_build_profiles  = editor_api_list_build_profiles,
		list_debug_profiles  = editor_api_list_debug_profiles,
		run_build_profile    = editor_api_run_build_profile,
		start_debug_profile  = editor_api_start_debug_profile,

		active_dap_client          = editor_api_active_dap_client,
		dap_action                 = editor_api_dap_action,
		dap_flush_file_breakpoints = editor_api_dap_flush_file_breakpoints,

		dispatch_menu_action       = editor_api_dispatch_menu_action,

		lsp_request_hover            = editor_api_lsp_request_hover,
		lsp_poll_hover               = editor_api_lsp_poll_hover,
		lsp_request_signature_help   = editor_api_lsp_request_signature_help,
		lsp_poll_signature_help      = editor_api_lsp_poll_signature_help,
		lsp_request_completion       = editor_api_lsp_request_completion,
		lsp_poll_completion          = editor_api_lsp_poll_completion,
		apply_completion_at_cursor   = editor_api_apply_completion_at_cursor,
		markdown_context             = editor_api_markdown_context,
		active_pane_cursor           = editor_api_active_pane_cursor,
		pane_anchor                  = editor_api_pane_anchor,
		theme                        = editor_api_theme,
	}

	// Order in `bindings` defines event-dispatch priority: the first
	// visible binding consumes the event.
	append(&editor.bindings, help_pkg.make_binding(&editor.help))
	append(&editor.bindings, browse_pkg.make_binding(&editor.browse_view, &editor.keybindings))

	append(&editor.bindings, symbols_pkg.make_binding(&editor.symbols_dialog, symbols_pkg.Hooks{
		user_data      = editor,
		source_symbols = symbols_host_source_symbols,
		dialog_title   = symbols_host_dialog_title,
		apply_activate = symbols_host_apply_activate,
	}))
	// Sentinel — start_session asks the user to pick via F7 the first time
	// when more than one debug profile is loaded.
	editor.active_debug_configuration_index = -1

	project_config_init(&editor.project_config)

	syntax.init()

	// Restore the last-used project root (if any) so reopening the editor
	// drops the user straight back into the project they were working in.
	editor_persistence_load(editor)

	// macOS: install the native NSMenu at the top of the screen, fed from
	// the same `MENUS` table the in-app strip uses on Windows/Linux. The
	// in-app strip is force-hidden on Darwin, so this is the only menu.
	when ODIN_OS == .Darwin { editor_install_native_menu(editor) }
}

// Toggle diff mode. Requires both panes to be open and contain
// editor content; otherwise it's a no-op. Diff state is freed on
// exit so memory doesn't linger. The algorithm + state container
// live in the `diff` subpackage.
@(private)
diff_toggle :: proc(editor: ^Editor) {
	if editor.diff_state.active {
		diff_pkg.destroy(&editor.diff_state)
		return
	}

	if !editor.split_active { return }
	left_pane  := pane_as_editor(&editor.panes[0])
	right_pane := pane_as_editor(&editor.panes[1])
	if left_pane == nil || right_pane == nil { return }

	if !diff_pkg.compute(&editor.diff_state, &left_pane.document, &right_pane.document) { return }
	editor.diff_state.active = true

	editor.diff_state.scroll_y = 0
	editor.diff_state.scroll_y_target = 0

	left_pane.selection_active  = false
	right_pane.selection_active = false
}

// --- menu subpackage integration ---------------------------------------

// Pixel height of the menu strip when visible. Returns 0 when the
// bar is hidden so panes get the full window height.
@(private)
editor_menu_bar_height :: proc(editor: ^Editor) -> i32 {
	return menu_pkg.bar_layout_height(&editor.menu_bar, editor.line_height)
}

// API trampoline: menu binding emits an action (u32) which the
// editor maps to a real menu_pkg.ActionKind and dispatches.
@(private)
editor_api_dispatch_menu_action :: proc(editor_ptr: rawptr, action: u32) {
	editor := cast(^Editor)editor_ptr
	menu_execute_action(editor, menu_pkg.ActionKind(action))
}

// Dispatch table for every menu action — the single sink that
// every menu surface (in-app strip, macOS NSMenu) routes through.
@(private)
menu_execute_action :: proc(editor: ^Editor, action: menu_pkg.ActionKind) {
	if action == .None { return }
	// Forces the bar to hide on the next visibility check, even if
	// Alt is still held — matches the platform-standard "menu
	// disappears after selection".
	editor.menu_bar.alt_press_consumed = true
	switch action {
	case .None: return

	case .FileOpen:            browse_pkg.open(&editor.browse_view, &editor.editor_api)
	case .FileSave:            editor_save_active_file(editor)
	case .FileSaveAs:          editor_save_as_active_file(editor)
	case .FileSwitchDocument:  if editor_active_editor_pane(editor) != nil { open_docs_pkg.open_with_hooks(&editor.open_docs_dialog, editor.open_docs_hooks, editor.active_pane_index) }
	case .FileClose:           editor_close_active_file(editor)
	case .FileQuit:            editor.quit_requested = true

	case .EditUndo:            editor_undo_active(editor)
	case .EditRedo:            editor_redo_active(editor)
	case .EditCopy:            menu_copy_in_active_pane(editor)
	case .EditPaste:           menu_paste_in_active_pane(editor)
	case .EditFind:            menu_toggle_find(editor)
	case .EditReplace:         menu_toggle_replace(editor)
	case .EditFindInFiles:     find_in_files_pkg.open_via_api(&editor.find_in_files, &editor.editor_api)
	case .EditReplaceInFiles:  replace_in_files_pkg.open_via_api(&editor.replace_in_files, &editor.editor_api)
	case .EditCompletion:      completion_popup_pkg.trigger_at_cursor_via_api(&editor.completion_popup, &editor.editor_api)

	case .ViewToggleWrap:      editor_toggle_wrap(editor)
	case .ViewToggleDiff:      diff_toggle(editor)
	case .ViewMarkdownPreview: markdown_preview_open(editor)
	case .ViewSwapPanes:       editor_focus_other_pane(editor)
	case .ViewFocusLeftPane:   editor_focus_pane(editor, 0)
	case .ViewFocusRightPane:  editor_focus_pane(editor, 1)
	case .ViewMoveToLeftPane:  editor_move_active_to_pane(editor, 0)
	case .ViewMoveToRightPane: editor_move_active_to_pane(editor, 1)

	case .NavSymbolJump:       symbols_open(editor)
	case .NavGitHistory:       git_history_pkg.open_via_api(&editor.git_history_dialog, &editor.editor_api)
	case .NavLspHover:         hover_pkg.request_at_cursor_via_api(&editor.hover_popup, &editor.editor_api)

	case .TerminalShowHide:    editor_toggle_terminal(editor)
	case .TerminalNew:         editor_terminal_create_new(editor)
	case .TerminalSwitch:      terminal_picker_pkg.open_with_hooks(&editor.terminal_picker, editor.terminal_picker_hooks)
	case .TerminalCloseActive: editor_terminal_destroy_active(editor)

	case .DebugTasks:          tasks_dialog_pkg.open_via_api(&editor.tasks_dialog, &editor.editor_api)
	case .DebugTogglePanel:    debug_panel_toggle(editor)
	case .DebugContinue:       dap.client_continue(editor.active_dap_client)
	case .DebugStop:           editor_dap_stop_session(editor)
	case .DebugStepOver:       dap.client_step_over(editor.active_dap_client)
	case .DebugStepInto:       dap.client_step_in(editor.active_dap_client)
	case .DebugStepOut:        dap.client_step_out(editor.active_dap_client)

	case .HelpToggle:          if help_pkg.toggle(&editor.help) { editor_mark_dirty(editor) }
	}
	editor_mark_dirty(editor)
}

@(private="file")
menu_toggle_find :: proc(editor: ^Editor) {
	if find_active(editor) { find_close(editor) } else { find_open(editor) }
}

@(private="file")
menu_toggle_replace :: proc(editor: ^Editor) {
	if replace_active(editor) { replace_close(editor, false) } else { replace_open(editor) }
}

@(private="file")
menu_copy_in_active_pane :: proc(editor: ^Editor) {
	#partial switch &content_value in editor_active_pane(editor).content {
	case TerminalPane:
		if content_value.terminal != nil { terminal.terminal_copy_selection_to_clipboard(content_value.terminal) }
	case EditorPane:
		clipboard_copy(editor)
	}
}

@(private="file")
menu_paste_in_active_pane :: proc(editor: ^Editor) {
	#partial switch &content_value in editor_active_pane(editor).content {
	case TerminalPane:
		if content_value.terminal != nil { terminal.terminal_paste_from_clipboard(content_value.terminal) }
	case EditorPane:
		if !editor.diff_state.active { clipboard_paste(editor) }
	}
}

// --- debug subpackage hooks + host trampolines --------------------------

@(private)
debug_hooks_menu_bar_height :: proc(user_data: rawptr) -> i32 {
	editor := cast(^Editor)user_data
	return editor_menu_bar_height(editor)
}

// Toggle the *debug UI as a whole*: the right-side debug panel AND
// the Debug Output pane in pane[1] are conceptually one feature, so
// Shift+F7 raises/lowers them together.
@(private)
debug_panel_toggle :: proc(editor: ^Editor) {
	any_visible := editor.debug_state.panel_visible || editor_is_output_pane_visible(editor)
	if any_visible {
		editor.debug_state.panel_visible = false
		editor_output_pane_hide(editor)
	} else {
		editor.debug_state.panel_visible = true
		editor_output_pane_show(editor)
	}
	editor_mark_dirty(editor)
}

// Width the debug panel currently claims on the right side of the
// window. Returns 0 when the panel is hidden — call sites can
// subtract this directly from `window_width`.
@(private)
debug_panel_width :: proc(editor: ^Editor) -> i32 {
	return debug_pkg.width(&editor.debug_state)
}

// Breakpoint condition modal trampolines — call into the debug
// subpackage's storage.
@(private)
breakpoint_condition_host_existing :: proc(user_data: rawptr, file_path: string, line: u32) -> (existing: string, had_bp: bool) {
	editor := cast(^Editor)user_data
	return debug_pkg.condition_at(&editor.debug_state, file_path, line)
}

@(private)
breakpoint_condition_host_set :: proc(user_data: rawptr, file_path: string, line: u32, condition_text: string) {
	editor := cast(^Editor)user_data
	debug_pkg.set_condition_at(&editor.debug_state, &editor.editor_api, file_path, line, condition_text)
	editor_mark_dirty(editor)
}

// Hit-test the editor pane's gutter and either toggle a breakpoint
// at the line under the click, or — when shift is held — open the
// condition editor for that line. Diff mode and untitled buffers
// don't get gutter breakpoints — they have nowhere to anchor to.
@(private)
editor_pane_gutter_toggle_breakpoint :: proc(editor: ^Editor, pane: ^Pane, editor_pane: ^EditorPane, mouse_x, mouse_y: f32, shift_held: bool) -> bool {
	if editor.diff_state.active           { return false }
	if len(editor_pane.file_path) == 0    { return false }

	title_bar_height := f32(editor_title_bar_height(editor))
	gutter_x_start := f32(pane.rectangle.x + editor.padding_x)
	gutter_x_end   := f32(pane.rectangle.x + editor.padding_x + editor_pane.gutter_width)
	if mouse_x < gutter_x_start || mouse_x >= gutter_x_end { return false }
	if mouse_y < f32(pane.rectangle.y) + title_bar_height  { return false }

	document_y := mouse_y - f32(pane.rectangle.y) - title_bar_height - f32(editor.padding_y) + editor_pane.scroll_y
	if document_y < 0                 { return false }
	if editor.line_height <= 0        { return false }

	clicked_line := u32(document_y / f32(editor.line_height))
	total_line_count := document.document_line_count(&editor_pane.document)
	if clicked_line >= total_line_count { return false }

	if shift_held {
		breakpoint_condition_pkg.open_with_hooks(&editor.breakpoint_condition_dialog, editor.breakpoint_condition_hooks, editor_pane.file_path, clicked_line)
	} else {
		debug_pkg.toggle_at(&editor.debug_state, &editor.editor_api, editor_pane.file_path, clicked_line)
		editor_mark_dirty(editor)
	}
	return true
}

editor_destroy :: proc(editor: ^Editor) {
	for pane_index in 0..<len(editor.panes) {
		pane_destroy(&editor.panes[pane_index])
	}
	for &registered_binding in editor.bindings {
		if registered_binding.destroy != nil {
			registered_binding.destroy(registered_binding.state)
		}
	}
	delete(editor.bindings)
	diff_pkg.destroy(&editor.diff_state)
	symbols_pkg.destroy(&editor.symbols_dialog)
	find_state_destroy(&editor.find)
	replace_state_destroy(&editor.replace)
	project_config_destroy(&editor.project_config)
	editor_lsp_destroy_all(editor)
	editor_settings_destroy(&editor.settings)
	for background_index in 0..<len(editor.background_documents) {
		editor_pane_destroy_in_place(&editor.background_documents[background_index])
	}
	if cap(editor.background_documents) > 0 { delete(editor.background_documents) }

	// Tear down every open terminal session. The pane teardown above only
	// cleared borrowed pointers — actual ownership lives here. After my
	// pane_content_destroy change the TerminalPane case is a no-op on the
	// terminal pointer, so this loop is the *only* call to terminal_destroy
	// and double-free is structurally impossible.
	for &entry in editor.terminals {
		if entry.terminal != nil {
			terminal.terminal_destroy(entry.terminal)
			entry.terminal = nil
		}
		if len(entry.build_profile_name) > 0 {
			delete(entry.build_profile_name)
			entry.build_profile_name = ""
		}
	}
	if cap(editor.terminals) > 0 { delete(editor.terminals) }
	markdown.fonts_destroy(&editor.markdown_fonts)
	editor_dap_destroy_all(editor)
	debug_output_destroy(editor)
	if len(editor.project_root) > 0 {
		delete(editor.project_root)
		editor.project_root = ""
	}
	syntax.destroy()
	if editor.cursor_default   != nil { sdl3.DestroyCursor(editor.cursor_default)   }
	if editor.cursor_resize_ew != nil { sdl3.DestroyCursor(editor.cursor_resize_ew) }
	if editor.cursor_resize_ns != nil { sdl3.DestroyCursor(editor.cursor_resize_ns) }
	ui.text_cache_destroy(&editor.text_cache)
	keybindings.bindings_destroy(&editor.keybindings)
}

// Build a `ui.Context` populated with the editor's font metrics + the last
// known mouse position. Every place that used to construct the same struct
// literal inline now goes through this helper so the mouse fields are
// always present (otherwise hover-aware widgets would silently no-op).
@(private)
editor_make_ui_context :: proc(editor: ^Editor, renderer: ^sdl3.Renderer) -> ui.Context {
	return ui.Context{
		renderer        = renderer,
		font            = editor.font,
		engine          = editor.text_engine,
		character_width = editor.character_width,
		line_height     = editor.line_height,
		mouse_x         = editor.last_mouse_x,
		mouse_y         = editor.last_mouse_y,
	}
}

// Mark the editor as needing a fresh render. Cheap; safe to call from any
// path that mutates visible state. Setters that flip user-visible bits
// (key/text/mouse events, cursor blink, scroll animation, terminal output)
// all funnel through here so the main loop can skip render+present on
// frames where nothing has actually changed.
editor_mark_dirty :: proc(editor: ^Editor) {
	editor.needs_redraw = true
}

// Drop the dirty flag — called by the main loop right after `editor_render`.
editor_mark_clean :: proc(editor: ^Editor) {
	editor.needs_redraw = false
}

// Tally one rendered frame for the status-bar FPS readout. Called by the
// main loop right after `sdl3.RenderPresent` with the seconds elapsed since
// the previous render-or-skip tick. Aggregated over a ~0.5s window so the
// displayed number doesn't flicker on every frame, and re-marks dirty when
// the value changes so the next paint reflects the new reading.
//
// `delta_time` is the same per-loop-iteration delta the main loop already
// computes; what makes this useful (vs. just counting iterations in
// `editor_update`) is that we only get called on frames that actually
// painted, so the rate drops when the render path stalls instead of being
// pinned at 60 by main.odin's sleep.
editor_record_frame_presented :: proc(editor: ^Editor, delta_time: f64) {
	editor.fps_window_seconds += delta_time
	editor.fps_window_frames  += 1
	if editor.fps_window_seconds >= 0.5 {
		new_fps := i32(f64(editor.fps_window_frames) / editor.fps_window_seconds + 0.5)
		if new_fps != editor.fps_last_value {
			editor.fps_last_value = new_fps
			when ODIN_DEBUG { editor_mark_dirty(editor) }
		}
		editor.fps_window_seconds = 0
		editor.fps_window_frames  = 0
	}
}

// True when this frame must be drawn. Wraps the flag so the main loop never
// reads internal state directly.
editor_needs_render :: proc(editor: ^Editor) -> bool {
	return editor.needs_redraw
}

// True when a modal dialog (help, browse, future popups) currently owns input.
editor_is_modal_open :: proc(editor: ^Editor) -> bool {
	return editor.help.visible || editor.browse_view.visible || editor.symbols_dialog.visible || editor.find_in_files.visible || editor.replace_in_files.visible || editor.save_as_dialog.visible || editor.close_confirm_dialog.visible || editor.git_history_dialog.visible || editor.open_docs_dialog.visible || editor.terminal_picker.visible || editor.tasks_dialog.visible || editor.breakpoint_condition_dialog.visible || editor.menu_bar.open_menu_index >= 0
}

