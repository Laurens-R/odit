package editor

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "vendor:sdl3"
import "vendor:sdl3/ttf"

import "../dap"
import "../document"
import binding_pkg "./binding"
import breakpoint_condition_pkg "./breakpoint_condition"
import browse_pkg "./browse"
import close_confirm_pkg "./close_confirm"
import completion_popup_pkg "./completion_popup"
import find_in_files_pkg "./find_in_files"
import git_history_pkg "./git_history"
import help_pkg "./help"
import hover_pkg "./hover"
import open_docs_pkg "./open_docs"
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
// The pointer here aliases the active entry in `Editor.terminals` — the
// editor owns the terminal lifetime; the pane just holds a borrowed
// pointer for rendering/input dispatch.
TerminalPane :: struct {
	terminal:  ^terminal.Terminal,
	scrollbar: ui.Scrollbar,
}

// One entry in the editor's multi-terminal list. `display_number` is a
// stable monotonically-assigned 1-based label used in the title strip and
// the picker — when a terminal is destroyed, the others keep their numbers
// instead of shifting, so the user's mental map ("Terminal 3") stays valid.
@(private)
TerminalEntry :: struct {
	terminal:       ^terminal.Terminal,
	display_number: int,
	// Task-runner bookkeeping. `is_build_job=true` marks a one-shot session
	// spawned by the Tasks dialog so the per-frame poll knows to watch its
	// child's exit code (rather than treating it as an interactive shell
	// that lives until the user closes it). When a build-job terminal exits
	// with code 0 *and* `pending_debug_profile_index >= 0`, the editor
	// auto-starts the queued debug session.
	is_build_job:                bool,
	build_profile_name:          string, // owned; "" for interactive shells
	pending_debug_profile_index: int,    // -1 = standalone build
	build_exit_observed:         bool,   // set once exit has been handled — guards against double-firing
}

// Tagged union of all pane content kinds. Add variants here as new pane types
// are introduced.
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
	diff_state:      DiffState,

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
	show_replace_in_files:      bool,
	replace_in_files:           ReplaceInFilesState,

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
	menu_bar:                    MenuBarState,

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
	debug_state:                DebugState,
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

	menu_bar_init(&editor.menu_bar)
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

	debug_state_init(&editor.debug_state)
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

// --- EditorAPI implementations ------------------------------------------
// Every editor primitive exposed to bindings is implemented here as a
// tiny trampoline. The `editor: rawptr` argument is always a `^Editor`.

@(private)
editor_api_find_open_document :: proc(editor_ptr: rawptr, file_path: string) -> (pane_index, background_index: int) {
	editor := cast(^Editor)editor_ptr
	return editor_find_open_document(editor, file_path)
}

@(private)
editor_api_open_string_in_pane :: proc(editor_ptr: rawptr, pane_index: int, content: string, file_path: string) {
	editor := cast(^Editor)editor_ptr
	editor_open_string_in_pane(editor, pane_index, content, file_path)
}

@(private)
editor_api_swap_background_into_pane :: proc(editor_ptr: rawptr, pane_index, background_index: int) {
	editor := cast(^Editor)editor_ptr
	editor_swap_background_into_pane(editor, pane_index, background_index)
}

@(private)
editor_api_active_pane_index :: proc(editor_ptr: rawptr) -> int {
	editor := cast(^Editor)editor_ptr
	return editor.active_pane_index
}

@(private)
editor_api_set_active_pane_index :: proc(editor_ptr: rawptr, pane_index: int) {
	editor := cast(^Editor)editor_ptr
	editor.active_pane_index = pane_index
}

@(private)
editor_api_set_split_active :: proc(editor_ptr: rawptr, value: bool) {
	editor := cast(^Editor)editor_ptr
	editor.split_active = value
}

@(private)
editor_api_project_root :: proc(editor_ptr: rawptr) -> string {
	editor := cast(^Editor)editor_ptr
	return editor.project_root
}

@(private)
editor_api_set_project_root :: proc(editor_ptr: rawptr, path: string) {
	editor := cast(^Editor)editor_ptr
	editor_set_project_root(editor, path)
}

@(private)
editor_api_path_inside_project_root :: proc(editor_ptr: rawptr, path: string) -> bool {
	editor := cast(^Editor)editor_ptr
	return editor_path_inside_project_root(editor, path)
}

@(private)
editor_api_line_height :: proc(editor_ptr: rawptr) -> i32 {
	editor := cast(^Editor)editor_ptr
	return editor.line_height
}

@(private="file")
EDITOR_API_MAX_FILE_BYTES :: 256 * 1024 * 1024 // 256 MiB

@(private)
editor_api_open_file_at_path :: proc(editor_ptr: rawptr, path: string, split_secondary: bool, allocator: runtime.Allocator) -> (error_message: string) {
	editor := cast(^Editor)editor_ptr

	existing_pane_index, existing_background_index := editor_find_open_document(editor, path)
	if existing_pane_index >= 0 {
		editor.active_pane_index = existing_pane_index
		return ""
	}
	if existing_background_index >= 0 {
		target_pane_index := editor.active_pane_index
		if split_secondary {
			editor.split_active = true
			target_pane_index   = 1
			editor.active_pane_index = 1
		}
		editor_swap_background_into_pane(editor, target_pane_index, existing_background_index)
		return ""
	}

	file_data, read_file_error := os.read_entire_file_from_path(path, context.allocator)
	if read_file_error != nil {
		return fmt.aprintf("Cannot open %s: %v", filepath.base(path), read_file_error, allocator = allocator)
	}
	defer delete(file_data)

	if len(file_data) > EDITOR_API_MAX_FILE_BYTES {
		return fmt.aprintf("File %s is too large (%d bytes)", filepath.base(path), len(file_data), allocator = allocator)
	}

	file_content := strings.clone(string(file_data))

	target_pane_index := editor.active_pane_index
	if split_secondary {
		editor.split_active = true
		target_pane_index   = 1
		editor.active_pane_index = 1
	}

	editor_open_string_in_pane(editor, target_pane_index, file_content, path)
	return ""
}

@(private)
editor_api_jump_active_pane_to :: proc(editor_ptr: rawptr, line, column: u32) {
	editor := cast(^Editor)editor_ptr
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return }

	document_line_count := document.document_line_count(&editor_pane.document)
	target_line := line
	if target_line >= document_line_count { target_line = document_line_count - 1 }

	line_start_offset := document.document_line_start(&editor_pane.document, target_line)
	line_text         := document.document_get_line(&editor_pane.document, target_line, context.temp_allocator)
	target_column     := column
	if int(target_column) > len(line_text) { target_column = u32(len(line_text)) }

	editor_pane.cursor_line      = target_line
	editor_pane.cursor_column    = target_column
	editor_pane.cursor_offset    = line_start_offset + target_column
	editor_pane.selection_active = false

	editor.cursor_visible = true
	editor.cursor_timer   = 0

	if editor.diff_state.active || editor.line_height <= 0 {
		sync_cursor_from_offset(editor)
	} else {
		target_scroll_y := f32(target_line) * f32(editor.line_height)
		if target_scroll_y < 0 { target_scroll_y = 0 }
		editor_pane.scroll_y        = target_scroll_y
		editor_pane.scroll_y_target = target_scroll_y
		editor_pane.scroll_line     = target_line
	}
}

@(private)
editor_api_active_pane_file_path :: proc(editor_ptr: rawptr) -> string {
	editor := cast(^Editor)editor_ptr
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return "" }
	return editor_pane.file_path
}

@(private)
editor_api_active_pane_short_selection :: proc(editor_ptr: rawptr, max_bytes: int, allocator: runtime.Allocator) -> (text: string, ok: bool) {
	editor := cast(^Editor)editor_ptr
	editor_pane := editor_active_editor_pane(editor); if editor_pane == nil { return "", false }
	if !editor_pane.selection_active                                          { return "", false }

	low_offset, high_offset, has_selection := editor_pane_selection_range(editor_pane)
	if !has_selection                       { return "", false }
	if int(high_offset - low_offset) > max_bytes { return "", false }

	selection_text := document.document_get_slice(&editor_pane.document, low_offset, high_offset - low_offset, context.temp_allocator)
	for byte_value in transmute([]u8)selection_text {
		if byte_value == '\n' { return "", false }
	}
	return strings.clone(selection_text, allocator), true
}

@(private)
editor_api_open_string_in_opposite_pane :: proc(editor_ptr: rawptr, source_pane_index: int, content: string, file_path_for_syntax: string, display_title_override: string) {
	editor := cast(^Editor)editor_ptr
	opposite_pane_index := 1 - source_pane_index
	if opposite_pane_index < 0 || opposite_pane_index >= len(editor.panes) { return }

	editor.split_active = true
	editor_open_string_in_pane(editor, opposite_pane_index, content, "")
	if opposite_pane := pane_as_editor(&editor.panes[opposite_pane_index]); opposite_pane != nil {
		opposite_pane.language               = syntax.get_definition_for_path(file_path_for_syntax)
		opposite_pane.display_title_override = display_title_override
		pane_rebuild_symbols(opposite_pane)
		opposite_pane.symbols_dirty      = false
		opposite_pane.last_analysis_time = editor.clock
	}
	editor.active_pane_index = opposite_pane_index
}

// --- LSP API primitives -----------------------------------------------

// Resolve the LSP client + editor pane for the active pane. Returns
// ok=false when nothing is wired up (no editor pane, no file path,
// no client for the language, client not initialized, pane hasn't
// sent didOpen yet).
@(private="file")
editor_api_active_lsp :: proc(editor: ^Editor) -> (client: ^lsp.Client, editor_pane: ^EditorPane, ok: bool) {
	editor_pane = editor_active_editor_pane(editor); if editor_pane == nil { return nil, nil, false }
	if len(editor_pane.file_path) == 0 { return nil, nil, false }
	language_id := lsp_language_id_for(editor_pane.language); if len(language_id) == 0 { return nil, nil, false }
	found_client, has_client := editor.lsp_clients[language_id]; if !has_client { return nil, nil, false }
	if !found_client.is_initialized        { return nil, nil, false }
	if !editor_pane.lsp_did_open_sent      { return nil, nil, false }
	return found_client, editor_pane, true
}

@(private)
editor_api_lsp_request_hover :: proc(editor_ptr: rawptr) -> bool {
	editor := cast(^Editor)editor_ptr
	client, editor_pane, ok := editor_api_active_lsp(editor)
	if !ok { return false }
	editor_lsp_flush_pending_change(editor, editor_pane)
	lsp.client_request_hover(client, editor_pane.file_path, i32(editor_pane.cursor_line), i32(editor_pane.cursor_column))
	return true
}

@(private)
editor_api_lsp_poll_hover :: proc(editor_ptr: rawptr, allocator: runtime.Allocator) -> (text: string, ok: bool) {
	editor := cast(^Editor)editor_ptr
	for _, client in editor.lsp_clients {
		if !client.hover.is_valid { continue }
		cloned := strings.clone(client.hover.text, allocator)
		lsp.hover_result_clear(&client.hover)
		return cloned, true
	}
	return "", false
}

@(private)
editor_api_lsp_request_signature_help :: proc(editor_ptr: rawptr) -> bool {
	editor := cast(^Editor)editor_ptr
	client, editor_pane, ok := editor_api_active_lsp(editor)
	if !ok { return false }
	editor_lsp_flush_pending_change(editor, editor_pane)
	lsp.client_request_signature_help(client, editor_pane.file_path, i32(editor_pane.cursor_line), i32(editor_pane.cursor_column))
	return true
}

@(private)
editor_api_lsp_poll_signature_help :: proc(editor_ptr: rawptr, allocator: runtime.Allocator) -> (info: binding_pkg.SignatureInfo, ok: bool) {
	editor := cast(^Editor)editor_ptr
	for _, client in editor.lsp_clients {
		if !client.signature_help.is_valid { continue }

		if len(client.signature_help.signatures) == 0 {
			lsp.signature_help_result_clear(&client.signature_help)
			return binding_pkg.SignatureInfo{ active_start = -1, active_end = -1 }, true
		}

		active_signature_index := client.signature_help.active_signature
		if active_signature_index < 0                                       { active_signature_index = 0 }
		if active_signature_index >= len(client.signature_help.signatures)  { active_signature_index = len(client.signature_help.signatures) - 1 }

		signature := client.signature_help.signatures[active_signature_index]
		active_parameter_index := client.signature_help.active_parameter
		if active_parameter_index < 0                                  { active_parameter_index = 0 }
		if active_parameter_index >= len(signature.parameter_ranges)   { active_parameter_index = -1 }

		result := binding_pkg.SignatureInfo{
			label         = strings.clone(signature.label,         allocator),
			documentation = strings.clone(signature.documentation, allocator),
			active_start  = -1,
			active_end    = -1,
		}
		if active_parameter_index >= 0 {
			active_range := signature.parameter_ranges[active_parameter_index]
			result.active_start = active_range.start_byte
			result.active_end   = active_range.end_byte
		}
		lsp.signature_help_result_clear(&client.signature_help)
		return result, true
	}
	return {}, false
}

@(private)
editor_api_lsp_request_completion :: proc(editor_ptr: rawptr) -> bool {
	editor := cast(^Editor)editor_ptr
	client, editor_pane, ok := editor_api_active_lsp(editor)
	if !ok { return false }
	editor_lsp_flush_pending_change(editor, editor_pane)
	lsp.client_request_completion(client, editor_pane.file_path, i32(editor_pane.cursor_line), i32(editor_pane.cursor_column))
	return true
}

@(private)
editor_api_lsp_poll_completion :: proc(editor_ptr: rawptr, allocator: runtime.Allocator) -> (items: []binding_pkg.CompletionItem, ok: bool) {
	editor := cast(^Editor)editor_ptr
	for _, client in editor.lsp_clients {
		if !client.completion.is_valid { continue }
		converted := make([]binding_pkg.CompletionItem, len(client.completion.items), allocator)
		for raw_item, item_index in client.completion.items {
			converted[item_index] = binding_pkg.CompletionItem{
				label       = strings.clone(raw_item.label,       allocator),
				detail      = strings.clone(raw_item.detail,      allocator),
				insert_text = strings.clone(raw_item.insert_text, allocator),
			}
		}
		lsp.completion_result_clear(&client.completion)
		return converted, true
	}
	return nil, false
}

@(private)
editor_api_apply_completion_at_cursor :: proc(editor_ptr: rawptr, pane_index: int, insert_text: string) {
	editor := cast(^Editor)editor_ptr
	if pane_index < 0 || pane_index >= len(editor.panes) { return }
	editor_pane := pane_as_editor(&editor.panes[pane_index]); if editor_pane == nil { return }

	cursor_offset := editor_pane.cursor_offset
	prefix_start  := cursor_offset
	for prefix_start > 0 {
		previous_byte := editor_api_document_byte_at(editor_pane, prefix_start - 1)
		if !editor_api_is_identifier_byte(previous_byte) { break }
		prefix_start -= 1
	}
	if prefix_start < cursor_offset {
		document.document_delete(&editor_pane.document, prefix_start, cursor_offset - prefix_start)
		editor_pane.cursor_offset = prefix_start
	}
	document.document_insert(&editor_pane.document, editor_pane.cursor_offset, insert_text)
	editor_pane.cursor_offset += u32(len(insert_text))
	pane_mark_document_modified(editor, editor_pane)
	sync_cursor_from_offset(editor)
}

@(private="file")
editor_api_document_byte_at :: proc(editor_pane: ^EditorPane, offset: u32) -> u8 {
	byte_slice := document.document_get_slice(&editor_pane.document, offset, 1, context.temp_allocator)
	if len(byte_slice) == 0 { return 0 }
	return byte_slice[0]
}

@(private="file")
editor_api_is_identifier_byte :: proc(byte_value: u8) -> bool {
	return (byte_value >= 'a' && byte_value <= 'z') ||
	       (byte_value >= 'A' && byte_value <= 'Z') ||
	       (byte_value >= '0' && byte_value <= '9') ||
	       byte_value == '_'
}

@(private)
editor_api_markdown_context :: proc(editor_ptr: rawptr, renderer: ^sdl3.Renderer) -> markdown.Context {
	editor := cast(^Editor)editor_ptr
	return editor_markdown_context(editor, renderer)
}

@(private)
editor_api_active_pane_cursor :: proc(editor_ptr: rawptr) -> binding_pkg.ActivePaneCursor {
	editor := cast(^Editor)editor_ptr
	result := binding_pkg.ActivePaneCursor{
		pane_index = editor.active_pane_index,
	}
	if active_editor_pane := editor_active_editor_pane(editor); active_editor_pane != nil {
		result.cursor_line   = active_editor_pane.cursor_line
		result.cursor_column = active_editor_pane.cursor_column
		result.cursor_offset = active_editor_pane.cursor_offset
		result.is_editor     = true
	}
	return result
}

@(private)
editor_api_pane_anchor :: proc(editor_ptr: rawptr, pane_index: int, anchor_line: u32) -> binding_pkg.PaneAnchor {
	editor := cast(^Editor)editor_ptr
	if pane_index < 0 || pane_index >= len(editor.panes) { return {} }
	pane := &editor.panes[pane_index]
	editor_pane := pane_as_editor(pane); if editor_pane == nil { return {} }

	title_bar_height    := editor_title_bar_height(editor)
	cursor_screen_top_y := pane.rectangle.y + title_bar_height + editor.padding_y + i32(anchor_line) * editor.line_height - i32(editor_pane.scroll_y)
	return binding_pkg.PaneAnchor{
		cursor_screen_top_y = cursor_screen_top_y,
		cursor_line_height  = editor.line_height,
		character_width     = editor.character_width,
		pane_left_x         = pane.rectangle.x,
		pane_top_y          = pane.rectangle.y + title_bar_height,
		text_left_x         = pane.rectangle.x + editor.padding_x + editor_pane.gutter_width,
	}
}

@(private)
editor_api_theme :: proc(editor_ptr: rawptr) -> binding_pkg.Theme {
	editor := cast(^Editor)editor_ptr
	return binding_pkg.Theme{
		background_color          = editor.background_color,
		foreground_color          = editor.foreground_color,
		status_bar_background     = editor.status_bar_background,
		divider_color             = editor.divider_color,
		cursor_color              = editor.cursor_color,
		selection_color           = editor.selection_color,
		line_number_color         = editor.line_number_color,
		syntax_keyword_foreground = editor.syntax_keyword_foreground,
	}
}

// --- symbols subpackage host + per-pane symbol cache --------------------

// Walk every line of the pane's doc through the language's symbol
// patterns and rebuild `symbols` + `symbol_names`. Called on file load,
// when symbols_dialog opens (so the dialog sees fresh data), and on the
// background reanalyze tick. Lives here rather than in the subpackage
// because `symbol_names` is also consumed by the per-line syntax
// tokenizer.
@(private)
pane_rebuild_symbols :: proc(editor_pane: ^EditorPane) {
	for existing_symbol in editor_pane.symbols { delete(existing_symbol.name) }
	clear(&editor_pane.symbols)
	clear(&editor_pane.symbol_names)

	if editor_pane.language == nil { return }

	total_line_count := document.document_line_count(&editor_pane.document)

	// Materialize every line into a slice once — the syntax matcher
	// works on a whole-file lexeme stream so patterns like
	// `template ... class {NAME} {` can span newlines.
	all_lines := make([]string, total_line_count, context.temp_allocator)
	for line_index in 0..<total_line_count {
		all_lines[line_index] = document.document_get_line(&editor_pane.document, line_index, context.temp_allocator)
	}

	// Pass 1: discover user-declared type names so the `{TYPE}`
	// placeholder can resolve references regardless of declaration
	// order. All allocations live in temp_allocator and survive until
	// the end of this proc, after pass 2 has consumed the map.
	known_type_names := make(map[string]bool, 0, context.temp_allocator)
	{
		scratch_symbols: [dynamic]syntax.Symbol
		scratch_symbols.allocator = context.temp_allocator
		syntax.extract_symbols_from_lines(editor_pane.language, all_lines, &scratch_symbols, nil, context.temp_allocator)
		for scratch_symbol in scratch_symbols {
			if scratch_symbol.kind == .Type { known_type_names[scratch_symbol.name] = true }
		}
	}

	// Pass 2: full extraction (names cloned with the long-lived allocator).
	syntax.extract_symbols_from_lines(editor_pane.language, all_lines, &editor_pane.symbols, &known_type_names)

	for extracted_symbol in editor_pane.symbols {
		editor_pane.symbol_names[extracted_symbol.name] = extracted_symbol.kind
	}
}

// Refresh the active pane's symbol cache and open the picker.
@(private)
symbols_open :: proc(editor: ^Editor) {
	editor_pane := editor_active_editor_pane(editor)
	if editor_pane == nil { return }

	// Always refresh on open so the user sees the latest declarations.
	pane_rebuild_symbols(editor_pane)
	editor_pane.symbols_dirty      = false
	editor_pane.last_analysis_time = editor.clock

	symbols_pkg.open(&editor.symbols_dialog, editor.active_pane_index, editor_pane.symbols[:])
}

@(private="file")
symbols_host_source_pane :: proc(editor: ^Editor) -> ^EditorPane {
	source_pane_index := editor.symbols_dialog.source_pane_index
	if source_pane_index < 0 || source_pane_index >= len(editor.panes) { return nil }
	return pane_as_editor(&editor.panes[source_pane_index])
}

@(private)
symbols_host_source_symbols :: proc(user_data: rawptr) -> []syntax.Symbol {
	editor := cast(^Editor)user_data
	source_editor_pane := symbols_host_source_pane(editor)
	if source_editor_pane == nil { return nil }
	return source_editor_pane.symbols[:]
}

@(private)
symbols_host_dialog_title :: proc(user_data: rawptr, allocator: runtime.Allocator) -> string {
	editor := cast(^Editor)user_data
	source_editor_pane := symbols_host_source_pane(editor)
	if source_editor_pane == nil { return strings.clone("Symbols", allocator) }
	display_filename := source_editor_pane.file_path != "" ? filepath.base(source_editor_pane.file_path) : "untitled"
	return fmt.aprintf("Symbols — %s", display_filename, allocator = allocator)
}

@(private)
symbols_host_apply_activate :: proc(user_data: rawptr, symbol_index: int) {
	editor := cast(^Editor)user_data
	source_editor_pane := symbols_host_source_pane(editor)
	if source_editor_pane == nil { return }
	if symbol_index < 0 || symbol_index >= len(source_editor_pane.symbols) { return }

	selected_symbol := source_editor_pane.symbols[symbol_index]

	// Focus the source pane and place the cursor on the symbol's name.
	editor.active_pane_index = editor.symbols_dialog.source_pane_index

	document_line_count := document.document_line_count(&source_editor_pane.document)
	target_line := selected_symbol.line
	if target_line >= document_line_count { target_line = document_line_count - 1 }

	line_start_offset := document.document_line_start(&source_editor_pane.document, target_line)
	line_text         := document.document_get_line(&source_editor_pane.document, target_line, context.temp_allocator)
	target_column     := selected_symbol.column
	if int(target_column) > len(line_text) { target_column = u32(len(line_text)) }

	source_editor_pane.cursor_line      = target_line
	source_editor_pane.cursor_column    = target_column
	source_editor_pane.cursor_offset    = line_start_offset + target_column
	source_editor_pane.selection_active = false

	editor.cursor_visible = true
	editor.cursor_timer = 0

	// Position the target line at the top of the pane's text area
	// instead of just making it visible. In diff mode the layout is
	// row-indexed and shared between panes, so we defer to the existing
	// scroll-into-view behaviour there.
	if editor.diff_state.active || editor.line_height <= 0 {
		sync_cursor_from_offset(editor)
	} else {
		target_scroll_y := f32(target_line) * f32(editor.line_height)
		if target_scroll_y < 0 { target_scroll_y = 0 }
		source_editor_pane.scroll_y        = target_scroll_y
		source_editor_pane.scroll_y_target = target_scroll_y
		source_editor_pane.scroll_line     = target_line
	}
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
	diff_state_destroy(&editor.diff_state)
	symbols_pkg.destroy(&editor.symbols_dialog)
	find_state_destroy(&editor.find)
	replace_state_destroy(&editor.replace)
	replace_in_files_destroy(&editor.replace_in_files)
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
	debug_state_destroy(&editor.debug_state)
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

// Per-content cleanup. Add cases here as new content types are introduced.
@(private)
pane_destroy :: proc(pane: ^Pane) {
	pane_content_destroy(&pane.content)
	if pane.has_saved_content {
		pane_content_destroy(&pane.saved_content)
		pane.has_saved_content = false
	}
}

// Tear down a single PaneContent without touching the surrounding Pane.
// Factored so the terminal stash/restore dance can release whatever the
// pane's previous content held.
@(private)
pane_content_destroy :: proc(pane_content: ^PaneContent) {
	#partial switch &content_value in pane_content {
	case EditorPane:
		editor_pane_destroy_in_place(&content_value)
	case TerminalPane:
		// Terminal lifetimes are owned by `Editor.terminals`, not by the
		// pane — the pane just holds a borrowed pointer. Clearing it here
		// (instead of calling terminal_destroy) lets the pane be replaced
		// or torn down without killing a session the user only meant to
		// hide. `editor_destroy` is the one place that actually destroys.
		content_value.terminal = nil
	case MarkdownPreviewPane:
		markdown_preview_pane_destroy(&content_value)
	case OutputPane:
		// Log buffer is owned by Editor.debug_output_lines, not the pane —
		// pane teardown just drops the scroll state struct.
		_ = content_value
	}
}

// Release every owned resource on an EditorPane in place. Shared by
// `pane_content_destroy` (for live panes) and `editor_destroy` (for
// EditorPanes parked in `background_documents`).
@(private)
editor_pane_destroy_in_place :: proc(editor_pane: ^EditorPane) {
	document.document_destroy(&editor_pane.document)
	if len(editor_pane.file_path) > 0 {
		delete(editor_pane.file_path)
		editor_pane.file_path = ""
	}
	if len(editor_pane.display_title_override) > 0 {
		delete(editor_pane.display_title_override)
		editor_pane.display_title_override = ""
	}
	for symbol in editor_pane.symbols { delete(symbol.name) }
	delete(editor_pane.symbols)
	delete(editor_pane.symbol_names)
}

// Height of the title strip at the top of every editor pane (filename area).
// Used by both render and mouse-coordinate translation.
@(private)
editor_title_bar_height :: proc(editor: ^Editor) -> i32 {
	return editor.line_height + 6
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

// Pixel height reserved for the find bar at the bottom of a pane when find
// mode is active on that pane. Returns 0 when find isn't active for this pane.
@(private)
editor_find_bar_height_for_pane :: proc(editor: ^Editor, pane_index: int) -> i32 {
	if !editor.find.active                       { return 0 }
	if editor.find.pane_index != pane_index      { return 0 }
	return editor.line_height + 10
}

// Total pixel height reserved at the bottom of a pane for any active overlay
// bar (find OR replace — only one can be active at a time). Used by the
// renderer to shrink the text-area height.
@(private)
editor_bottom_bar_height_for_pane :: proc(editor: ^Editor, pane_index: int) -> i32 {
	return editor_find_bar_height_for_pane(editor, pane_index) + replace_bar_height_for_pane(editor, pane_index)
}

// --- Pane accessors -------------------------------------------------------

@(private)
editor_active_pane :: proc(editor: ^Editor) -> ^Pane {
	return &editor.panes[editor.active_pane_index]
}

// Single sink for "this pane's document just changed". Flips every dirty flag
// that gates an idle/debounced rebuild so future flags (next time we add
// another debounced consumer) get picked up by every existing mutation site
// for free. Stamps `editor.clock` on the LSP edit timer so the didChange
// debounce in `editor_lsp_update` measures from the latest edit.
@(private)
pane_mark_document_modified :: proc(editor: ^Editor, editor_pane: ^EditorPane) {
	editor_pane.symbols_dirty       = true
	editor_pane.markdown_dirty      = true
	editor_pane.lsp_dirty           = true
	editor_pane.lsp_last_edit_time  = editor.clock
}

// Returns the active pane's `EditorPane`, or nil if the active pane is not an
// editor pane. Most cursor/selection/clipboard procs short-circuit on nil so
// they're safe to call regardless of what kind of pane is currently focused.
@(private)
editor_active_editor_pane :: proc(editor: ^Editor) -> ^EditorPane {
	return pane_as_editor(&editor.panes[editor.active_pane_index])
}

@(private)
pane_as_editor :: proc(pane: ^Pane) -> ^EditorPane {
	editor_pane_value, is_editor_pane := &pane.content.(EditorPane)
	return editor_pane_value if is_editor_pane else nil
}

// Returns 2 when a split is showing both panes; 1 otherwise.
@(private)
editor_visible_pane_count :: proc(editor: ^Editor) -> int {
	return 2 if editor.split_active else 1
}

// Hit-test: which pane is the given pixel position over? Returns -1 if none.
@(private)
editor_pane_at :: proc(editor: ^Editor, pixel_x, pixel_y: f32) -> int {
	for pane_index in 0..<editor_visible_pane_count(editor) {
		pane_rectangle := editor.panes[pane_index].rectangle
		if pixel_x >= f32(pane_rectangle.x) && pixel_x < f32(pane_rectangle.x + pane_rectangle.w) &&
		   pixel_y >= f32(pane_rectangle.y) && pixel_y < f32(pane_rectangle.y + pane_rectangle.h) {
			return pane_index
		}
	}
	return -1
}

// Toggle focus to the other pane (no-op when no split is active).
@(private)
editor_focus_other_pane :: proc(editor: ^Editor) {
	if !editor.split_active { return }
	editor.active_pane_index = 1 - editor.active_pane_index
	editor.cursor_visible = true
	editor.cursor_timer = 0
}

// Move focus to a specific pane by index. When the user asks for pane[1]
// (the right pane) but split isn't currently active, we open the split —
// the right pane is always populated (editor_init seeds it with an empty
// editor), so revealing it is enough; no new content gets created.
@(private)
editor_focus_pane :: proc(editor: ^Editor, target_pane_index: int) {
	if target_pane_index < 0 || target_pane_index >= len(editor.panes) { return }
	if target_pane_index == 1 && !editor.split_active {
		editor.split_active = true
	}
	if editor.active_pane_index == target_pane_index { return }
	editor.active_pane_index = target_pane_index
	editor.cursor_visible = true
	editor.cursor_timer = 0
	editor_mark_dirty(editor)
}

// Move the active pane's content to `target_pane_index`. If both panes
// have content we swap (so neither doc gets lost); if the destination is
// the empty initial editor pane, the source's content effectively shifts
// over and the source is left with the destination's old empty slot. When
// targeting the right pane while split is inactive, the split opens — the
// right pane is then revealed with the moved content.
//
// Focus follows the moved content so the user can keep typing without an
// extra Ctrl+Tab.
@(private)
editor_move_active_to_pane :: proc(editor: ^Editor, target_pane_index: int) {
	if target_pane_index < 0 || target_pane_index >= len(editor.panes) { return }
	if editor.active_pane_index == target_pane_index { return }

	if target_pane_index == 1 && !editor.split_active {
		editor.split_active = true
	}

	source_index := editor.active_pane_index
	// Swap the two contents wholesale. PaneContent is a union — both fields
	// own their payload (EditorPane.document, etc.) so the swap doesn't
	// alias any state. Borrowed-pointer panes (TerminalPane, OutputPane)
	// just shuffle the pointer, which is fine.
	source_content      := editor.panes[source_index].content
	destination_content := editor.panes[target_pane_index].content
	editor.panes[source_index].content      = destination_content
	editor.panes[target_pane_index].content = source_content

	// Close any Find / Replace bars pinned to the panes whose content just
	// shifted out from under them — the bar's `pane_index` would otherwise
	// point at a doc that's now somewhere else.
	if find_active(editor)    && (editor.find.pane_index    == source_index || editor.find.pane_index    == target_pane_index) { find_close(editor) }
	if replace_active(editor) && (editor.replace.pane_index == source_index || editor.replace.pane_index == target_pane_index) { replace_close(editor, false) }

	editor.active_pane_index = target_pane_index
	editor.cursor_visible = true
	editor.cursor_timer = 0
	editor_mark_dirty(editor)
}

// --- Multi-terminal session model -----------------------------------------
//
// Terminals live in `editor.terminals` and are independent of pane state.
// pane[1] is the "terminal slot" — when a terminal is being shown it holds
// a `TerminalPane` whose `terminal` field is a *borrowed* pointer aliasing
// the active entry. The terminal itself stays alive even when pane[1] is
// showing something else.
//
// F9               toggle visibility of the active terminal (creates the
//                  first one when the list is empty)
// Ctrl+F9          always create a new session and make it the active one
// Ctrl+Shift+F9    open a picker over `editor.terminals`
// Ctrl+F4          (in a terminal pane) destroy the active session

@(private)
TERMINAL_PANE_INDEX :: 1

@(private)
editor_is_terminal_visible :: proc(editor: ^Editor) -> bool {
	_, is_terminal := editor.panes[TERMINAL_PANE_INDEX].content.(TerminalPane)
	return is_terminal
}

@(private)
editor_active_terminal :: proc(editor: ^Editor) -> ^terminal.Terminal {
	if len(editor.terminals) == 0 { return nil }
	if editor.active_terminal_index < 0 || editor.active_terminal_index >= len(editor.terminals) { return nil }
	return editor.terminals[editor.active_terminal_index].terminal
}

// --- terminal_picker host trampolines ------------------------------------
//
// The picker calls these via its Host callbacks; they cast `user_data`
// back to `^Editor` and apply the requested mutation. Keeps the
// terminal_picker subpackage's import graph clean: it never depends on
// the editor package.

@(private)
terminal_picker_host_list_entries :: proc(user_data: rawptr, allocator: runtime.Allocator) -> []terminal_picker_pkg.Entry {
	editor := cast(^Editor)user_data
	entries := make([]terminal_picker_pkg.Entry, len(editor.terminals), allocator)
	for entry, entry_index in editor.terminals {
		entries[entry_index] = terminal_picker_pkg.Entry{
			display_number = entry.display_number,
			is_active      = entry_index == editor.active_terminal_index,
		}
	}
	return entries
}

@(private)
terminal_picker_host_initial_selection :: proc(user_data: rawptr) -> int {
	editor := cast(^Editor)user_data
	return max(0, editor.active_terminal_index)
}

// Switch the active terminal to whichever entry the picker activated.
// Same pane-swap dance the old `editor_activate_terminal_at` did,
// reached now through the Host callback rather than a direct call.
@(private)
terminal_picker_host_activate :: proc(user_data: rawptr, entry_index: int) {
	editor := cast(^Editor)user_data
	if entry_index < 0 || entry_index >= len(editor.terminals) { return }
	editor.active_terminal_index = entry_index

	if editor_is_terminal_visible(editor) {
		if terminal_pane, is_terminal := &editor.panes[TERMINAL_PANE_INDEX].content.(TerminalPane); is_terminal {
			terminal_pane.terminal = editor_active_terminal(editor)
		}
		editor.active_pane_index = TERMINAL_PANE_INDEX
	} else {
		editor_terminal_show(editor)
	}
}

// --- open_docs host trampolines ------------------------------------------

@(private)
open_docs_host_list_entries :: proc(user_data: rawptr, source_pane_index: int, allocator: runtime.Allocator) -> []open_docs_pkg.EntrySource {
	editor := cast(^Editor)user_data
	sources := make([dynamic]open_docs_pkg.EntrySource, 0, 16, allocator)

	// Source pane (active) first so the user's current doc is the top row.
	if source_pane_index >= 0 && source_pane_index < len(editor.panes) {
		if source_editor_pane := pane_as_editor(&editor.panes[source_pane_index]); source_editor_pane != nil {
			append(&sources, open_docs_pkg.EntrySource{
				location   = .ActivePane,
				pane_index = source_pane_index,
				is_dirty   = document.document_is_dirty(&source_editor_pane.document),
				label      = open_docs_format_label(source_editor_pane, source_pane_index, .ActivePane, allocator),
			})
		}
	}

	// Other-pane doc, if a split is active.
	if editor.split_active {
		for visible_pane_index in 0..<len(editor.panes) {
			if visible_pane_index == source_pane_index { continue }
			other_editor_pane := pane_as_editor(&editor.panes[visible_pane_index])
			if other_editor_pane == nil { continue }
			append(&sources, open_docs_pkg.EntrySource{
				location   = .OtherPane,
				pane_index = visible_pane_index,
				is_dirty   = document.document_is_dirty(&other_editor_pane.document),
				label      = open_docs_format_label(other_editor_pane, visible_pane_index, .OtherPane, allocator),
			})
		}
	}

	// Background documents — most-recently-stashed first.
	for reverse_index := len(editor.background_documents) - 1; reverse_index >= 0; reverse_index -= 1 {
		background_editor_pane := &editor.background_documents[reverse_index]
		append(&sources, open_docs_pkg.EntrySource{
			location         = .Background,
			background_index = reverse_index,
			is_dirty         = document.document_is_dirty(&background_editor_pane.document),
			label            = open_docs_format_label(background_editor_pane, -1, .Background, allocator),
		})
	}
	return sources[:]
}

@(private)
open_docs_host_activate :: proc(user_data: rawptr, source_pane_index: int, location: open_docs_pkg.EntryLocation, pane_index, background_index: int) {
	editor := cast(^Editor)user_data
	switch location {
	case .ActivePane:
		// Picking the currently-active doc — just close (handled by
		// the modal itself).

	case .OtherPane:
		if pane_index >= 0 && pane_index < len(editor.panes) {
			editor.active_pane_index = pane_index
		}

	case .Background:
		// Pull the stashed doc into the pane the dialog opened from.
		editor_swap_background_into_pane(editor, source_pane_index, background_index)
	}
	editor.cursor_visible = true
	editor.cursor_timer   = 0
}

@(private)
open_docs_format_label :: proc(editor_pane: ^EditorPane, pane_index: int, location: open_docs_pkg.EntryLocation, allocator := context.temp_allocator) -> string {
	dirty_marker := document.document_is_dirty(&editor_pane.document) ? "* " : "  "

	display_name: string
	full_path:    string
	switch {
	case len(editor_pane.display_title_override) > 0:
		display_name = editor_pane.display_title_override
	case len(editor_pane.file_path) > 0:
		display_name = open_docs_filepath_base(editor_pane.file_path)
		full_path    = editor_pane.file_path
	case:
		display_name = "untitled"
	}

	location_tag: string
	switch location {
	case .ActivePane: location_tag = "[active]"
	case .OtherPane:  location_tag = fmt.tprintf("[Pane %d]", pane_index + 1)
	case .Background: location_tag = ""
	}

	if len(full_path) > 0 && len(location_tag) > 0 {
		return strings.clone(fmt.tprintf("%s%s — %s    %s", dirty_marker, display_name, full_path, location_tag), allocator)
	}
	if len(full_path) > 0 {
		return strings.clone(fmt.tprintf("%s%s — %s", dirty_marker, display_name, full_path), allocator)
	}
	if len(location_tag) > 0 {
		return strings.clone(fmt.tprintf("%s%s    %s", dirty_marker, display_name, location_tag), allocator)
	}
	return strings.clone(fmt.tprintf("%s%s", dirty_marker, display_name), allocator)
}

@(private)
open_docs_filepath_base :: proc(file_path: string) -> string {
	if len(file_path) == 0 { return file_path }
	for character_index := len(file_path) - 1; character_index >= 0; character_index -= 1 {
		current_character := file_path[character_index]
		if current_character == '/' || current_character == '\\' { return file_path[character_index+1:] }
	}
	return file_path
}

// Display number of the active terminal entry, or 0 when nothing's open.
// Used by the title strip and the picker so the user sees the same stable
// "Terminal #N" label regardless of where it appears.
@(private)
editor_active_terminal_display_number :: proc(editor: ^Editor) -> int {
	if len(editor.terminals) == 0 { return 0 }
	if editor.active_terminal_index < 0 || editor.active_terminal_index >= len(editor.terminals) { return 0 }
	return editor.terminals[editor.active_terminal_index].display_number
}

// Show the active terminal in pane[1], stashing whatever was there into the
// pane's `saved_content` slot. No-op when no terminals exist or one is
// already visible — the caller is expected to handle those.
@(private)
editor_terminal_show :: proc(editor: ^Editor) {
	if editor_is_terminal_visible(editor) { return }
	active_terminal := editor_active_terminal(editor); if active_terminal == nil { return }

	pane := &editor.panes[TERMINAL_PANE_INDEX]
	// Drop any prior saved_content defensively — a stale stash would leak
	// the doc we'd be overwriting.
	if pane.has_saved_content {
		pane_content_destroy(&pane.saved_content)
		pane.has_saved_content = false
	}
	pane.saved_content      = pane.content
	pane.saved_split_active = editor.split_active
	pane.has_saved_content  = true

	pane.content             = TerminalPane{ terminal = active_terminal }
	editor.split_active      = true
	editor.active_pane_index = TERMINAL_PANE_INDEX
}

// Hide the currently-visible terminal: restore pane[1] from `saved_content`
// (and the matching `split_active` snapshot) without destroying anything in
// `editor.terminals`. The session keeps running in the background.
@(private)
editor_terminal_hide :: proc(editor: ^Editor) {
	if !editor_is_terminal_visible(editor) { return }
	pane := &editor.panes[TERMINAL_PANE_INDEX]

	// Clear the borrowed pointer before swapping content out — keeps the
	// pane_content_destroy fallthrough below from doing anything to a
	// terminal that's still owned by `editor.terminals`.
	if terminal_pane, is_terminal := &pane.content.(TerminalPane); is_terminal {
		terminal_pane.terminal = nil
	}

	if pane.has_saved_content {
		pane.content            = pane.saved_content
		editor.split_active     = pane.saved_split_active
		pane.saved_content      = PaneContent{}
		pane.saved_split_active = false
		pane.has_saved_content  = false
	} else {
		pane.content        = PaneContent{}
		editor.split_active = false
	}

	if !editor.split_active { editor.active_pane_index = 0 }
}

// Spawn a new shell session and make it the active terminal. If the slot is
// already visible the borrowed pointer in pane[1] swaps to the new one; if
// hidden, this also makes the slot visible.
@(private)
editor_terminal_create_new :: proc(editor: ^Editor) {
	pane := &editor.panes[TERMINAL_PANE_INDEX]
	pane_rectangle := pane.rectangle
	if pane_rectangle.w == 0 || pane_rectangle.h == 0 {
		// Pane hasn't been laid out yet; conjure something reasonable so
		// the shell gets a sane initial size and the renderer adjusts on
		// the next frame.
		pane_rectangle = sdl3.Rect{ x = 0, y = 0, w = 720, h = 480 }
	}
	character_width := editor.character_width;  if character_width <= 0 { character_width = 8 }
	line_height     := editor.line_height;      if line_height     <= 0 { line_height     = 16 }

	row_count    := max(i32(4),  (pane_rectangle.h - editor_title_bar_height(editor)) / line_height)
	column_count := max(i32(10), pane_rectangle.w / character_width)

	default_foreground := terminal.Color{ editor.foreground_color.r, editor.foreground_color.g, editor.foreground_color.b, editor.foreground_color.a }
	default_background := terminal.Color{ editor.background_color.r, editor.background_color.g, editor.background_color.b, editor.background_color.a }

	// When a project root is set, anchor the shell there so terminal commands
	// run relative to the project regardless of where the editor was launched
	// from. Otherwise inherit the editor's own cwd ("" = pass nil to spawn).
	new_terminal := terminal.terminal_new(row_count, column_count, default_foreground, default_background, editor.project_root)
	if new_terminal == nil { return }

	editor.next_terminal_display_number += 1
	append(&editor.terminals, TerminalEntry{
		terminal       = new_terminal,
		display_number = editor.next_terminal_display_number,
	})
	editor.active_terminal_index = len(editor.terminals) - 1

	if editor_is_terminal_visible(editor) {
		// Already showing a different session — swap the borrowed pointer
		// in place rather than re-stashing pane[1].
		if terminal_pane, is_terminal := &editor.panes[TERMINAL_PANE_INDEX].content.(TerminalPane); is_terminal {
			terminal_pane.terminal = new_terminal
		}
		editor.active_pane_index = TERMINAL_PANE_INDEX
	} else {
		editor_terminal_show(editor)
	}
}

// Spawn a one-shot terminal session running `command_line` instead of the
// default interactive shell. Tagged as a build job so the per-frame poll in
// `editor_dap_update` can watch its exit code and (when the build belongs
// to a build-then-debug chain) auto-start the queued debug session on
// success. Returns the new terminal pointer or nil on failure.
@(private)
editor_terminal_create_for_build :: proc(editor: ^Editor, command_line: string, working_directory: string, build_profile_name: string, pending_debug_profile_index: int) -> ^terminal.Terminal {
	pane := &editor.panes[TERMINAL_PANE_INDEX]
	pane_rectangle := pane.rectangle
	if pane_rectangle.w == 0 || pane_rectangle.h == 0 {
		pane_rectangle = sdl3.Rect{ x = 0, y = 0, w = 720, h = 480 }
	}
	character_width := editor.character_width;  if character_width <= 0 { character_width = 8 }
	line_height     := editor.line_height;      if line_height     <= 0 { line_height     = 16 }

	row_count    := max(i32(4),  (pane_rectangle.h - editor_title_bar_height(editor)) / line_height)
	column_count := max(i32(10), pane_rectangle.w / character_width)

	default_foreground := terminal.Color{ editor.foreground_color.r, editor.foreground_color.g, editor.foreground_color.b, editor.foreground_color.a }
	default_background := terminal.Color{ editor.background_color.r, editor.background_color.g, editor.background_color.b, editor.background_color.a }

	cwd := working_directory
	if len(cwd) == 0 { cwd = editor.project_root }

	new_terminal := terminal.terminal_new(row_count, column_count, default_foreground, default_background, cwd, command_line)
	if new_terminal == nil { return nil }

	editor.next_terminal_display_number += 1
	append(&editor.terminals, TerminalEntry{
		terminal                    = new_terminal,
		display_number              = editor.next_terminal_display_number,
		is_build_job                = true,
		build_profile_name          = strings.clone(build_profile_name),
		pending_debug_profile_index = pending_debug_profile_index,
	})
	editor.active_terminal_index = len(editor.terminals) - 1

	if editor_is_terminal_visible(editor) {
		if terminal_pane, is_terminal := &editor.panes[TERMINAL_PANE_INDEX].content.(TerminalPane); is_terminal {
			terminal_pane.terminal = new_terminal
		}
		editor.active_pane_index = TERMINAL_PANE_INDEX
	} else {
		editor_terminal_show(editor)
	}
	return new_terminal
}

// Kill the active terminal session. If others remain, the next one in the
// list becomes active and the visible pane (if any) swaps over to it. If the
// list empties, pane[1] is restored from saved_content.
@(private)
editor_terminal_destroy_active :: proc(editor: ^Editor) {
	if len(editor.terminals) == 0 { return }
	if editor.active_terminal_index < 0 || editor.active_terminal_index >= len(editor.terminals) { return }

	was_visible := editor_is_terminal_visible(editor)

	doomed_terminal := editor.terminals[editor.active_terminal_index].terminal
	if doomed_entry_name := editor.terminals[editor.active_terminal_index].build_profile_name; len(doomed_entry_name) > 0 {
		delete(doomed_entry_name)
	}
	ordered_remove(&editor.terminals, editor.active_terminal_index)

	// Clear the borrowed pointer in pane[1] *before* terminal_destroy so a
	// concurrent render path can't latch onto a half-freed handle.
	if was_visible {
		if terminal_pane, is_terminal := &editor.panes[TERMINAL_PANE_INDEX].content.(TerminalPane); is_terminal {
			terminal_pane.terminal = nil
		}
	}
	if doomed_terminal != nil { terminal.terminal_destroy(doomed_terminal) }

	if len(editor.terminals) == 0 {
		editor.active_terminal_index = 0
		if was_visible { editor_terminal_hide(editor) }
		return
	}

	// Clamp the active index to the new list size; the most natural fall-
	// through pick is the entry that just shifted into the removed slot
	// (same index unless we killed the last entry).
	if editor.active_terminal_index >= len(editor.terminals) {
		editor.active_terminal_index = len(editor.terminals) - 1
	}

	if was_visible {
		new_active := editor_active_terminal(editor)
		if terminal_pane, is_terminal := &editor.panes[TERMINAL_PANE_INDEX].content.(TerminalPane); is_terminal {
			terminal_pane.terminal = new_active
		}
	}
}

// F9: hide if currently visible, show the active one if hidden, or create
// the first session when none exist yet.
@(private)
editor_toggle_terminal :: proc(editor: ^Editor) {
	if editor_is_terminal_visible(editor) {
		editor_terminal_hide(editor)
		return
	}
	if len(editor.terminals) == 0 {
		editor_terminal_create_new(editor)
		return
	}
	editor_terminal_show(editor)
}

// --- Public open-string entry points --------------------------------------

editor_open_string :: proc(editor: ^Editor, content_text: string) {
	editor_open_string_in_pane(editor, editor.active_pane_index, content_text)
}

// Load a string into a specific pane. If a `file_path` is supplied and the
// document is already open (in any pane or in `background_documents`), this
// switches to the existing copy rather than reloading — the user's cursor,
// scroll, undo history and unsaved edits are preserved. Otherwise the target
// pane's current EditorPane is moved into `background_documents` (if it's
// worth keeping — has a path, override, or unsaved changes) and a fresh
// editor pane is installed in its place.
editor_open_string_in_pane :: proc(editor: ^Editor, pane_index: int, content_text: string, file_path: string = "") {
	if pane_index < 0 || pane_index >= len(editor.panes) { return }

	// Dedupe: if this path is already loaded, switch to it instead of doing a
	// fresh load. Avoids two EditorPanes diverging from the same on-disk file
	// and discards the (already-read) `content_text` argument — that read is
	// the caller's choice, not something we can undo here.
	if len(file_path) > 0 {
		existing_pane_index, existing_background_index := editor_find_open_document(editor, file_path)
		if existing_pane_index == pane_index { return }
		if existing_pane_index >= 0 {
			editor.active_pane_index = existing_pane_index
			return
		}
		if existing_background_index >= 0 {
			editor_swap_background_into_pane(editor, pane_index, existing_background_index)
			return
		}
	}

	// Stash whatever was in the target pane so it can be reached again from
	// the F4 picker. Untitled-and-clean panes are not worth stashing and are
	// just destroyed by `pane_destroy` below.
	pane_stash_editor(editor, pane_index)

	safe_content := content_text
	if len(safe_content) < 0 || len(safe_content) > EDITOR_MAX_DOCUMENT_BYTES {
		safe_content = ""
	}

	// Tear down whatever remains in the pane and install a fresh editor.
	pane_destroy(&editor.panes[pane_index])

	new_editor_pane: EditorPane
	document.document_init(&new_editor_pane.document, safe_content)
	if len(file_path) > 0 {
		// Normalize the on-disk path so display / comparison stays
		// consistent regardless of whether the OS handed us back slashes
		// or our own code joined with forward slashes.
		new_editor_pane.file_path = path_normalize(file_path)
		new_editor_pane.language  = syntax.get_definition_for_path(file_path)
	}
	editor.panes[pane_index].content = new_editor_pane

	// Build the per-pane symbol index now that the doc + language are wired up.
	if new_editor_pane.language != nil {
		if editor_pane := pane_as_editor(&editor.panes[pane_index]); editor_pane != nil {
			pane_rebuild_symbols(editor_pane)
		}
	}

	// Notify the LSP layer that a new document is open in this pane (if its
	// language has an LSP entry configured). Safe to call when no LSP is
	// available — the proc short-circuits.
	if editor_pane := pane_as_editor(&editor.panes[pane_index]); editor_pane != nil {
		editor_lsp_pane_opened(editor, editor_pane)
	}
}

// Drop a fresh untitled EditorPane into the given pane, destroying whatever
// was there. Use this on the Ctrl+F4 close path — `editor_open_string_in_pane`
// would stash the doc the user is asking to close, which is wrong.
@(private)
editor_replace_pane_with_empty_editor :: proc(editor: ^Editor, pane_index: int) {
	if pane_index < 0 || pane_index >= len(editor.panes) { return }
	if editor_pane := pane_as_editor(&editor.panes[pane_index]); editor_pane != nil {
		editor_lsp_pane_closing(editor, editor_pane)
	}
	pane_destroy(&editor.panes[pane_index])

	new_editor_pane: EditorPane
	document.document_init(&new_editor_pane.document, "")
	editor.panes[pane_index].content = new_editor_pane
}

// Move the target pane's EditorPane into `background_documents` if it's
// worth keeping (has a path, has a display-title override, or is dirty).
// On success the pane is left with an empty `PaneContent{}` — the caller is
// expected to install new content right after. Returns true when a stash
// actually happened.
@(private)
pane_stash_editor :: proc(editor: ^Editor, pane_index: int) -> bool {
	if pane_index < 0 || pane_index >= len(editor.panes) { return false }
	pane := &editor.panes[pane_index]
	editor_pane_ptr, is_editor := &pane.content.(EditorPane)
	if !is_editor { return false }

	is_worth_keeping := len(editor_pane_ptr.file_path) > 0 ||
	                    len(editor_pane_ptr.display_title_override) > 0 ||
	                    document.document_is_dirty(&editor_pane_ptr.document)
	if !is_worth_keeping { return false }

	// Find/Replace bars are pinned to a specific pane index; the doc we are
	// moving away is the one the bar was bound to, so close the bar before
	// the pane content changes underneath it.
	if find_active(editor)    && editor.find.pane_index    == pane_index { find_close(editor) }
	if replace_active(editor) && editor.replace.pane_index == pane_index { replace_close(editor, false) }

	// Append a value-copy; ownership of the heap-allocated fields transfers
	// to the new slot. We then *both* zero out the EditorPane fields in the
	// union storage AND set the union to its nil variant. The belt-and-
	// suspenders matters: if a later destroy path somehow still observes the
	// union as an EditorPane variant, every heap-pointer field is now nil/
	// empty so `editor_pane_destroy_in_place` short-circuits on each one
	// instead of double-freeing what we just transferred to the background.
	append(&editor.background_documents, editor_pane_ptr^)
	editor_pane_ptr^ = EditorPane{}
	pane.content = PaneContent{}
	return true
}

// Pull a background document into the target pane, stashing the pane's
// current content (if worth keeping) on the way out. Used both by
// `editor_open_string_in_pane` when a requested path is found in the stash
// and by the F4 picker when the user clicks a row.
@(private)
editor_swap_background_into_pane :: proc(editor: ^Editor, pane_index, background_index: int) {
	if pane_index       < 0 || pane_index       >= len(editor.panes)               { return }
	if background_index < 0 || background_index >= len(editor.background_documents) { return }

	// Lift the target out of the list first. Subsequent mutations to
	// `background_documents` (the stash that follows) can then freely append
	// without shifting the index we already captured.
	restored_editor_pane := editor.background_documents[background_index]
	ordered_remove(&editor.background_documents, background_index)

	// Move the pane's existing editor into the background, OR — if it isn't
	// stash-worthy — destroy it directly. Either way the pane is empty
	// afterwards and ready to receive the restored content.
	if !pane_stash_editor(editor, pane_index) {
		pane_destroy(&editor.panes[pane_index])
		editor.panes[pane_index].content = PaneContent{}
	}

	editor.panes[pane_index].content = restored_editor_pane
}

// Find an open EditorPane whose `file_path` matches (case-insensitively).
// Returns `(pane_index, -1)` when the doc is in a visible pane, `(-1,
// background_index)` when it's stashed, and `(-1, -1)` when not open.
@(private)
editor_find_open_document :: proc(editor: ^Editor, file_path: string) -> (pane_index: int, background_index: int) {
	pane_index, background_index = -1, -1
	if len(file_path) == 0 { return }

	for visible_pane_index in 0..<len(editor.panes) {
		visible_editor_pane := pane_as_editor(&editor.panes[visible_pane_index])
		if visible_editor_pane == nil                                                  { continue }
		if len(visible_editor_pane.file_path) == 0                                     { continue }
		if path_equals_ignore_case(visible_editor_pane.file_path, file_path) {
			pane_index = visible_pane_index
			return
		}
	}
	for background_editor_pane, idx in editor.background_documents {
		if len(background_editor_pane.file_path) == 0                                  { continue }
		if path_equals_ignore_case(background_editor_pane.file_path, file_path) {
			background_index = idx
			return
		}
	}
	return
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
	return editor.help.visible || editor.browse_view.visible || editor.symbols_dialog.visible || editor.find_in_files.visible || editor.show_replace_in_files || editor.save_as_dialog.visible || editor.close_confirm_dialog.visible || editor.git_history_dialog.visible || editor.open_docs_dialog.visible || editor.terminal_picker.visible || editor.tasks_dialog.visible || editor.breakpoint_condition_dialog.visible || editor.menu_bar.open_menu_index >= 0
}

// --- Project root ---------------------------------------------------------

// Replace the current project root. Pass "" to clear it. `path` is copied —
// the caller retains ownership of the buffer they pass in. Idempotent / safe
// to call repeatedly.
@(private)
editor_set_project_root :: proc(editor: ^Editor, path: string) {
	if len(editor.project_root) > 0 {
		delete(editor.project_root)
		editor.project_root = ""
	}
	if len(path) > 0 {
		// Normalize incoming path to platform-native separators so the
		// status bar, title strips, and debug output log all show one
		// consistent form regardless of whether the caller sourced the
		// path from F2 (OS-native) or from JSON config (forward slashes).
		editor.project_root = path_normalize(path)
	}
	// Reload per-project profiles whenever the root moves — the new root
	// might have its own `.odit/project.json`, and the old one's profiles
	// shouldn't follow the user across projects.
	project_config_reload(editor)
	// Forget any prior debug selection — indices into `debug_profiles` are
	// no longer meaningful against the new project's list.
	editor.active_debug_configuration_index = -1
	// Persist the new root so the next session can resume here.
	editor_persistence_save(editor)
}

// True when `path` is the project root or sits inside it. Caller passes
// already-normalized absolute paths; we just do a case-insensitive prefix
// check with a separator boundary so `C:/foo` is not treated as inside
// `C:/foobar`. Returns false if no project root is set.
@(private)
editor_path_inside_project_root :: proc(editor: ^Editor, path: string) -> bool {
	if len(editor.project_root) == 0 { return false }
	if len(path) == 0                { return false }
	if path_equals_ignore_case(path, editor.project_root) { return true }

	root_length := len(editor.project_root)
	if len(path) <= root_length { return false }
	if !path_has_prefix_ignore_case(path, editor.project_root) { return false }
	// Boundary check — refuse a hit where `editor.project_root` is just a
	// prefix of a longer sibling name.
	boundary_byte := path[root_length]
	return boundary_byte == '/' || boundary_byte == '\\'
}

// Case-insensitive path equality. ASCII-only fold; full Unicode case folding
// would need a real table and we don't need it for path matching on the
// platforms we target.
@(private)
path_equals_ignore_case :: proc(a, b: string) -> bool {
	if len(a) != len(b) { return false }
	for byte_index in 0..<len(a) {
		if ascii_fold_lower(a[byte_index]) != ascii_fold_lower(b[byte_index]) { return false }
	}
	return true
}

@(private="file")
path_has_prefix_ignore_case :: proc(path, prefix: string) -> bool {
	if len(prefix) > len(path) { return false }
	for byte_index in 0..<len(prefix) {
		if ascii_fold_lower(path[byte_index]) != ascii_fold_lower(prefix[byte_index]) { return false }
	}
	return true
}

// ASCII case-fold AND separator-fold. We want both `\` and `/` to compare as
// equal so paths from different sources (filepath.clean output, raw cwd, etc.)
// compare correctly. Full Unicode folding isn't needed for path matching on
// the platforms we target.
@(private="file")
ascii_fold_lower :: proc(byte_value: u8) -> u8 {
	if byte_value >= 'A' && byte_value <= 'Z' { return byte_value + ('a' - 'A') }
	if byte_value == '\\' { return '/' }
	return byte_value
}
