package terminal

import "core:sync"
import "core:thread"
import "vendor:sdl3"
import "vendor:sdl3/ttf"

// --- Cells, attributes, colors -------------------------------------------

CellAttr :: distinct u16
ATTR_BOLD      :: CellAttr(0x01)
ATTR_DIM       :: CellAttr(0x02)
ATTR_UNDERLINE :: CellAttr(0x04)
ATTR_REVERSE   :: CellAttr(0x08)
ATTR_ITALIC    :: CellAttr(0x10)

Color :: struct {
	r, g, b, a: f32,
}

Cell :: struct {
	ch:    rune,
	fg:    Color,
	bg:    Color,
	attrs: CellAttr,
}

// --- Screen --------------------------------------------------------------

Screen :: struct {
	cells:         []Cell, // row-major; len == cols * rows
	cols:          i32,
	rows:          i32,
	cursor_row:    i32,
	cursor_col:    i32,
	saved_row:     i32,
	saved_col:     i32,
	fg:            Color, // current foreground
	bg:            Color, // current background
	attrs:         CellAttr,
	default_fg:    Color,
	default_bg:    Color,
	scroll_top:    i32, // inclusive
	scroll_bottom: i32, // inclusive
	cursor_visible: bool,
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
	state:        ParserState,
	params:       [16]i32, // CSI numeric params; -1 means "unset"
	nparams:      int,
	private_mark: u8, // e.g. '?' for DEC private (ESC[?...) — 0 if none
	intermediate: u8, // a single intermediate byte (' '..'/') if present
}

// --- Terminal ------------------------------------------------------------

// Default starting grid before the editor has had a chance to compute the
// actual pixel rect.
DEFAULT_COLS :: i32(80)
DEFAULT_ROWS :: i32(24)

// Cap on bytes drained from the read queue per frame so a flood from the
// shell can't stall the UI. Excess stays in the queue for the next tick.
DRAIN_BUDGET_PER_FRAME :: 64 * 1024

Terminal :: struct {
	screen: Screen,
	parser: Parser,

	// Output buffer shared with the read thread.
	out_buf:   [dynamic]u8,
	out_mutex: sync.Mutex,

	read_thread: ^thread.Thread,

	// Platform-specific process / pty state (see process_*.odin).
	pty:   PtyState,
	alive: bool,

	// Geometry set by the editor each layout pass.
	rect:        sdl3.Rect,
	char_width:  i32,
	line_height: i32,

	// Cursor blink mirrors the editor's, but the terminal owns its own
	// counter so closing/reopening the pane resets the rhythm.
	cursor_visible: bool,
	cursor_timer:   f64,

	// Palette (xterm 256-color). palette[0..15] are the SGR 30-37 / 40-47
	// base colors; the rest of the indices are the standard xterm cube.
	palette: [256]Color,
}

// --- Public API ----------------------------------------------------------

// Allocate a new terminal, spin up the shell process, and start the read
// thread. Returns nil on failure (e.g. ConPTY unavailable). The caller owns
// the returned pointer and must hand it to `terminal_destroy` when done.
//
// `default_fg` / `default_bg` are the colors used for cells the shell hasn't
// explicitly colored via SGR — pass the editor's palette so plain shell
// output blends with the surrounding UI. The xterm 256-color palette is
// still initialized and used for SGR-styled cells.
terminal_new :: proc(rows, cols: i32, default_fg: Color, default_bg: Color) -> ^Terminal {
	r := rows; if r < 4  { r = DEFAULT_ROWS }
	c := cols; if c < 10 { c = DEFAULT_COLS }

	t := new(Terminal)
	t.alive = true
	t.cursor_visible = true

	palette_init(&t.palette)
	t.screen.default_fg = default_fg
	t.screen.default_bg = default_bg
	screen_init(&t.screen, c, r)

	if !pty_spawn(t, c, r) {
		screen_destroy(&t.screen)
		free(t)
		return nil
	}

	t.read_thread = thread.create_and_start_with_data(t, read_thread_proc)
	return t
}

terminal_destroy :: proc(t: ^Terminal) {
	if t == nil { return }
	t.alive = false

	// Two-phase shutdown to avoid deadlocking on the reader thread:
	//   1) `pty_close` terminates the child and closes the host-side pipes.
	//      Closing the output pipe is what unblocks the reader's pending
	//      ReadFile; terminating the child first means ClosePseudoConsole
	//      won't sit waiting for the shell to die.
	//   2) Once the reader is joined we can safely call ClosePseudoConsole
	//      and release the remaining handles / attribute list.
	pty_close(t)

	if t.read_thread != nil {
		thread.join(t.read_thread)
		thread.destroy(t.read_thread)
		t.read_thread = nil
	}

	pty_finalize(t)

	delete(t.out_buf)
	t.out_buf = nil

	screen_destroy(&t.screen)
	free(t)
}

// Lay the terminal out inside `rect` using the editor's monospace metrics.
// Recomputes rows/cols and, if they changed, resizes the cell grid and
// notifies the shell via ResizePseudoConsole.
terminal_set_geometry :: proc(t: ^Terminal, rect: sdl3.Rect, char_width, line_height: i32) {
	if t == nil { return }
	t.rect        = rect
	t.char_width  = char_width
	t.line_height = line_height
	if char_width <= 0 || line_height <= 0 { return }

	new_cols := max(i32(10), rect.w / char_width)
	new_rows := max(i32(4),  rect.h / line_height)
	if new_cols == t.screen.cols && new_rows == t.screen.rows { return }

	screen_resize(&t.screen, new_cols, new_rows)
	pty_resize(t, new_cols, new_rows)
}

// Drain pending bytes from the read thread and feed them through the parser.
// Also advances the cursor-blink timer using the editor-supplied dt. Returns
// true when anything visible changed this tick — either the cursor blinked
// or bytes were drained — so the editor's main loop can flip its dirty flag
// without polling our internals.
terminal_update :: proc(t: ^Terminal, dt: f64) -> bool {
	if t == nil { return false }

	changed := false

	// Cursor blink.
	t.cursor_timer += dt
	if t.cursor_timer >= 0.5 {
		t.cursor_timer -= 0.5
		t.cursor_visible = !t.cursor_visible
		changed = true
	}

	// Drain shell output.
	bytes: [DRAIN_BUDGET_PER_FRAME]u8
	count: int

	sync.lock(&t.out_mutex)
	available := len(t.out_buf)
	if available > 0 {
		count = min(available, DRAIN_BUDGET_PER_FRAME)
		copy(bytes[:count], t.out_buf[:count])
		// Shift the rest down. With per-frame drain this is rarely large.
		remaining := available - count
		if remaining > 0 {
			copy(t.out_buf[:remaining], t.out_buf[count:available])
		}
		resize(&t.out_buf, remaining)
	}
	sync.unlock(&t.out_mutex)

	if count > 0 {
		parser_feed(t, bytes[:count])
		changed = true
	}

	return changed
}

// Background thread entry: read from the PTY's output pipe in a tight loop,
// append into `t.out_buf` under the mutex, exit when the pipe yields EOF or
// the terminal is being torn down.
@(private)
read_thread_proc :: proc(arg: rawptr) {
	t := cast(^Terminal)arg
	buf: [4096]u8
	for t.alive {
		n, ok := pty_read(t, buf[:])
		if !ok { break }       // pipe closed / unrecoverable error
		if n == 0 { continue } // idle tick — pty_read already slept; re-check t.alive
		sync.lock(&t.out_mutex)
		for i in 0..<n { append(&t.out_buf, buf[i]) }
		sync.unlock(&t.out_mutex)
	}
}

// Write `data` to the shell's stdin (typed user input or synthesized escape
// sequences for special keys). Returns the number of bytes that made it
// through; partial writes are unusual on Windows pipes but we surface them
// anyway.
terminal_write :: proc(t: ^Terminal, data: []u8) -> int {
	if t == nil || len(data) == 0 { return 0 }
	return pty_write(t, data)
}

// Convenience for callers that want to push a literal string.
terminal_write_string :: proc(t: ^Terminal, s: string) -> int {
	return terminal_write(t, transmute([]u8)s)
}
