// Render for the hover popup.
package hover

import "vendor:sdl3"

import "../../markdown"

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
