// Package `hover` is the LSP hover popup — the bubble that pops next to
// the editor cursor on Ctrl+K with type / doc info pulled back from the
// language server. Extracted from src/editor/hover.odin as the third
// modal subpackage. Mirrors the dependency-inversion pattern locked in
// for `help` and `terminal_picker`:
//
//   * `State` owns everything that survives between frames (visibility,
//     anchor coords, raw markdown text, parsed blocks, layout cache).
//   * The editor talks to it through a small functional API: open()/
//     set_anchor() to seed where the popup belongs, set_content() to
//     hand it a fresh markdown payload (already cloned), close() to
//     tear down, auto_close_if_cursor_moved() to drive stickiness, and
//     render() to draw.
//   * LSP request / response wiring stays in the editor — this package
//     doesn't know what a Client is. The editor's `hover_popup_update`
//     polls the LSP for a fresh result and calls `set_content` when one
//     arrives.
//
// Auto-close is driven by a "stickiness" range on the anchor line: while
// the cursor sits inside that byte span, the popup stays open; moving
// outside it (different row, different pane, or past the range columns)
// closes it. The editor seeds the range from an identifier-shaped span
// around the cursor.
package hover

import "core:strings"
import "vendor:sdl3"

import "../../markdown"

State :: struct {
	visible:           bool,
	text:              string, // owned, raw markdown
	anchor_line:       u32,
	anchor_column:     u32,
	anchor_pane_index: int,

	// "Stickiness" range — while the cursor sits anywhere in this byte
	// span on `anchor_line`, the popup stays open. Seeded by the editor
	// with a generous default around the cursor; the LSP `range` field
	// will eventually feed in a tighter span.
	range_start_column: u32,
	range_end_column:   u32,

	blocks:            [dynamic]markdown.Block,
	layouted_blocks:   [dynamic]markdown.LayoutedBlock,
	layout_width:      i32,
}

// Where the popup should anchor on screen, in viewport coordinates. The
// editor knows panes, gutters, scroll offsets, title-bar heights, font
// metrics — the hover package doesn't. Caller composes this struct once
// per render pass.
AnchorScreenPosition :: struct {
	cursor_screen_top_y: i32, // y of the cursor row (post-scroll)
	cursor_line_height:  i32, // host's line height — controls flip-above geometry
	pane_left_x:         i32, // left edge of the originating pane, for popup_x base
	character_width:     i32, // host's monospace cell width — for "70 columns wide" sizing
}

// Cursor snapshot the editor passes into `auto_close_if_cursor_moved`.
// Plain data: no pointers into editor state.
CursorState :: struct {
	active_pane_index: int,
	cursor_line:       u32,
	cursor_column:     u32,
	// True when the active pane is the same EditorPane the popup was
	// opened over. The editor checks this because the popup is per-pane
	// (different panes can have different cursors / different documents
	// the LSP response wouldn't be valid against).
	pane_is_editor:    bool,
}

// Chrome colors for the popup background + border. Markdown body colors
// come through the `markdown.Context` passed to `render`; chrome is the
// bubble around it.
Chrome :: struct {
	background: sdl3.FColor,
	border:     sdl3.FColor,
}

// --- Lifecycle ------------------------------------------------------------

destroy :: proc(state: ^State) {
	markdown.clear_layouted_blocks(&state.layouted_blocks)
	if cap(state.layouted_blocks) > 0 { delete(state.layouted_blocks) }
	markdown.clear_blocks(&state.blocks)
	if cap(state.blocks)          > 0 { delete(state.blocks) }
	if len(state.text) > 0 { delete(state.text) }
	state^ = State{}
}

// Tear the popup down without freeing the dynamic-array backing buffers
// (preserves `state.blocks` / `state.layouted_blocks` cap for reuse —
// reopening a popup right after closing is the common case for "Ctrl+K
// on different symbols in quick succession").
//
// Always safe to call — no-op when already closed.
close :: proc(state: ^State) {
	if !state.visible && len(state.text) == 0 && len(state.blocks) == 0 { return }
	destroy(state)
}

// Record where a freshly-fired hover request was anchored. Called by the
// editor *before* the LSP response lands so the popup's auto-close
// stickiness range survives the round-trip — without this, the next
// frame would see range columns of zero and immediately auto-close.
set_anchor :: proc(state: ^State, pane_index: int, anchor_line, anchor_column, range_start, range_end: u32) {
	state.anchor_line        = anchor_line
	state.anchor_column      = anchor_column
	state.anchor_pane_index  = pane_index
	state.range_start_column = range_start
	state.range_end_column   = range_end
}

// Populate the popup from an LSP hover response. `raw_text` is cloned —
// the caller can pass an LSP-owned string directly without pre-cloning.
// Re-parses the markdown immediately so per-frame render work is just
// layout + draw.
set_content :: proc(state: ^State, raw_text: string) {
	// Capture anchor info before destroy() zeros the struct. Forgetting
	// any of these makes the next-frame auto-close check immediately
	// slam the popup shut (range columns default to 0, so cursor_column
	// > 0 trips the "off the symbol" guard).
	anchor_line        := state.anchor_line
	anchor_column      := state.anchor_column
	anchor_pane_index  := state.anchor_pane_index
	range_start_column := state.range_start_column
	range_end_column   := state.range_end_column

	destroy(state)

	state.visible            = true
	state.text               = strings.clone(raw_text)
	state.anchor_line        = anchor_line
	state.anchor_column      = anchor_column
	state.anchor_pane_index  = anchor_pane_index
	state.range_start_column = range_start_column
	state.range_end_column   = range_end_column

	markdown.parse_into(state.text, &state.blocks)
}

// --- Update --------------------------------------------------------------

// Stickiness check — close the popup when the cursor wanders off the
// anchored symbol. Returns true if the popup was actually closed (caller
// should then release any LSP-side state the editor still owns).
//
// `cursor.pane_is_editor` is false when the active pane is something the
// hover popup doesn't apply to (terminal, markdown preview, output) — we
// treat that the same as a pane switch.
auto_close_if_cursor_moved :: proc(state: ^State, cursor: CursorState) -> (closed: bool) {
	if !state.visible { return false }

	close_reason := false
	switch {
	case state.anchor_pane_index < 0:
		close_reason = true
	case state.anchor_pane_index != cursor.active_pane_index:
		close_reason = true
	case !cursor.pane_is_editor:
		close_reason = true
	case cursor.cursor_line != state.anchor_line:
		close_reason = true
	case cursor.cursor_column < state.range_start_column:
		close_reason = true
	case cursor.cursor_column > state.range_end_column:
		close_reason = true
	}

	if !close_reason { return false }
	close(state)
	return true
}

// --- Render ---------------------------------------------------------------

render :: proc(state: ^State, md_ctx: ^markdown.Context, chrome: Chrome, viewport_width, viewport_height: i32, anchor: AnchorScreenPosition) {
	if !state.visible || len(state.text) == 0 || len(state.blocks) == 0 { return }
	renderer := md_ctx.renderer
	if renderer == nil { return }

	// Pick a sensible body-content width — clamped between a readable
	// minimum and ~70 chars of the host's monospace, then to the viewport.
	character_width := anchor.character_width; if character_width <= 0 { character_width = 8 }
	target_width:    i32 = character_width * 70
	if target_width > viewport_width - 60 { target_width = viewport_width - 60 }
	if target_width < character_width * 20 { target_width = character_width * 20 }

	horizontal_padding: i32 = 10
	vertical_padding:   i32 = 6
	usable_text_pixels := target_width

	// Re-layout when the chosen width drifts from what's cached — and
	// the first time around when nothing is laid out yet.
	if state.layout_width != usable_text_pixels || len(state.layouted_blocks) != len(state.blocks) {
		markdown.clear_layouted_blocks(&state.layouted_blocks)
		if cap(state.layouted_blocks) < len(state.blocks) {
			if cap(state.layouted_blocks) > 0 { delete(state.layouted_blocks) }
			state.layouted_blocks = make([dynamic]markdown.LayoutedBlock, 0, len(state.blocks), context.allocator)
		}
		for block_index in 0..<len(state.blocks) {
			append(&state.layouted_blocks, markdown.layout_block(md_ctx, &state.blocks[block_index], usable_text_pixels))
		}
		state.layout_width = usable_text_pixels
	}

	total_content_height: i32 = 0
	for layouted in state.layouted_blocks {
		total_content_height += layouted.height_pixels
	}

	popup_width  := usable_text_pixels + horizontal_padding * 2
	popup_height := total_content_height + vertical_padding * 2
	if popup_height > viewport_height - 40 { popup_height = viewport_height - 40 }

	// Anchor below the cursor row; flip above if the bubble would
	// otherwise clip the bottom of the window.
	popup_y := anchor.cursor_screen_top_y + anchor.cursor_line_height + 4
	if popup_y + popup_height > viewport_height - 4 {
		popup_y = anchor.cursor_screen_top_y - popup_height - 4
		if popup_y < 4 { popup_y = 4 }
	}
	popup_x := anchor.pane_left_x + 24
	if popup_x + popup_width > viewport_width - 4 {
		popup_x = viewport_width - 4 - popup_width
		if popup_x < 4 { popup_x = 4 }
	}

	popup_rectangle := sdl3.FRect{f32(popup_x), f32(popup_y), f32(popup_width), f32(popup_height)}
	sdl3.SetRenderDrawColorFloat(renderer, chrome.background.r, chrome.background.g, chrome.background.b, chrome.background.a)
	sdl3.RenderFillRect(renderer, &popup_rectangle)
	sdl3.SetRenderDrawColorFloat(renderer, chrome.border.r, chrome.border.g, chrome.border.b, chrome.border.a)
	sdl3.RenderRect(renderer, &popup_rectangle)

	// Clip so block contents (especially code blocks with full-width
	// backgrounds) don't bleed outside the bubble.
	clip_rectangle := sdl3.Rect{popup_x, popup_y, popup_width, popup_height}
	sdl3.SetRenderClipRect(renderer, &clip_rectangle)
	defer sdl3.SetRenderClipRect(renderer, nil)

	content_x := popup_x + horizontal_padding
	current_y := popup_y + vertical_padding
	bottom_y  := popup_y + popup_height
	for layouted_index in 0..<len(state.layouted_blocks) {
		layouted := &state.layouted_blocks[layouted_index]
		block_height := layouted.height_pixels
		if current_y + block_height >= popup_y && current_y < bottom_y {
			markdown.render_layouted_block(md_ctx, layouted, content_x, current_y, usable_text_pixels)
		}
		current_y += block_height
		if current_y >= bottom_y { break }
	}
}
