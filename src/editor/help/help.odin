// Package `help` is the F1 help dialog modal. It owns its visibility +
// scroll state, renders itself against a `ui.Context` the editor builds,
// and reports back via plain return values whether the host needs to
// repaint. Zero coupling to the editor package — drop in by hosting a
// `help.State` field and calling the small public API below.
//
// Extracted from src/editor/help.odin during the modal-subpackage split.
// Serves as the reference pattern for the other modals: state-owning
// package + ui.Context-driven render + "needs_redraw" booleans returned
// upward so the host stays in charge of dirty-tracking.
package help

import "vendor:sdl3"

import "../../ui"

State :: struct {
	visible:   bool,
	scroll:    i32,
	scrollbar: ui.Scrollbar,
}

@(private="file")
HelpItem :: struct {
	keybinding:  string,
	description: string,
}

@(private="file")
HelpSection :: struct {
	title: string,
	items: []HelpItem,
}

// Section content is package-scope so the slice in `HelpSection.items`
// references stable memory rather than a stack frame.

@(private="file")
editing_items := [?]HelpItem{
	{"Ctrl+Z",        "Undo last edit"},
	{"Ctrl+Shift+Z",  "Redo"},
	{"Ctrl+Y",        "Redo (alternate)"},
	{"Ctrl+C",        "Copy selection to clipboard"},
	{"Ctrl+V",        "Paste from clipboard"},
	{"Backspace",     "Delete char / selection"},
	{"Delete",        "Forward delete / selection"},
	{"Tab",           "Insert four spaces"},
	{"Enter",         "Insert newline"},
	{"Ctrl+S",        "Save (prompts for path if untitled)"},
	{"Ctrl+Shift+S",  "Save As (always prompts)"},
	{"Ctrl+F4",       "Close current file (prompts if unsaved)"},
}

@(private="file")
navigation_items := [?]HelpItem{
	{"Arrow keys",    "Move cursor"},
	{"Home / End",    "Jump to line start / end"},
	{"Ctrl+Home/End", "Jump to document start / end"},
	{"PageUp/Down",   "Jump one page"},
}

@(private="file")
selection_items := [?]HelpItem{
	{"Shift+Move",    "Extend selection with any nav key"},
	{"Mouse drag",    "Select with the mouse"},
	{"Shift+Click",   "Extend selection to click point"},
	{"Left / Right",  "Collapse selection without moving"},
}

@(private="file")
view_items := [?]HelpItem{
	{"Mouse wheel",   "Smooth scroll"},
	{"Ctrl+Wheel",    "Zoom font size"},
}

@(private="file")
find_items := [?]HelpItem{
	{"Ctrl+F",        "Open find bar (wildcards * and ? supported)"},
	{"Up / Down",     "In find: previous / next match"},
	{"Enter",         "In find: next match (Shift+Enter: previous)"},
	{"Esc",           "In find: close the bar"},
	{"Ctrl+Shift+F",  "Find in files (recursive search dialog)"},
	{"Ctrl+R",        "Open find-and-replace (live preview)"},
	{"Ctrl+Shift+R",  "Replace in files (recursive, on-disk)"},
	{"Tab",           "In replace: swap between Find and Replace inputs"},
	{"Enter",         "In replace: commit the replacement"},
	{"Esc",           "In replace: cancel and revert"},
	{"Ctrl+Z",        "Undo a committed replace in one step"},
}

@(private="file")
other_items := [?]HelpItem{
	{"F1",            "Toggle this help"},
	{"F2",            "Open file browser"},
	{"F3",            "Open git history for the active file"},
	{"F3",            "In file browser: toggle flat (recursive) view"},
	{"F4",            "Switch to another open document in the active pane"},
	{"Ctrl+F4",       "Close active doc (or kill active terminal in terminal pane)"},
	{"F5",            "Render markdown preview in the opposite pane"},
	{"F6",            "Open symbol picker (jump to function / type / etc.)"},
	{"F7",            "Open the Tasks dialog (build profiles + debug launches)"},
	{"Shift+F7",      "Toggle the debugger panel + output pane (treated as one unit)"},
	{"F10",           "Debug: step over (no-op when no session is running)"},
	{"F11",           "Debug: step into"},
	{"Shift+gutter",  "Set or edit a conditional breakpoint on the clicked line"},
	{"Mouse drag",    "In the Debug Output pane: select text"},
	{"Ctrl+C",        "In the Debug Output pane: copy selection to clipboard"},
	{"Ctrl+A",        "In the Debug Output pane: select all"},
	{"Esc",           "In the Debug Output pane: clear the current selection"},
	{"Ctrl+P",        "In file browser: set current directory as project root"},
	{"Ctrl+R",        "In file browser: rename the highlighted entry"},
	{"Ctrl+N",        "In file browser: create a new empty file"},
	{"Ctrl+Z",        "In file browser: undo the last rename / create"},
	{"F8",            "Toggle side-by-side diff mode (requires split)"},
	{"F9",            "Show/hide active terminal (creates one if none exist)"},
	{"Ctrl+F9",       "Spawn a new terminal session and make it active"},
	{"Ctrl+Shift+F9", "Open the terminal-session picker"},
	{"Ctrl+K",        "LSP: show hover info at cursor (in supported languages)"},
	{"Ctrl+Space",    "LSP: trigger completion at cursor"},
	{"Wheel / PgUp/Dn", "In terminal pane: scroll through scrollback"},
	{"Mouse drag",    "In terminal pane: select text"},
	{"Ctrl+Shift+C",  "In terminal pane: copy selection to clipboard"},
	{"Ctrl+Shift+V",  "In terminal pane: paste clipboard into the shell"},
	{"Shift+Enter",   "In file browser: open file in second pane (split)"},
	{"Ctrl+Tab",      "Swap focus between split panes"},
	{"Ctrl+Left/Right",       "Focus the left / right pane (opens split if needed)"},
	{"Ctrl+Shift+Left/Right", "Move the active document to the left / right pane"},
	{"Mouse click",   "Click in a pane to focus it"},
	{"Esc",           "Close dialog / find bar"},
	{"Ctrl+Q",        "Quit"},
}

@(private="file")
help_sections := [?]HelpSection{
	{title = "EDITING",    items = editing_items[:]},
	{title = "NAVIGATION", items = navigation_items[:]},
	{title = "SELECTION",  items = selection_items[:]},
	{title = "VIEW",       items = view_items[:]},
	{title = "FIND",       items = find_items[:]},
	{title = "OTHER",      items = other_items[:]},
}

// Flip the modal's visibility. Resets scroll to the top when *opening* so
// the user always sees the intro line, never a mid-section landing. Always
// returns true — every toggle changes what's drawn.
toggle :: proc(state: ^State) -> (needs_redraw: bool) {
	if !state.visible { state.scroll = 0 }
	state.visible = !state.visible
	return true
}

// Hide the modal. No-op (and no repaint) when it's already hidden.
close :: proc(state: ^State) -> (needs_redraw: bool) {
	if !state.visible { return false }
	state.visible = false
	return true
}

scroll_by :: proc(state: ^State, scroll_delta: i32) {
	state.scroll += scroll_delta
	// `render` clamps the upper bound each frame; only lower-bound clamp here.
	if state.scroll < 0 { state.scroll = 0 }
}

scroll_to_top    :: proc(state: ^State) { state.scroll = 0 }
// Sentinel — render clamps to the real max so we don't have to recompute
// content height here just to position the bottom.
scroll_to_bottom :: proc(state: ^State) { state.scroll = 1 << 30 }

// Mouse handlers. Each returns `needs_redraw=true` when the visible state
// changed, so the host can decide whether to mark the next frame dirty.
//
// Plain hover updates are reported as needing a redraw so the scrollbar
// thumb's highlight feedback animates promptly — same contract the editor's
// in-package scrollbar handlers used to satisfy via `editor_mark_dirty`.

handle_mouse_motion :: proc(state: ^State, mouse_x, mouse_y: f32) -> (needs_redraw: bool) {
	if state.scrollbar.is_dragging {
		apply_scrollbar_drag(state, mouse_y)
		return true
	}
	return ui.scrollbar_update_hover(&state.scrollbar, mouse_x, mouse_y)
}

handle_mouse_down :: proc(state: ^State, mouse_x, mouse_y: f32) -> (needs_redraw: bool) {
	if ui.scrollbar_thumb_hit(&state.scrollbar, mouse_x, mouse_y) {
		ui.scrollbar_begin_thumb_drag(&state.scrollbar, mouse_y)
		return false
	}
	if ui.scrollbar_track_hit(&state.scrollbar, mouse_x, mouse_y) {
		ui.scrollbar_begin_track_drag(&state.scrollbar)
		apply_scrollbar_drag(state, mouse_y)
		return true
	}
	return false
}

handle_mouse_up :: proc(state: ^State) -> (needs_redraw: bool) {
	if state.scrollbar.is_dragging {
		ui.scrollbar_end_drag(&state.scrollbar)
		return true
	}
	return false
}

// Paint the modal at the centre of the given viewport. Caller must verify
// `state.visible` first; this proc does no visibility check so it can be
// composed against test harnesses or screenshot tooling without the modal
// state having to be open.
render :: proc(state: ^State, ui_context: ^ui.Context, viewport_width, viewport_height: i32) {
	theme := ui.default_theme()

	// Dim everything behind the dialog.
	ui.draw_dim_overlay(ui_context, viewport_width, viewport_height, theme.overlay)

	// Size the dialog from font metrics, then clamp to viewport.
	desired_columns: i32 = 56
	desired_rows: i32 = 34
	dialog_width  := min(desired_columns * ui_context.character_width + 32, viewport_width  - 40)
	dialog_height := min(desired_rows * ui_context.line_height + 40, viewport_height - 40)
	if dialog_width  < 200 { dialog_width  = min(viewport_width  - 16, 200) }
	if dialog_height < 200 { dialog_height = min(viewport_height - 16, 200) }
	dialog_x := (viewport_width  - dialog_width)  / 2
	dialog_y := (viewport_height - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_width), f32(dialog_height)}

	content_rectangle := ui.draw_window(ui_context, dialog_rectangle, "Help — odit", theme)

	line_step := ui_context.line_height

	// Carve out a footer strip at the bottom of the dialog; everything above
	// it is the scrollable viewport.
	footer_reservation_height: f32 = f32(line_step) + 18
	viewport_rectangle := sdl3.FRect{
		x = content_rectangle.x,
		y = content_rectangle.y,
		w = content_rectangle.w - 12, // leave room for the scrollbar on the right
		h = (dialog_rectangle.y + dialog_rectangle.h - footer_reservation_height) - content_rectangle.y,
	}
	if viewport_rectangle.h < f32(line_step) { viewport_rectangle.h = f32(line_step) }

	total_content_height := content_height(line_step)

	origin_x, origin_y, scroll_view := ui.scroll_view_begin(ui_context, &state.scrollbar, viewport_rectangle, &state.scroll, total_content_height)

	ui.draw_text(ui_context, "Welcome to odit — a terminal-inspired text editor.", origin_x, origin_y, theme.text_foreground)
	origin_y += line_step
	ui.draw_text(ui_context, "Every shortcut currently wired up is listed below.", origin_x, origin_y, theme.dim_foreground)
	origin_y += line_step + 6

	ui.draw_hrule(ui_context, origin_x, origin_y, i32(viewport_rectangle.w), theme.border)
	origin_y += 8

	keybinding_column_x  := origin_x + 2 * ui_context.character_width
	description_column_x := origin_x + 18 * ui_context.character_width

	for section, section_index in help_sections {
		if section_index > 0 { origin_y += line_step / 2 }
		ui.draw_text(ui_context, section.title, origin_x, origin_y, theme.accent_foreground)
		origin_y += line_step + 2

		for help_item in section.items {
			ui.draw_text(ui_context, help_item.keybinding,  keybinding_column_x,  origin_y, theme.title_foreground)
			ui.draw_text(ui_context, help_item.description, description_column_x, origin_y, theme.text_foreground)
			origin_y += line_step
		}
	}

	ui.scroll_view_end(scroll_view, theme)

	// Footer hint, anchored to the bottom of the dialog (outside the viewport).
	footer_text := "Press F1 or Esc to close"
	footer_width, _ := ui.text_size(ui_context, footer_text)
	footer_x := i32(dialog_rectangle.x + (dialog_rectangle.w - f32(footer_width)) / 2)
	footer_y := i32(dialog_rectangle.y + dialog_rectangle.h) - line_step - 10
	ui.draw_text(ui_context, footer_text, footer_x, footer_y, theme.dim_foreground)
}

// Total pixel height of the help content laid out at `line_step`. Mirrors
// the layout in `render` exactly so scroll clamping and the scrollbar
// thumb stay in sync with what's actually drawn.
@(private="file")
content_height :: proc(line_step: i32) -> i32 {
	accumulated_height: i32 = 0
	accumulated_height += line_step           // intro line 1
	accumulated_height += line_step + 6       // intro line 2 + gap
	accumulated_height += 8                   // hrule + gap

	for section, section_index in help_sections {
		if section_index > 0 { accumulated_height += line_step / 2 }
		accumulated_height += line_step + 2  // section header
		accumulated_height += i32(len(section.items)) * line_step
	}
	return accumulated_height
}

// Recover content height from the last-rendered track/thumb ratio so we
// don't have to re-run `content_height` here — track/thumb were sized
// from it on the previous frame, and the inverse gives us the original.
@(private="file")
apply_scrollbar_drag :: proc(state: ^State, mouse_y: f32) {
	track := state.scrollbar.track_rectangle
	thumb := state.scrollbar.thumb_rectangle
	if track.h <= 0 || thumb.h <= 0 { return }
	max_height := track.h * track.h / thumb.h
	max_scroll := max_height - track.h
	if max_scroll < 0 { max_scroll = 0 }
	new_scroll := ui.scrollbar_drag_to(&state.scrollbar, mouse_y, max_scroll)
	state.scroll = i32(new_scroll)
}
