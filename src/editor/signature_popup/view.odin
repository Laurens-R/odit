// Render for the signature popup.
package signature_popup

import "core:strings"
import "vendor:sdl3"
import "vendor:sdl3/ttf"

import "../../markdown"

render :: proc(state: ^State, md_ctx: ^markdown.Context, chrome: Chrome, viewport_width, viewport_height: i32, anchor: AnchorScreenPosition) {
	if !state.visible || len(state.signature_label) == 0 { return }
	renderer := md_ctx.renderer
	if renderer == nil { return }

	horizontal_padding: i32 = 10
	vertical_padding:   i32 = 6
	character_width    := anchor.character_width; if character_width <= 0 { character_width = 8 }
	line_step          := anchor.cursor_line_height

	signature_width, _ := signature_text_size(state.signature_label, character_width)

	popup_width := signature_width + horizontal_padding * 2
	preferred_width := character_width * 70
	if popup_width < preferred_width  { popup_width = preferred_width }
	if popup_width > viewport_width - 40 { popup_width = viewport_width - 40 }

	docs_usable_pixels := popup_width - horizontal_padding * 2

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

	if state.signature_text_dirty && md_ctx.monospace_font != nil && md_ctx.engine != nil {
		if state.signature_text_object != nil {
			ttf.DestroyText(state.signature_text_object)
			state.signature_text_object = nil
		}
		c_label := strings.clone_to_cstring(state.signature_label, context.temp_allocator)
		state.signature_text_object = ttf.CreateText(md_ctx.engine, md_ctx.monospace_font, c_label, 0)
		state.signature_text_dirty = false
	}

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
