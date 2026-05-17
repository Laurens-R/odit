package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "vendor:sdl3"

import "../ui"

// --- Types -----------------------------------------------------------------

@(private)
BrowsePromptKind :: enum {
	None,
	Rename,
	NewFile,
}

@(private)
BrowsePromptFocus :: enum {
	Input,
	Primary,
	Cancel,
}

// Owns the editable text buffer and tracks which widget is currently focused.
// `target` is the original entry name when renaming (for the prompt text and
// for building the old-path side of the rename); empty for NewFile.
// The three `*_rect` fields are filled in by the renderer each frame so the
// event handler can mouse hit-test against the actually-drawn geometry.
@(private)
BrowsePrompt :: struct {
	kind:         BrowsePromptKind,
	value:        [dynamic]u8,
	focus:        BrowsePromptFocus,
	target:       string, // owned; original entry name for rename

	input_rect:   sdl3.FRect,
	primary_rect: sdl3.FRect,
	cancel_rect:  sdl3.FRect,
}

// One reversible file-system change. `a` and `b` are owned strings.
@(private)
BrowseUndoOp :: enum {
	Rename, // a = old absolute path, b = new absolute path
	Create, // a = created absolute path (b unused)
}

@(private)
BrowseUndoEntry :: struct {
	op: BrowseUndoOp,
	a:  string,
	b:  string,
}

// --- Lifecycle -------------------------------------------------------------

@(private)
browse_prompt_active :: proc(ed: ^Editor) -> bool {
	return ed.browse.prompt.kind != .None
}

@(private)
browse_prompt_destroy :: proc(p: ^BrowsePrompt) {
	delete(p.value)
	if len(p.target) > 0 { delete(p.target) }
	p^ = BrowsePrompt{}
}

@(private)
browse_undo_stack_destroy :: proc(stack: ^[dynamic]BrowseUndoEntry) {
	for e in stack {
		if len(e.a) > 0 { delete(e.a) }
		if len(e.b) > 0 { delete(e.b) }
	}
	delete(stack^)
	stack^ = nil
}

@(private)
browse_prompt_close :: proc(ed: ^Editor) {
	ed.browse.prompt.kind = .None
	clear(&ed.browse.prompt.value)
	if len(ed.browse.prompt.target) > 0 {
		delete(ed.browse.prompt.target)
		ed.browse.prompt.target = ""
	}
}

// --- Open helpers ----------------------------------------------------------

@(private="file")
browse_current_entry :: proc(ed: ^Editor) -> ^BrowseEntry {
	if ed.browse.selected < 0 || ed.browse.selected >= len(ed.browse.filtered_idx) { return nil }
	idx := ed.browse.filtered_idx[ed.browse.selected]
	if idx < 0 || idx >= len(ed.browse.entries) { return nil }
	return &ed.browse.entries[idx]
}

@(private)
browse_prompt_open_rename :: proc(ed: ^Editor) {
	e := browse_current_entry(ed)
	if e == nil { return }
	if e.name == ".." { return } // not a valid rename target

	p := &ed.browse.prompt
	if len(p.target) > 0 { delete(p.target) }
	p.target = strings.clone(e.name)

	clear(&p.value)
	for b in transmute([]u8)e.name { append(&p.value, b) }

	p.kind  = .Rename
	p.focus = .Input
}

@(private)
browse_prompt_open_new_file :: proc(ed: ^Editor) {
	p := &ed.browse.prompt
	if len(p.target) > 0 {
		delete(p.target)
		p.target = ""
	}
	clear(&p.value)
	p.kind  = .NewFile
	p.focus = .Input
}

// --- Focus / text editing --------------------------------------------------

@(private="file")
prompt_focus_next :: proc(p: ^BrowsePrompt) {
	switch p.focus {
	case .Input:   p.focus = .Primary
	case .Primary: p.focus = .Cancel
	case .Cancel:  p.focus = .Input
	}
}

@(private="file")
prompt_focus_prev :: proc(p: ^BrowsePrompt) {
	switch p.focus {
	case .Input:   p.focus = .Cancel
	case .Primary: p.focus = .Input
	case .Cancel:  p.focus = .Primary
	}
}

@(private="file")
prompt_value_append :: proc(p: ^BrowsePrompt, text: string) {
	for b in transmute([]u8)text {
		append(&p.value, b)
	}
}

@(private="file")
prompt_value_backspace :: proc(p: ^BrowsePrompt) {
	n := len(p.value)
	if n == 0 { return }
	i := n - 1
	for i > 0 && (p.value[i] & 0xC0) == 0x80 { i -= 1 }
	resize(&p.value, i)
}

// --- Actions ---------------------------------------------------------------

@(private="file")
prompt_execute :: proc(ed: ^Editor) {
	p := &ed.browse.prompt

	new_name := strings.trim_space(string(p.value[:]))
	if len(new_name) == 0 { return }

	switch p.kind {
	case .Rename:
		browse_do_rename(ed, p.target, new_name)
	case .NewFile:
		browse_do_create_file(ed, new_name)
	case .None:
	}
}

@(private="file")
browse_do_rename :: proc(ed: ^Editor, old_name, new_name: string) {
	if old_name == new_name {
		browse_prompt_close(ed)
		return
	}

	parts_old := [2]string{ed.browse.cwd, old_name}
	parts_new := [2]string{ed.browse.cwd, new_name}
	old_path, _ := filepath.join(parts_old[:], context.temp_allocator)
	new_path, _ := filepath.join(parts_new[:], context.temp_allocator)

	err := os.rename(old_path, new_path)
	if err != nil {
		browse_set_error(ed, fmt.tprintf("Cannot rename: %v", err))
		return
	}

	append(&ed.browse.undo_stack, BrowseUndoEntry{
		op = .Rename,
		a  = strings.clone(old_path),
		b  = strings.clone(new_path),
	})

	browse_prompt_close(ed)

	reload_path := strings.clone(ed.browse.cwd, context.temp_allocator)
	browse_load_directory(ed, reload_path)
}

@(private="file")
browse_do_create_file :: proc(ed: ^Editor, name: string) {
	parts := [2]string{ed.browse.cwd, name}
	new_path, _ := filepath.join(parts[:], context.temp_allocator)

	// `write_entire_file` creates the file (or truncates if it exists). For
	// "new file", we want to refuse to clobber an existing one.
	if existing, ferr := os.open(new_path); ferr == nil {
		os.close(existing)
		browse_set_error(ed, fmt.tprintf("File already exists: %s", name))
		return
	}

	if err := os.write_entire_file(new_path, []byte{}); err != nil {
		browse_set_error(ed, fmt.tprintf("Cannot create file: %v", err))
		return
	}

	append(&ed.browse.undo_stack, BrowseUndoEntry{
		op = .Create,
		a  = strings.clone(new_path),
		b  = "",
	})

	browse_prompt_close(ed)

	reload_path := strings.clone(ed.browse.cwd, context.temp_allocator)
	browse_load_directory(ed, reload_path)
}

// Reverse the most recent file-system change. Triggered by Ctrl+Z while the
// browser is open and no prompt is active.
@(private)
browse_undo :: proc(ed: ^Editor) {
	n := len(ed.browse.undo_stack)
	if n == 0 { return }

	entry := ed.browse.undo_stack[n - 1]
	resize(&ed.browse.undo_stack, n - 1)

	defer {
		if len(entry.a) > 0 { delete(entry.a) }
		if len(entry.b) > 0 { delete(entry.b) }
	}

	switch entry.op {
	case .Rename:
		if err := os.rename(entry.b, entry.a); err != nil {
			browse_set_error(ed, fmt.tprintf("Cannot undo rename: %v", err))
			return
		}
	case .Create:
		if err := os.remove(entry.a); err != nil {
			browse_set_error(ed, fmt.tprintf("Cannot undo create: %v", err))
			return
		}
	}

	reload_path := strings.clone(ed.browse.cwd, context.temp_allocator)
	browse_load_directory(ed, reload_path)
}

// --- Event handling --------------------------------------------------------

@(private)
browse_prompt_handle_event :: proc(ed: ^Editor, event: ^sdl3.Event) {
	p := &ed.browse.prompt

	#partial switch event.type {
	case .TEXT_INPUT:
		if p.focus == .Input {
			input_text := string(event.text.text)
			if len(input_text) > 0 { prompt_value_append(p, input_text) }
		}

	case .KEY_DOWN:
		key   := event.key.key
		mod   := event.key.mod
		shift := .LSHIFT in mod || .RSHIFT in mod

		switch key {
		case sdl3.K_ESCAPE:
			browse_prompt_close(ed)
		case sdl3.K_TAB:
			if shift { prompt_focus_prev(p) } else { prompt_focus_next(p) }
		case sdl3.K_RETURN:
			switch p.focus {
			case .Input, .Primary: prompt_execute(ed)
			case .Cancel:          browse_prompt_close(ed)
			}
		case sdl3.K_BACKSPACE:
			if p.focus == .Input { prompt_value_backspace(p) }
		}

	case .MOUSE_BUTTON_DOWN:
		if event.button.button == sdl3.BUTTON_LEFT {
			x, y := event.button.x, event.button.y
			switch {
			case ui.point_in_rect(p.input_rect, x, y):
				p.focus = .Input
			case ui.point_in_rect(p.primary_rect, x, y):
				p.focus = .Primary
				prompt_execute(ed)
			case ui.point_in_rect(p.cancel_rect, x, y):
				p.focus = .Cancel
				browse_prompt_close(ed)
			}
		}
	}
}

// --- Rendering -------------------------------------------------------------

@(private)
browse_prompt_render :: proc(ed: ^Editor, renderer: ^sdl3.Renderer, width, height: i32) {
	p := &ed.browse.prompt
	if p.kind == .None { return }

	ctx := ui.Context{
		renderer    = renderer,
		font        = ed.font,
		engine      = ed.engine,
		char_width  = ed.char_width,
		line_height = ed.line_height,
	}
	theme := ui.default_theme()

	// Extra dim layer over the browse modal so the prompt visually dominates.
	ui.draw_dim_overlay(&ctx, width, height, theme.overlay)

	// Popup sizing (in character cells + small pixel padding).
	pw := min(50 * ed.char_width + 32, width  - 80)
	ph := min(8  * ed.line_height + 40, height - 80)
	if pw < 240 { pw = min(width  - 16, 240) }
	if ph < 160 { ph = min(height - 16, 160) }
	px := (width  - pw) / 2
	py := (height - ph) / 2
	popup_rect := sdl3.FRect{f32(px), f32(py), f32(pw), f32(ph)}

	title := p.kind == .Rename ? "Rename" : "New File"
	content := ui.draw_window(&ctx, popup_rect, title, theme)

	line_step := ed.line_height
	cx := i32(content.x)
	cy := i32(content.y)
	cw := i32(content.w)

	// Prompt headline
	headline: string
	switch p.kind {
	case .Rename:  headline = fmt.tprintf("Rename \"%s\" to:", p.target)
	case .NewFile: headline = "New file name:"
	case .None:    return
	}
	ui.draw_text(&ctx, headline, cx, cy, theme.text_fg)
	cy += line_step + 6

	// Editable input field
	p.input_rect = sdl3.FRect{f32(cx), f32(cy), f32(cw), f32(line_step + 4)}
	value_str := string(p.value[:])
	ui.draw_input_field(&ctx, cx, cy, cw, "", value_str, theme, p.focus == .Input)
	cy += line_step + 16

	// Buttons row anchored to the popup's bottom edge.
	btn_w: i32 = 14 * ed.char_width
	btn_h: i32 = line_step + 12
	btn_gap: i32 = 8
	total_btn_w := btn_w * 2 + btn_gap
	btn_start_x := cx + (cw - total_btn_w) / 2
	btn_y := i32(popup_rect.y + popup_rect.h) - btn_h - 12

	primary_label := p.kind == .Rename ? "Rename" : "Create"

	p.primary_rect = sdl3.FRect{f32(btn_start_x),                       f32(btn_y), f32(btn_w), f32(btn_h)}
	p.cancel_rect  = sdl3.FRect{f32(btn_start_x + btn_w + btn_gap),     f32(btn_y), f32(btn_w), f32(btn_h)}

	ui.draw_button(&ctx, p.primary_rect, primary_label, p.focus == .Primary, theme)
	ui.draw_button(&ctx, p.cancel_rect,  "Cancel",      p.focus == .Cancel,  theme)
}
