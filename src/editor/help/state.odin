// Package `help` is the F1 help dialog modal. Pure UI — no host
// callbacks needed: every input flips internal state and the host just
// repaints when `dispatch_event` reports a change.
//
// Structure inside this package:
//   * `state.odin` — State + the static section tables + lifecycle
//                    procs (toggle/close/scroll_*) + scrollbar drag
//                    arithmetic.
//   * `view.odin`  — `dispatch_event` (SDL event → state mutation) +
//                    `render` (layout + paint).
package help

import "../../ui"

State :: struct {
	visible:   bool,
	scroll:    i32,
	scrollbar: ui.Scrollbar,
}

@(private)
HelpItem :: struct {
	keybinding:  string,
	description: string,
}

@(private)
HelpSection :: struct {
	title: string,
	items: []HelpItem,
}

// Section content is package-scope so the slice in `HelpSection.items`
// references stable memory rather than a stack frame.

@(private)
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

@(private)
navigation_items := [?]HelpItem{
	{"Arrow keys",    "Move cursor"},
	{"Home / End",    "Jump to line start / end"},
	{"Ctrl+Home/End", "Jump to document start / end"},
	{"PageUp/Down",   "Jump one page"},
}

@(private)
selection_items := [?]HelpItem{
	{"Shift+Move",    "Extend selection with any nav key"},
	{"Mouse drag",    "Select with the mouse"},
	{"Shift+Click",   "Extend selection to click point"},
	{"Left / Right",  "Collapse selection without moving"},
}

@(private)
view_items := [?]HelpItem{
	{"Mouse wheel",   "Smooth scroll"},
	{"Ctrl+Wheel",    "Zoom font size"},
}

@(private)
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

@(private)
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

@(private)
help_sections := [?]HelpSection{
	{title = "EDITING",    items = editing_items[:]},
	{title = "NAVIGATION", items = navigation_items[:]},
	{title = "SELECTION",  items = selection_items[:]},
	{title = "VIEW",       items = view_items[:]},
	{title = "FIND",       items = find_items[:]},
	{title = "OTHER",      items = other_items[:]},
}

// --- Lifecycle -----------------------------------------------------------

// Flip the modal's visibility. Resets scroll to the top when *opening*
// so the user always sees the intro line, never a mid-section landing.
// Always returns true — every toggle changes what's drawn.
toggle :: proc(state: ^State) -> (needs_redraw: bool) {
	if !state.visible { state.scroll = 0 }
	state.visible = !state.visible
	return true
}

close :: proc(state: ^State) -> (needs_redraw: bool) {
	if !state.visible { return false }
	state.visible = false
	return true
}

@(private)
scroll_by :: proc(state: ^State, scroll_delta: i32) {
	state.scroll += scroll_delta
	// `render` clamps the upper bound each frame; only lower-bound clamp here.
	if state.scroll < 0 { state.scroll = 0 }
}

@(private) scroll_to_top    :: proc(state: ^State) { state.scroll = 0 }
// Sentinel — render clamps to the real max so we don't have to
// recompute content height here just to position the bottom.
@(private) scroll_to_bottom :: proc(state: ^State) { state.scroll = 1 << 30 }

// Recover content height from the last-rendered track/thumb ratio so we
// don't have to re-run `content_height` here — track/thumb were sized
// from it on the previous frame, and the inverse gives us the original.
@(private)
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

// Total pixel height of the help content laid out at `line_step`.
// Mirrors the layout in `render` exactly so scroll clamping and the
// scrollbar thumb stay in sync with what's actually drawn.
@(private)
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
