package editor

import "vendor:sdl3"

import "../ui"

@(private="file")
HelpItem :: struct {
	key:  string,
	desc: string,
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
other_items := [?]HelpItem{
	{"F1",            "Toggle this help"},
	{"F2",            "Open file browser"},
	{"F3",            "In file browser: toggle flat (recursive) view"},
	{"F6",            "Open symbol picker (jump to function / type / etc.)"},
	{"Ctrl+R",        "In file browser: rename the highlighted entry"},
	{"Ctrl+N",        "In file browser: create a new empty file"},
	{"Ctrl+Z",        "In file browser: undo the last rename / create"},
	{"F8",            "Toggle side-by-side diff mode (requires split)"},
	{"Shift+Enter",   "In file browser: open file in second pane (split)"},
	{"Ctrl+Tab",      "Swap focus between split panes"},
	{"Mouse click",   "Click in a pane to focus it"},
	{"Esc",           "Close dialog / quit when no dialog open"},
}

@(private="file")
help_sections := [?]HelpSection{
	{title = "EDITING",    items = editing_items[:]},
	{title = "NAVIGATION", items = navigation_items[:]},
	{title = "SELECTION",  items = selection_items[:]},
	{title = "VIEW",       items = view_items[:]},
	{title = "OTHER",      items = other_items[:]},
}

@(private)
help_toggle :: proc(ed: ^Editor) {
	if !ed.show_help {
		ed.help_scroll = 0
	}
	ed.show_help = !ed.show_help
}

@(private)
help_close :: proc(ed: ^Editor) {
	ed.show_help = false
}

@(private)
help_render :: proc(ed: ^Editor, renderer: ^sdl3.Renderer, width, height: i32) {
	ctx := ui.Context{
		renderer    = renderer,
		font        = ed.font,
		engine      = ed.engine,
		char_width  = ed.char_width,
		line_height = ed.line_height,
	}
	theme := ui.default_theme()

	// Dim everything behind the dialog.
	ui.draw_dim_overlay(&ctx, width, height, theme.overlay)

	// Size the dialog from font metrics, then clamp to viewport.
	want_cols: i32 = 56
	want_rows: i32 = 34
	dialog_w := min(want_cols * ed.char_width + 32, width  - 40)
	dialog_h := min(want_rows * ed.line_height + 40, height - 40)
	if dialog_w < 200 { dialog_w = min(width  - 16, 200) }
	if dialog_h < 200 { dialog_h = min(height - 16, 200) }
	dialog_x := (width  - dialog_w) / 2
	dialog_y := (height - dialog_h) / 2
	dialog_rect := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_w), f32(dialog_h)}

	content := ui.draw_window(&ctx, dialog_rect, "Help — odit", theme)

	line_step := ed.line_height

	// Carve out a footer strip at the bottom of the dialog; everything above
	// it is the scrollable viewport.
	footer_reserve: f32 = f32(line_step) + 18
	viewport := sdl3.FRect{
		x = content.x,
		y = content.y,
		w = content.w - 12, // leave room for the scrollbar on the right
		h = (dialog_rect.y + dialog_rect.h - footer_reserve) - content.y,
	}
	if viewport.h < f32(line_step) { viewport.h = f32(line_step) }

	content_height := help_content_height(line_step)

	x, y, sv := ui.scroll_view_begin(&ctx, viewport, &ed.help_scroll, content_height)

	ui.draw_text(&ctx, "Welcome to odit — a terminal-inspired text editor.", x, y, theme.text_fg)
	y += line_step
	ui.draw_text(&ctx, "Every shortcut currently wired up is listed below.", x, y, theme.dim_fg)
	y += line_step + 6

	ui.draw_hrule(&ctx, x, y, i32(viewport.w), theme.border)
	y += 8

	key_col_x  := x + 2 * ed.char_width
	desc_col_x := x + 18 * ed.char_width

	for section, i in help_sections {
		if i > 0 { y += line_step / 2 }
		ui.draw_text(&ctx, section.title, x, y, theme.accent_fg)
		y += line_step + 2

		for item in section.items {
			ui.draw_text(&ctx, item.key,  key_col_x,  y, theme.title_fg)
			ui.draw_text(&ctx, item.desc, desc_col_x, y, theme.text_fg)
			y += line_step
		}
	}

	ui.scroll_view_end(sv, theme)

	// Footer hint, anchored to the bottom of the dialog (outside the viewport).
	footer := "Press F1 or Esc to close"
	fw, _ := ui.text_size(&ctx, footer)
	foot_x := i32(dialog_rect.x + (dialog_rect.w - f32(fw)) / 2)
	foot_y := i32(dialog_rect.y + dialog_rect.h) - line_step - 10
	ui.draw_text(&ctx, footer, foot_x, foot_y, theme.dim_fg)
}

// Compute the total pixel height of the help content laid out at `line_step`.
// Mirrors the layout in `help_render` exactly so scroll clamping and the
// scrollbar thumb stay in sync with what's actually drawn.
@(private="file")
help_content_height :: proc(line_step: i32) -> i32 {
	h: i32 = 0
	h += line_step           // intro line 1
	h += line_step + 6       // intro line 2 + gap
	h += 8                   // hrule + gap

	for section, i in help_sections {
		if i > 0 { h += line_step / 2 }
		h += line_step + 2  // section header
		h += i32(len(section.items)) * line_step
	}
	return h
}

@(private)
help_scroll_by :: proc(ed: ^Editor, delta: i32) {
	ed.help_scroll += delta
	// Render clamps to the valid range each frame; no need to compute max here.
	if ed.help_scroll < 0 { ed.help_scroll = 0 }
}

@(private)
help_scroll_to_top :: proc(ed: ^Editor) {
	ed.help_scroll = 0
}

@(private)
help_scroll_to_bottom :: proc(ed: ^Editor) {
	// Use a sentinel large value; render clamps to the actual max.
	ed.help_scroll = 1 << 30
}
