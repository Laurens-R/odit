package editor

import "vendor:sdl3"

import "../ui"

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

// Section content is stored as package-scope fixed arrays so that slicing them
// into HelpSection.items references stable memory rather than a stack frame.

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

@(private)
help_toggle :: proc(editor: ^Editor) {
	if !editor.show_help {
		editor.help_scroll = 0
	}
	editor.show_help = !editor.show_help
}

@(private)
help_close :: proc(editor: ^Editor) {
	editor.show_help = false
}

@(private)
help_render :: proc(editor: ^Editor, renderer: ^sdl3.Renderer, viewport_width, viewport_height: i32) {
	ui_context := ui.Context{
		renderer        = renderer,
		font            = editor.font,
		engine          = editor.text_engine,
		character_width = editor.character_width,
		line_height     = editor.line_height,
	}
	theme := ui.default_theme()

	// Dim everything behind the dialog.
	ui.draw_dim_overlay(&ui_context, viewport_width, viewport_height, theme.overlay)

	// Size the dialog from font metrics, then clamp to viewport.
	desired_columns: i32 = 56
	desired_rows: i32 = 34
	dialog_width  := min(desired_columns * editor.character_width + 32, viewport_width  - 40)
	dialog_height := min(desired_rows * editor.line_height + 40, viewport_height - 40)
	if dialog_width  < 200 { dialog_width  = min(viewport_width  - 16, 200) }
	if dialog_height < 200 { dialog_height = min(viewport_height - 16, 200) }
	dialog_x := (viewport_width  - dialog_width)  / 2
	dialog_y := (viewport_height - dialog_height) / 2
	dialog_rectangle := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_width), f32(dialog_height)}

	content_rectangle := ui.draw_window(&ui_context, dialog_rectangle, "Help — odit", theme)

	line_step := editor.line_height

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

	total_content_height := help_content_height(line_step)

	origin_x, origin_y, scroll_view := ui.scroll_view_begin(&ui_context, viewport_rectangle, &editor.help_scroll, total_content_height)

	ui.draw_text(&ui_context, "Welcome to odit — a terminal-inspired text editor.", origin_x, origin_y, theme.text_foreground)
	origin_y += line_step
	ui.draw_text(&ui_context, "Every shortcut currently wired up is listed below.", origin_x, origin_y, theme.dim_foreground)
	origin_y += line_step + 6

	ui.draw_hrule(&ui_context, origin_x, origin_y, i32(viewport_rectangle.w), theme.border)
	origin_y += 8

	keybinding_column_x  := origin_x + 2 * editor.character_width
	description_column_x := origin_x + 18 * editor.character_width

	for section, section_index in help_sections {
		if section_index > 0 { origin_y += line_step / 2 }
		ui.draw_text(&ui_context, section.title, origin_x, origin_y, theme.accent_foreground)
		origin_y += line_step + 2

		for help_item in section.items {
			ui.draw_text(&ui_context, help_item.keybinding,  keybinding_column_x,  origin_y, theme.title_foreground)
			ui.draw_text(&ui_context, help_item.description, description_column_x, origin_y, theme.text_foreground)
			origin_y += line_step
		}
	}

	ui.scroll_view_end(scroll_view, theme)

	// Footer hint, anchored to the bottom of the dialog (outside the viewport).
	footer_text := "Press F1 or Esc to close"
	footer_width, _ := ui.text_size(&ui_context, footer_text)
	footer_x := i32(dialog_rectangle.x + (dialog_rectangle.w - f32(footer_width)) / 2)
	footer_y := i32(dialog_rectangle.y + dialog_rectangle.h) - line_step - 10
	ui.draw_text(&ui_context, footer_text, footer_x, footer_y, theme.dim_foreground)
}

// Compute the total pixel height of the help content laid out at `line_step`.
// Mirrors the layout in `help_render` exactly so scroll clamping and the
// scrollbar thumb stay in sync with what's actually drawn.
@(private="file")
help_content_height :: proc(line_step: i32) -> i32 {
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

@(private)
help_scroll_by :: proc(editor: ^Editor, scroll_delta: i32) {
	editor.help_scroll += scroll_delta
	// Render clamps to the valid range each frame; no need to compute max here.
	if editor.help_scroll < 0 { editor.help_scroll = 0 }
}

@(private)
help_scroll_to_top :: proc(editor: ^Editor) {
	editor.help_scroll = 0
}

@(private)
help_scroll_to_bottom :: proc(editor: ^Editor) {
	// Use a sentinel large value; render clamps to the actual max.
	editor.help_scroll = 1 << 30
}
