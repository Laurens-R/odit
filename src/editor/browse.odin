package editor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "vendor:sdl3"

import "../ui"

@(private)
BrowseEntry :: struct {
	name:   string, // owned
	is_dir: bool,
}

@(private)
BrowseState :: struct {
	cwd:          string, // owned
	entries:      [dynamic]BrowseEntry,
	filtered_idx: [dynamic]int,
	filter:       [dynamic]u8,
	selected:     int, // index into filtered_idx
	scroll:       int, // first visible row in filtered list
	visible_rows: int, // set during render
	error_msg:    string, // owned; "" when no error
}

// --- Lifecycle ---

@(private)
browse_state_destroy :: proc(ed: ^Editor) {
	for entry in ed.browse.entries {
		delete(entry.name)
	}
	delete(ed.browse.entries)
	delete(ed.browse.filtered_idx)
	delete(ed.browse.filter)
	if len(ed.browse.cwd) > 0 {
		delete(ed.browse.cwd)
		ed.browse.cwd = ""
	}
	if len(ed.browse.error_msg) > 0 {
		delete(ed.browse.error_msg)
		ed.browse.error_msg = ""
	}
}

@(private)
browse_open :: proc(ed: ^Editor) {
	if ed.show_browse { return }

	start_path: string
	if len(ed.browse.cwd) > 0 {
		// Use a temp clone because browse_load_directory frees ed.browse.cwd before
		// taking ownership of its argument.
		start_path = strings.clone(ed.browse.cwd, context.temp_allocator)
	} else {
		wd, err := os.get_working_directory(context.temp_allocator)
		if err != nil {
			start_path = "."
		} else {
			start_path = wd
		}
	}

	ed.show_browse = true
	browse_load_directory(ed, start_path)
}

@(private)
browse_close :: proc(ed: ^Editor) {
	ed.show_browse = false
}

// --- Directory loading ---

@(private="file")
browse_set_error :: proc(ed: ^Editor, msg: string) {
	if len(ed.browse.error_msg) > 0 {
		delete(ed.browse.error_msg)
	}
	ed.browse.error_msg = strings.clone(msg)
}

@(private="file")
browse_clear_error :: proc(ed: ^Editor) {
	if len(ed.browse.error_msg) > 0 {
		delete(ed.browse.error_msg)
		ed.browse.error_msg = ""
	}
}

@(private="file")
entry_less :: proc(a, b: BrowseEntry) -> bool {
	// Folders first; then alphabetical (case-sensitive — good enough for now).
	if a.is_dir != b.is_dir { return a.is_dir }
	return a.name < b.name
}

@(private)
browse_load_directory :: proc(ed: ^Editor, path: string) {
	// Replace owned entries
	for entry in ed.browse.entries {
		delete(entry.name)
	}
	clear(&ed.browse.entries)

	new_cwd := strings.clone(path)
	if len(ed.browse.cwd) > 0 {
		delete(ed.browse.cwd)
	}
	ed.browse.cwd = new_cwd

	browse_clear_error(ed)

	// Always offer ".." (a no-op at a filesystem root after filepath.clean).
	append(&ed.browse.entries, BrowseEntry{name = strings.clone(".."), is_dir = true})

	infos, err := os.read_all_directory_by_path(path, context.allocator)
	if err != nil {
		browse_set_error(ed, fmt.tprintf("Cannot read directory: %v", err))
	} else {
		defer os.file_info_slice_delete(infos, context.allocator)

		// Materialize sortable entries, skipping "." and ".." entries the OS might
		// return; ours is always at index 0.
		fs_entries := make([dynamic]BrowseEntry, 0, len(infos), context.temp_allocator)
		for info in infos {
			if info.name == "." || info.name == ".." { continue }
			is_dir := info.type == .Directory
			// Skip device files, pipes, etc. — only show dirs and regular files.
			if !is_dir && info.type != .Regular && info.type != .Symlink {
				continue
			}
			append(&fs_entries, BrowseEntry{name = strings.clone(info.name), is_dir = is_dir})
		}
		slice.sort_by(fs_entries[:], entry_less)
		for entry in fs_entries {
			append(&ed.browse.entries, entry)
		}
	}

	clear(&ed.browse.filter)
	ed.browse.selected = 0
	ed.browse.scroll = 0
	browse_apply_filter(ed)
}

// --- Filtering ---

@(private)
browse_apply_filter :: proc(ed: ^Editor) {
	clear(&ed.browse.filtered_idx)

	filter_lower := strings.to_lower(string(ed.browse.filter[:]), context.temp_allocator)

	for entry, i in ed.browse.entries {
		if len(filter_lower) == 0 {
			append(&ed.browse.filtered_idx, i)
			continue
		}
		// ".." is special — always show it regardless of filter so the user can
		// always escape upward.
		if entry.name == ".." {
			append(&ed.browse.filtered_idx, i)
			continue
		}
		name_lower := strings.to_lower(entry.name, context.temp_allocator)
		if strings.contains(name_lower, filter_lower) {
			append(&ed.browse.filtered_idx, i)
		}
	}

	// Clamp selection
	n := len(ed.browse.filtered_idx)
	if n == 0 {
		ed.browse.selected = 0
	} else if ed.browse.selected >= n {
		ed.browse.selected = n - 1
	}
	if ed.browse.selected < 0 { ed.browse.selected = 0 }
}

@(private="file")
browse_filter_append :: proc(ed: ^Editor, text: string) {
	for b in transmute([]u8)text {
		append(&ed.browse.filter, b)
	}
	browse_apply_filter(ed)
}

@(private="file")
browse_filter_backspace :: proc(ed: ^Editor) {
	n := len(ed.browse.filter)
	if n == 0 { return }
	i := n - 1
	// Walk back over UTF-8 continuation bytes
	for i > 0 && (ed.browse.filter[i] & 0xC0) == 0x80 {
		i -= 1
	}
	resize(&ed.browse.filter, i)
	browse_apply_filter(ed)
}

// --- Navigation ---

@(private="file")
browse_move_selection :: proc(ed: ^Editor, delta: int) {
	n := len(ed.browse.filtered_idx)
	if n == 0 { return }
	new_sel := ed.browse.selected + delta
	if new_sel < 0 { new_sel = 0 }
	if new_sel >= n { new_sel = n - 1 }
	ed.browse.selected = new_sel
}

// Maximum file size we'll load into the editor. Anything larger is rejected
// up-front rather than handed to the piece tree (which would otherwise try to
// allocate the entire file in its source buffer).
@(private="file")
MAX_FILE_BYTES :: 256 * 1024 * 1024 // 256 MiB

@(private="file")
browse_activate :: proc(ed: ^Editor) {
	n := len(ed.browse.filtered_idx)
	if n == 0 { return }
	if ed.browse.selected < 0 || ed.browse.selected >= n { return }

	idx := ed.browse.filtered_idx[ed.browse.selected]
	entry := ed.browse.entries[idx]

	parts := [2]string{ed.browse.cwd, entry.name}
	joined, _ := filepath.join(parts[:], context.temp_allocator)
	full_path, _ := filepath.clean(joined, context.temp_allocator)

	if entry.is_dir {
		browse_load_directory(ed, full_path)
		return
	}

	data, err := os.read_entire_file_from_path(full_path, context.allocator)
	if err != nil {
		browse_set_error(ed, fmt.tprintf("Cannot open %s: %v", entry.name, err))
		return
	}
	defer delete(data)

	if len(data) < 0 || len(data) > MAX_FILE_BYTES {
		browse_set_error(ed, fmt.tprintf("File %s is too large (%d bytes)", entry.name, len(data)))
		return
	}

	// Clone the bytes into a freshly-allocated string right here at the source.
	// From this point on, `content` is a normal, well-formed string that can be
	// passed through proc boundaries like any other.
	content := strings.clone(string(data))
	defer delete(content)

	editor_open_string(ed, content)
	browse_close(ed)
}

// --- Input ---

@(private)
browse_handle_event :: proc(ed: ^Editor, event: ^sdl3.Event) {
	#partial switch event.type {
	case .TEXT_INPUT:
		input_text := string(event.text.text)
		if len(input_text) > 0 {
			browse_filter_append(ed, input_text)
		}

	case .KEY_DOWN:
		key := event.key.key
		switch key {
		case sdl3.K_ESCAPE, sdl3.K_F2:
			browse_close(ed)
		case sdl3.K_UP:
			browse_move_selection(ed, -1)
		case sdl3.K_DOWN:
			browse_move_selection(ed, 1)
		case sdl3.K_PAGEUP:
			step := ed.browse.visible_rows
			if step < 1 { step = 1 }
			browse_move_selection(ed, -step)
		case sdl3.K_PAGEDOWN:
			step := ed.browse.visible_rows
			if step < 1 { step = 1 }
			browse_move_selection(ed, step)
		case sdl3.K_HOME:
			browse_move_selection(ed, -len(ed.browse.filtered_idx))
		case sdl3.K_END:
			browse_move_selection(ed, len(ed.browse.filtered_idx))
		case sdl3.K_RETURN:
			browse_activate(ed)
		case sdl3.K_BACKSPACE:
			browse_filter_backspace(ed)
		}
	}
}

// --- Rendering ---

@(private)
browse_render :: proc(ed: ^Editor, renderer: ^sdl3.Renderer, width, height: i32) {
	ctx := ui.Context{
		renderer    = renderer,
		font        = ed.font,
		engine      = ed.engine,
		char_width  = ed.char_width,
		line_height = ed.line_height,
	}
	theme := ui.default_theme()

	ui.draw_dim_overlay(&ctx, width, height, theme.overlay)

	// Dialog rect
	want_cols: i32 = 64
	want_rows: i32 = 28
	dialog_w := min(want_cols * ed.char_width + 32, width  - 40)
	dialog_h := min(want_rows * ed.line_height + 40, height - 40)
	if dialog_w < 240 { dialog_w = min(width  - 16, 240) }
	if dialog_h < 240 { dialog_h = min(height - 16, 240) }
	dialog_x := (width  - dialog_w) / 2
	dialog_y := (height - dialog_h) / 2
	dialog_rect := sdl3.FRect{f32(dialog_x), f32(dialog_y), f32(dialog_w), f32(dialog_h)}

	title := fmt.tprintf("Browse — %s", ed.browse.cwd)
	content := ui.draw_window(&ctx, dialog_rect, title, theme)

	line_step := ed.line_height
	x := i32(content.x)
	y := i32(content.y)
	w := i32(content.w)

	// Filter field
	filter_str := string(ed.browse.filter[:])
	ui.draw_input_field(&ctx, x, y, w, "Filter: ", filter_str, theme)
	y += line_step + 8 // include underline gap

	// Footer reservation
	footer_height: i32 = line_step + 12
	list_top := y
	list_bottom := i32(dialog_rect.y + dialog_rect.h) - footer_height - 12

	// Reserve a line for the error message, if any.
	if len(ed.browse.error_msg) > 0 {
		list_bottom -= line_step
	}

	list_height := list_bottom - list_top
	visible_rows := int(list_height / line_step)
	if visible_rows < 1 { visible_rows = 1 }
	ed.browse.visible_rows = visible_rows

	// Adjust scroll so the selected row is in view.
	if ed.browse.selected < ed.browse.scroll {
		ed.browse.scroll = ed.browse.selected
	} else if ed.browse.selected >= ed.browse.scroll + visible_rows {
		ed.browse.scroll = ed.browse.selected - visible_rows + 1
	}
	if ed.browse.scroll < 0 { ed.browse.scroll = 0 }

	// Draw entries
	end := min(ed.browse.scroll + visible_rows, len(ed.browse.filtered_idx))
	for i := ed.browse.scroll; i < end; i += 1 {
		entry := ed.browse.entries[ed.browse.filtered_idx[i]]
		label := entry.is_dir ? fmt.tprintf("%s/", entry.name) : entry.name
		row_y := list_top + i32(i - ed.browse.scroll) * line_step
		ui.draw_list_row(&ctx, x, row_y, w, label, i == ed.browse.selected, theme)
	}

	if len(ed.browse.filtered_idx) == 0 {
		empty_msg := len(ed.browse.filter) > 0 ? "(no matches)" : "(empty)"
		ui.draw_text(&ctx, empty_msg, x + 8, list_top, theme.dim_fg)
	}

	// Error line (if any), drawn just below the list area.
	if len(ed.browse.error_msg) > 0 {
		err_y := list_bottom
		ui.draw_text(&ctx, ed.browse.error_msg, x, err_y, sdl3.FColor{0.95, 0.42, 0.42, 1.0})
	}

	// Footer hint
	hint := "Up/Down: navigate    Enter: open    Type to filter    Esc: close"
	fw, _ := ui.text_size(&ctx, hint)
	foot_x := i32(dialog_rect.x + (dialog_rect.w - f32(fw)) / 2)
	foot_y := i32(dialog_rect.y + dialog_rect.h) - line_step - 10
	ui.draw_text(&ctx, hint, foot_x, foot_y, theme.dim_fg)
}
