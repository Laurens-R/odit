// Package `signature_popup` is the small popup that shows a procedure's
// signature while the user is inside the argument list. Triggered when
// `(` is typed (and refreshed on `,` / cursor moves), closed by the
// matching `)`, Esc, jumping to a different row, or backing past the
// opening paren.
//
// Visually similar to the hover popup but content is just the signature
// label with the active parameter underlined; documentation, when ols
// provides it, renders as markdown below the signature.
//
// Extracted from src/editor/signature_popup.odin alongside the hover
// extraction — same dependency-inversion pattern: state owns its data,
// editor owns LSP wiring + anchor-position computation.
package signature_popup

import "core:strings"
import "vendor:sdl3"
import "vendor:sdl3/ttf"

import "../../markdown"

State :: struct {
	visible:           bool,
	pane_index:        int,
	anchor_line:       u32,
	open_paren_offset: u32,    // byte offset of the `(` that triggered the popup
	request_pending:   bool,

	// If a `,` (or another paren-list cursor move) arrives while a
	// previous request is still in flight, we DON'T fire a second one —
	// that'd pile up on a slow server. We just flip this flag; the
	// moment the in-flight response lands, the editor immediately fires
	// the latest position and clears the flag. End state always
	// converges on the cursor's current location.
	needs_refresh:     bool,

	// Snapshotted from the latest server response so re-renders don't
	// need to peek at the LSP client's state.
	signature_label:   string, // owned
	documentation:     string, // owned
	active_start:      i32,    // byte range of the highlighted parameter within `signature_label`
	active_end:        i32,

	// Cached `ttf.Text*` for the signature label. Rebuilt lazily on the
	// first render after `set_content`. Saves a CreateText/Destroy
	// roundtrip on every frame the popup is visible (cursor blink alone
	// fires render twice a second).
	signature_text_object: ^ttf.Text,
	signature_text_dirty:  bool,

	doc_blocks:           [dynamic]markdown.Block,
	doc_layouted_blocks:  [dynamic]markdown.LayoutedBlock,
	doc_layout_width:     i32,
}

// Anchor info computed by the editor — same shape as the hover
// equivalent but with a `text_left_x` (post-gutter) and a `pane_top_y`
// (post-title-bar) so the popup can decide whether to flip from above-
// cursor to below.
AnchorScreenPosition :: struct {
	cursor_screen_top_y: i32, // y of the anchor row (post-scroll)
	cursor_line_height:  i32, // host's line height
	character_width:     i32, // host's monospace cell width
	text_left_x:         i32, // where the popup left edge should anchor (post-gutter)
	pane_top_y:          i32, // topmost y the popup may occupy (post-title-bar)
}

// Cursor snapshot the editor passes into `auto_close_if_cursor_moved`.
// Plain data; no pointers into editor state.
CursorState :: struct {
	pane_index:     int,
	cursor_line:    u32,
	cursor_offset:  u32,  // byte offset in the doc — used for the "moved past `(`" check
	pane_is_editor: bool,
}

// Fresh signature data the editor extracts from an LSP response and
// hands to `set_content`. Strings are NOT owned by the editor after the
// call — `set_content` clones them.
Content :: struct {
	signature_label: string,
	documentation:   string,
	active_start:    i32,
	active_end:      i32,
}

// Chrome colors for the popup background + border. Markdown body colors
// flow through `markdown.Context`. The signature label and the active-
// parameter underline get their own colors here since they're not
// markdown content.
Chrome :: struct {
	background:             sdl3.FColor,
	border:                 sdl3.FColor,
	signature_color:        sdl3.FColor,
	active_underline_color: sdl3.FColor,
}

// --- Lifecycle ------------------------------------------------------------

destroy :: proc(state: ^State) {
	markdown.clear_layouted_blocks(&state.doc_layouted_blocks)
	if cap(state.doc_layouted_blocks) > 0 { delete(state.doc_layouted_blocks) }
	markdown.clear_blocks(&state.doc_blocks)
	if cap(state.doc_blocks) > 0 { delete(state.doc_blocks) }
	if len(state.signature_label) > 0 { delete(state.signature_label) }
	if len(state.documentation)   > 0 { delete(state.documentation)   }
	if state.signature_text_object != nil {
		ttf.DestroyText(state.signature_text_object)
		state.signature_text_object = nil
	}
	state^ = State{}
}

close :: proc(state: ^State) {
	if !state.visible { return }
	destroy(state)
}

// Open the popup at the `(` that just got typed (or refresh anchor on a
// `,`). Safe to call repeatedly — only the first call sets the anchor;
// subsequent calls leave existing anchor info untouched, matching the
// "popup follows the same call expression" UX.
open :: proc(state: ^State, pane_index: int, anchor_line: u32, open_paren_offset: u32) {
	if state.visible { return } // already open at the same call expression
	destroy(state)
	state.visible            = true
	state.pane_index         = pane_index
	state.anchor_line        = anchor_line
	state.open_paren_offset  = open_paren_offset
}

// --- LSP request coalescing helpers ---------------------------------------

// Mark that a request has been fired and is in flight. Editor calls this
// right after issuing `lsp.client_request_signature_help` so the popup
// knows to wait for a response before firing again.
mark_request_pending :: proc(state: ^State) {
	state.request_pending = true
}

// Editor calls this when a `,` arrives but a request is already in
// flight — flips the "refire as soon as the previous one lands" flag.
// Returns whether the editor should ACTUALLY skip firing a new request.
should_coalesce_request :: proc(state: ^State) -> bool {
	if !state.request_pending { return false }
	state.needs_refresh = true
	return true
}

// --- Stickiness ----------------------------------------------------------

// Auto-close when the cursor wanders off the call expression. Returns
// true if the popup was actually closed.
auto_close_if_cursor_moved :: proc(state: ^State, cursor: CursorState) -> (closed: bool) {
	if !state.visible { return false }

	close_reason := false
	switch {
	case state.pane_index < 0:
		close_reason = true
	case state.pane_index != cursor.pane_index:
		close_reason = true
	case !cursor.pane_is_editor:
		close_reason = true
	case cursor.cursor_line != state.anchor_line:
		close_reason = true
	case cursor.cursor_offset < state.open_paren_offset:
		close_reason = true
	}

	if !close_reason { return false }
	close(state)
	return true
}

// --- Content set --------------------------------------------------------

// Populate the popup with fresh signature data. Strings inside `content`
// are cloned, so the caller can pass LSP-owned strings directly without
// pre-cloning. Marks the cached signature text-object dirty so the next
// render rebuilds it against the host's font.
//
// Returns true when the editor should refire the request immediately —
// i.e. a `,` arrived while we were waiting for the previous response.
set_content :: proc(state: ^State, content: Content) -> (needs_refire: bool) {
	state.request_pending = false

	// Free previous data + markdown cache before overwriting.
	markdown.clear_layouted_blocks(&state.doc_layouted_blocks)
	markdown.clear_blocks(&state.doc_blocks)
	state.doc_layout_width = 0
	if len(state.signature_label) > 0 { delete(state.signature_label); state.signature_label = "" }
	if len(state.documentation)   > 0 { delete(state.documentation);   state.documentation   = "" }
	if state.signature_text_object != nil {
		ttf.DestroyText(state.signature_text_object)
		state.signature_text_object = nil
	}

	state.signature_label = strings.clone(content.signature_label)
	state.documentation   = strings.clone(content.documentation)
	state.active_start    = content.active_start
	state.active_end      = content.active_end
	state.signature_text_dirty = true

	// Parse the docs markdown once; layout happens lazily during render.
	if len(state.documentation) > 0 {
		markdown.parse_into(state.documentation, &state.doc_blocks)
	}

	needs_refire = state.needs_refresh
	state.needs_refresh = false
	return needs_refire
}

// --- Render ---------------------------------------------------------------

render :: proc(state: ^State, md_ctx: ^markdown.Context, chrome: Chrome, viewport_width, viewport_height: i32, anchor: AnchorScreenPosition) {
	if !state.visible || len(state.signature_label) == 0 { return }
	renderer := md_ctx.renderer
	if renderer == nil { return }

	horizontal_padding: i32 = 10
	vertical_padding:   i32 = 6
	character_width    := anchor.character_width; if character_width <= 0 { character_width = 8 }
	line_step          := anchor.cursor_line_height

	signature_width, _ := signature_text_size(state.signature_label, character_width)

	// Pick a width that comfortably holds the signature and is wide
	// enough for the markdown docs to flow without wrapping each phrase.
	popup_width := signature_width + horizontal_padding * 2
	preferred_width := character_width * 70
	if popup_width < preferred_width  { popup_width = preferred_width }
	if popup_width > viewport_width - 40 { popup_width = viewport_width - 40 }

	docs_usable_pixels := popup_width - horizontal_padding * 2

	// (Re-)layout markdown docs whenever the popup width changes (or on
	// the first frame after a fresh response). Mirrors HoverPopup's logic.
	docs_height: i32 = 0
	if len(state.doc_blocks) > 0 {
		if state.doc_layout_width != docs_usable_pixels || len(state.doc_layouted_blocks) != len(state.doc_blocks) {
			markdown.clear_layouted_blocks(&state.doc_layouted_blocks)
			if cap(state.doc_layouted_blocks) < len(state.doc_blocks) {
				if cap(state.doc_layouted_blocks) > 0 { delete(state.doc_layouted_blocks) }
				state.doc_layouted_blocks = make([dynamic]markdown.LayoutedBlock, 0, len(state.doc_blocks), context.allocator)
			}
			for block_index in 0..<len(state.doc_blocks) {
				append(&state.doc_layouted_blocks, markdown.layout_block(md_ctx, &state.doc_blocks[block_index], docs_usable_pixels))
			}
			state.doc_layout_width = docs_usable_pixels
		}
		for layouted in state.doc_layouted_blocks {
			docs_height += layouted.height_pixels
		}
	}

	signature_row_height := line_step
	body_gap_between_sig_and_docs: i32 = docs_height > 0 ? 4 : 0
	popup_height := vertical_padding + signature_row_height + body_gap_between_sig_and_docs + docs_height + vertical_padding
	if popup_height > viewport_height - 40 { popup_height = viewport_height - 40 }

	// Anchor above the cursor row so the popup sits where it blocks the
	// least typing; flip below if it would clip the top of the pane.
	popup_y := anchor.cursor_screen_top_y - popup_height - 2
	if popup_y < anchor.pane_top_y + 2 {
		popup_y = anchor.cursor_screen_top_y + line_step + 2
	}
	popup_x := anchor.text_left_x
	if popup_x + popup_width > viewport_width - 4 {
		popup_x = viewport_width - 4 - popup_width
		if popup_x < 4 { popup_x = 4 }
	}

	popup_rectangle := sdl3.FRect{f32(popup_x), f32(popup_y), f32(popup_width), f32(popup_height)}
	sdl3.SetRenderDrawColorFloat(renderer, chrome.background.r, chrome.background.g, chrome.background.b, chrome.background.a)
	sdl3.RenderFillRect(renderer, &popup_rectangle)
	sdl3.SetRenderDrawColorFloat(renderer, chrome.border.r, chrome.border.g, chrome.border.b, chrome.border.a)
	sdl3.RenderRect(renderer, &popup_rectangle)

	clip_rectangle := sdl3.Rect{popup_x, popup_y, popup_width, popup_height}
	sdl3.SetRenderClipRect(renderer, &clip_rectangle)
	defer sdl3.SetRenderClipRect(renderer, nil)

	// Build (or reuse) the cached signature text-object. Uses the host's
	// monospace font from the markdown context so signatures look right
	// regardless of whether the proportional markdown body font loaded.
	if state.signature_text_dirty && md_ctx.monospace_font != nil && md_ctx.engine != nil {
		if state.signature_text_object != nil {
			ttf.DestroyText(state.signature_text_object)
			state.signature_text_object = nil
		}
		c_label := strings.clone_to_cstring(state.signature_label, context.temp_allocator)
		state.signature_text_object = ttf.CreateText(md_ctx.engine, md_ctx.monospace_font, c_label, 0)
		state.signature_text_dirty = false
	}

	// Signature line: monospace + active-param underline.
	signature_y := popup_y + vertical_padding
	if state.signature_text_object != nil {
		c := chrome.signature_color
		_ = ttf.SetTextColorFloat(state.signature_text_object, c.r, c.g, c.b, c.a)
		_ = ttf.DrawRendererText(state.signature_text_object, f32(popup_x + horizontal_padding), f32(signature_y))
	}
	if state.active_start >= 0 && state.active_end > state.active_start && int(state.active_end) <= len(state.signature_label) {
		prefix_width: i32 = 0
		active_width: i32 = 0
		if state.active_start > 0 {
			prefix_width, _ = signature_text_size(state.signature_label[:state.active_start], character_width)
		}
		active_width, _ = signature_text_size(state.signature_label[state.active_start:state.active_end], character_width)

		underline_y := signature_y + line_step - 2
		uc := chrome.active_underline_color
		sdl3.SetRenderDrawColorFloat(renderer, uc.r, uc.g, uc.b, uc.a)
		sdl3.RenderLine(renderer, f32(popup_x + horizontal_padding + prefix_width), f32(underline_y), f32(popup_x + horizontal_padding + prefix_width + active_width - 1), f32(underline_y))

		// Repaint the active range in the underline color so it pops
		// against the dimmer signature_color used for the rest of the
		// label. Burns one extra CreateText/DrawText per active param —
		// fine, this only happens once per LSP response.
		if md_ctx.monospace_font != nil && md_ctx.engine != nil {
			c_active := strings.clone_to_cstring(state.signature_label[state.active_start:state.active_end], context.temp_allocator)
			active_text_object := ttf.CreateText(md_ctx.engine, md_ctx.monospace_font, c_active, 0)
			if active_text_object != nil {
				_ = ttf.SetTextColorFloat(active_text_object, uc.r, uc.g, uc.b, uc.a)
				_ = ttf.DrawRendererText(active_text_object, f32(popup_x + horizontal_padding + prefix_width), f32(signature_y))
				ttf.DestroyText(active_text_object)
			}
		}
	}

	// Markdown docs below the signature.
	if len(state.doc_layouted_blocks) > 0 {
		docs_origin_x := popup_x + horizontal_padding
		current_y := signature_y + signature_row_height + body_gap_between_sig_and_docs
		bottom_y  := popup_y + popup_height - vertical_padding
		for layouted_index in 0..<len(state.doc_layouted_blocks) {
			layouted := &state.doc_layouted_blocks[layouted_index]
			block_height := layouted.height_pixels
			if current_y + block_height >= popup_y && current_y < bottom_y {
				markdown.render_layouted_block(md_ctx, layouted, docs_origin_x, current_y, docs_usable_pixels)
			}
			current_y += block_height
			if current_y >= bottom_y { break }
		}
	}
}

@(private="file")
signature_text_size :: proc(text: string, character_width: i32) -> (width, height: i32) {
	if len(text) == 0 || character_width <= 0 { return 0, 0 }
	return i32(len(text)) * character_width, 0
}
