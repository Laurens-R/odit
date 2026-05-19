package terminal

import "core:sync"
import "core:thread"
import "vendor:sdl3"
import "vendor:sdl3/ttf"

// --- Cells, attributes, colors -------------------------------------------

CellAttributes :: distinct u16
ATTRIBUTE_BOLD      :: CellAttributes(0x01)
ATTRIBUTE_DIM       :: CellAttributes(0x02)
ATTRIBUTE_UNDERLINE :: CellAttributes(0x04)
ATTRIBUTE_REVERSE   :: CellAttributes(0x08)
ATTRIBUTE_ITALIC    :: CellAttributes(0x10)

Color :: struct {
	red, green, blue, alpha: f32,
}

Cell :: struct {
	character:        rune,
	foreground_color: Color,
	background_color: Color,
	attributes:       CellAttributes,
}

// --- Screen --------------------------------------------------------------

Screen :: struct {
	cells:                       []Cell, // row-major; len == columns * rows
	columns:                     i32,
	rows:                        i32,
	cursor_row:                  i32,
	cursor_column:               i32,
	saved_cursor_row:            i32,
	saved_cursor_column:         i32,
	current_foreground_color:    Color, // current foreground
	current_background_color:    Color, // current background
	current_attributes:          CellAttributes,
	default_foreground_color:    Color,
	default_background_color:    Color,
	scroll_region_top:           i32, // inclusive
	scroll_region_bottom:        i32, // inclusive
	cursor_visible:              bool,

	// Scrollback: rows pushed off the top of the active region by full-
	// screen scrolls. Each entry is an owned slice of `Cell` at the column
	// count active at push time — we don't re-flow on resize, the renderer
	// just clamps. Capped at SCROLLBACK_MAX_ROWS so a runaway shell can't
	// grow the heap unboundedly.
	scrollback_rows:             [dynamic][]Cell,

	// Bookkeeping so wide-char / wrap edge cases can be added later without
	// schema changes. For now this is a simple grid.
}

// --- ANSI parser ---------------------------------------------------------

ParserState :: enum u8 {
	Ground,        // normal text
	Escape,        // saw ESC, waiting for next byte
	Csi,           // saw ESC[, collecting params + intermediates
	Osc,           // saw ESC], collecting OSC payload (skipped for now)
}

Parser :: struct {
	state:               ParserState,
	parameters:          [16]i32, // CSI numeric params; -1 means "unset"
	parameter_count:     int,
	private_mark:        u8, // e.g. '?' for DEC private (ESC[?...) — 0 if none
	intermediate_byte:   u8, // a single intermediate byte (' '..'/') if present
}

// --- Terminal ------------------------------------------------------------

// Default starting grid before the editor has had a chance to compute the
// actual pixel rect.
DEFAULT_COLUMN_COUNT :: i32(80)
DEFAULT_ROW_COUNT    :: i32(24)

// Cap on bytes drained from the read queue per frame so a flood from the
// shell can't stall the UI. Excess stays in the queue for the next tick.
DRAIN_BUDGET_PER_FRAME :: 64 * 1024

// Maximum scrollback retained in memory. Each row is roughly columns *
// sizeof(Cell) bytes — at ~38 bytes/cell × 200 columns × 5000 rows that's
// about 38 MB worst case, which is the right order of magnitude for an
// embedded terminal. Older rows are evicted FIFO when this is exceeded.
SCROLLBACK_MAX_ROWS :: 5000

Terminal :: struct {
	screen: Screen,
	parser: Parser,

	// Output buffer shared with the read thread.
	output_buffer: [dynamic]u8,
	output_mutex:  sync.Mutex,

	read_thread: ^thread.Thread,

	// Platform-specific process / pty state (see process_*.odin).
	pty_state: PtyState,
	is_alive:  bool,

	// Geometry set by the editor each layout pass.
	rectangle:       sdl3.Rect,
	character_width: i32,
	line_height:     i32,

	// Cursor blink mirrors the editor's, but the terminal owns its own
	// counter so closing/reopening the pane resets the rhythm.
	cursor_visible: bool,
	cursor_timer:   f64,

	// Palette (xterm 256-color). palette[0..15] are the SGR 30-37 / 40-47
	// base colors; the rest of the indices are the standard xterm cube.
	palette: [256]Color,

	// Number of rows the viewport is scrolled up from the live screen. 0
	// means "showing the bottom" (the live cells). Bumped by the mouse
	// wheel; snapped back to 0 on any user keystroke so typing always
	// follows the prompt.
	scroll_offset: i32,

	// Text selection state — coordinates are in *virtual* row space:
	//   virtual_row in [0, len(scrollback_rows))            => scrollback row
	//   virtual_row in [len(scrollback_rows), +screen.rows) => live cells
	// Coordinates survive scrolling so a long drag through scrollback stays
	// anchored to the same source rows even as the viewport moves.
	selection: TerminalSelection,
}

// Stream selection: a contiguous span from `anchor` (inclusive) to `current`
// (exclusive of the cell beyond the last character). Wraps across rows. When
// `is_active` is false, no selection is rendered or copied.
TerminalSelection :: struct {
	is_active:      bool,
	is_dragging:    bool, // true between mouse-down and mouse-up; updates current on motion
	anchor_row:     i32,  // virtual row index
	anchor_column:  i32,
	current_row:    i32,
	current_column: i32,
}

// --- Public API ----------------------------------------------------------

// Allocate a new terminal, spin up the shell process, and start the read
// thread. Returns nil on failure (e.g. ConPTY unavailable). The caller owns
// the returned pointer and must hand it to `terminal_destroy` when done.
//
// `default_foreground` / `default_background` are the colors used for cells
// the shell hasn't explicitly colored via SGR — pass the editor's palette so
// plain shell output blends with the surrounding UI. The xterm 256-color
// palette is still initialized and used for SGR-styled cells.
//
// `working_directory` is the cwd the shell should launch in. Pass "" to
// inherit the parent process's cwd; otherwise it must be an absolute path
// (no expansion is performed here). Used by the editor to anchor the shell
// at the project root when one is set.
terminal_new :: proc(initial_rows, initial_columns: i32, default_foreground: Color, default_background: Color, working_directory: string = "") -> ^Terminal {
	resolved_rows := initial_rows;    if resolved_rows    < 4  { resolved_rows    = DEFAULT_ROW_COUNT }
	resolved_columns := initial_columns; if resolved_columns < 10 { resolved_columns = DEFAULT_COLUMN_COUNT }

	terminal := new(Terminal)
	terminal.is_alive = true
	terminal.cursor_visible = true

	palette_init(&terminal.palette)
	terminal.screen.default_foreground_color = default_foreground
	terminal.screen.default_background_color = default_background
	screen_init(&terminal.screen, resolved_columns, resolved_rows)

	if !pty_spawn(terminal, resolved_columns, resolved_rows, working_directory) {
		screen_destroy(&terminal.screen)
		free(terminal)
		return nil
	}

	terminal.read_thread = thread.create_and_start_with_data(terminal, read_thread_proc)
	return terminal
}

terminal_destroy :: proc(terminal: ^Terminal) {
	if terminal == nil { return }
	terminal.is_alive = false

	// Two-phase shutdown to avoid deadlocking on the reader thread:
	//   1) `pty_close` terminates the child and closes the host-side pipes.
	//      Closing the output pipe is what unblocks the reader's pending
	//      ReadFile; terminating the child first means ClosePseudoConsole
	//      won't sit waiting for the shell to die.
	//   2) Once the reader is joined we can safely call ClosePseudoConsole
	//      and release the remaining handles / attribute list.
	pty_close(terminal)

	if terminal.read_thread != nil {
		thread.join(terminal.read_thread)
		thread.destroy(terminal.read_thread)
		terminal.read_thread = nil
	}

	pty_finalize(terminal)

	delete(terminal.output_buffer)
	terminal.output_buffer = nil

	screen_destroy(&terminal.screen)
	free(terminal)
}

// Lay the terminal out inside `rectangle` using the editor's monospace metrics.
// Recomputes rows/cols and, if they changed, resizes the cell grid and
// notifies the shell via ResizePseudoConsole.
terminal_set_geometry :: proc(terminal: ^Terminal, rectangle: sdl3.Rect, character_width, line_height: i32) {
	if terminal == nil { return }
	terminal.rectangle       = rectangle
	terminal.character_width = character_width
	terminal.line_height     = line_height
	if character_width <= 0 || line_height <= 0 { return }

	new_column_count := max(i32(10), rectangle.w / character_width)
	new_row_count    := max(i32(4),  rectangle.h / line_height)
	if new_column_count == terminal.screen.columns && new_row_count == terminal.screen.rows { return }

	screen_resize(&terminal.screen, new_column_count, new_row_count)
	pty_resize(terminal, new_column_count, new_row_count)
}

// Drain pending bytes from the read thread and feed them through the parser.
// Also advances the cursor-blink timer using the editor-supplied delta_time.
// Returns true when anything visible changed this tick — either the cursor
// blinked or bytes were drained — so the editor's main loop can flip its
// dirty flag without polling our internals.
terminal_update :: proc(terminal: ^Terminal, delta_time: f64) -> bool {
	if terminal == nil { return false }

	anything_changed := false

	// Cursor blink.
	terminal.cursor_timer += delta_time
	if terminal.cursor_timer >= 0.5 {
		terminal.cursor_timer -= 0.5
		terminal.cursor_visible = !terminal.cursor_visible
		anything_changed = true
	}

	// Drain shell output.
	drain_buffer: [DRAIN_BUDGET_PER_FRAME]u8
	drained_byte_count: int

	sync.lock(&terminal.output_mutex)
	available_byte_count := len(terminal.output_buffer)
	if available_byte_count > 0 {
		drained_byte_count = min(available_byte_count, DRAIN_BUDGET_PER_FRAME)
		copy(drain_buffer[:drained_byte_count], terminal.output_buffer[:drained_byte_count])
		// Shift the rest down. With per-frame drain this is rarely large.
		remaining_byte_count := available_byte_count - drained_byte_count
		if remaining_byte_count > 0 {
			copy(terminal.output_buffer[:remaining_byte_count], terminal.output_buffer[drained_byte_count:available_byte_count])
		}
		resize(&terminal.output_buffer, remaining_byte_count)
	}
	sync.unlock(&terminal.output_mutex)

	if drained_byte_count > 0 {
		parser_feed(terminal, drain_buffer[:drained_byte_count])
		anything_changed = true
	}

	return anything_changed
}

// Background thread entry: read from the PTY's output pipe in a tight loop,
// append into `terminal.output_buffer` under the mutex, exit when the pipe
// yields EOF or the terminal is being torn down.
@(private)
read_thread_proc :: proc(thread_argument: rawptr) {
	terminal := cast(^Terminal)thread_argument
	read_buffer: [4096]u8
	for terminal.is_alive {
		bytes_read, read_succeeded := pty_read(terminal, read_buffer[:])
		if !read_succeeded { break }       // pipe closed / unrecoverable error
		if bytes_read == 0 { continue } // idle tick — pty_read already slept; re-check is_alive
		sync.lock(&terminal.output_mutex)
		for byte_index in 0..<bytes_read { append(&terminal.output_buffer, read_buffer[byte_index]) }
		sync.unlock(&terminal.output_mutex)
	}
}

// Write `data` to the shell's stdin (typed user input or synthesized escape
// sequences for special keys). Returns the number of bytes that made it
// through; partial writes are unusual on Windows pipes but we surface them
// anyway. Also snaps the viewport back to the live bottom — typing always
// follows the prompt, mirroring xterm / Windows Terminal behavior.
terminal_write :: proc(terminal: ^Terminal, data: []u8) -> int {
	if terminal == nil || len(data) == 0 { return 0 }
	terminal.scroll_offset = 0
	return pty_write(terminal, data)
}

// Scroll the viewport by `line_delta` rows. Positive = scroll up (older
// content), negative = scroll down (back toward the live screen). Clamped
// to the available scrollback. Returns true when scroll_offset actually
// moved so the caller can mark its frame dirty.
terminal_scroll :: proc(terminal: ^Terminal, line_delta: i32) -> bool {
	if terminal == nil || line_delta == 0 { return false }
	max_scroll_offset := i32(len(terminal.screen.scrollback_rows))
	new_offset := terminal.scroll_offset + line_delta
	if new_offset < 0                 { new_offset = 0 }
	if new_offset > max_scroll_offset { new_offset = max_scroll_offset }
	if new_offset == terminal.scroll_offset { return false }
	terminal.scroll_offset = new_offset
	return true
}

// Force the viewport back to the live screen. Used by the input path so
// any keystroke that ends up in the shell pops the user out of scrollback.
terminal_snap_to_bottom :: proc(terminal: ^Terminal) {
	if terminal == nil { return }
	terminal.scroll_offset = 0
}

// Convenience for callers that want to push a literal string.
terminal_write_string :: proc(terminal: ^Terminal, text: string) -> int {
	return terminal_write(terminal, transmute([]u8)text)
}
