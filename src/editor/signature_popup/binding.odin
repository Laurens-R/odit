// Editor binding for the signature-help popup. Passive — doesn't
// consume input. All editor coupling flows through
// `binding.EditorAPI`.
package signature_popup

import "vendor:sdl3"

import "../../ui"
import "../binding"

@(private="file")
BindingContext :: struct {
	state: ^State,
}

make_binding :: proc(state: ^State, allocator := context.allocator) -> binding.Binding {
	binding_context := new(BindingContext, allocator)
	binding_context.state = state
	return binding.Binding{
		name         = "signature_popup",
		state        = rawptr(binding_context),
		passive      = true,
		visible      = binding_visible,
		destroy      = binding_destroy,
		handle_event = binding_handle_event,
		render       = binding_render,
	}
}

// Fired from the text-input path on `(` (or `,` to nudge the active
// parameter underline). Opens or refreshes the popup; coalesces in
// flight requests.
request_at_cursor_via_api :: proc(state: ^State, api: ^binding.EditorAPI) {
	if api == nil { return }
	cursor := api.active_pane_cursor(api.editor)
	if !cursor.is_editor { return }

	open(state, cursor.pane_index, cursor.cursor_line, cursor.cursor_offset)

	if should_coalesce_request(state) { return }

	if api.lsp_request_signature_help(api.editor) {
		mark_request_pending(state)
	}
}

// Per-frame: stickiness probe + drain in-flight response.
update_via_api :: proc(state: ^State, api: ^binding.EditorAPI) {
	if api == nil { return }
	if !state.visible { return }

	cursor := api.active_pane_cursor(api.editor)
	cursor_state := CursorState{
		pane_index     = cursor.pane_index,
		cursor_line    = cursor.cursor_line,
		cursor_offset  = cursor.cursor_offset,
		pane_is_editor = cursor.is_editor,
	}
	if auto_close_if_cursor_moved(state, cursor_state) { return }

	if !state.request_pending { return }

	info, ok := api.lsp_poll_signature_help(api.editor, context.temp_allocator)
	if !ok { return }

	if len(info.label) == 0 && info.active_start < 0 {
		// Server returned an empty result — close the popup rather
		// than leaving an empty bubble on screen.
		close(state)
		return
	}

	needs_refire := set_content(state, Content{
		signature_label = info.label,
		documentation   = info.documentation,
		active_start    = info.active_start,
		active_end      = info.active_end,
	})
	if needs_refire {
		request_at_cursor_via_api(state, api)
	}
}

@(private="file")
binding_visible :: proc(state_ptr: rawptr) -> bool {
	binding_context := cast(^BindingContext)state_ptr
	return binding_context.state.visible
}

@(private="file")
binding_destroy :: proc(state_ptr: rawptr) {
	binding_context := cast(^BindingContext)state_ptr
	destroy(binding_context.state)
	free(binding_context)
}

@(private="file")
binding_handle_event :: proc(state_ptr: rawptr, api: ^binding.EditorAPI, event: ^sdl3.Event) -> (consumed: bool, needs_redraw: bool) {
	return false, false
}

@(private="file")
binding_render :: proc(state_ptr: rawptr, api: ^binding.EditorAPI, renderer: ^sdl3.Renderer, ui_context: ^ui.Context, viewport_width, viewport_height: i32) {
	binding_context := cast(^BindingContext)state_ptr
	state := binding_context.state
	if !state.visible { return }
	if api == nil || api.markdown_context == nil { return }

	md_ctx := api.markdown_context(api.editor, renderer)
	pa     := api.pane_anchor(api.editor, state.pane_index, state.anchor_line)
	theme  := api.theme(api.editor)

	chrome := Chrome{
		background             = theme.status_bar_background,
		border                 = theme.divider_color,
		signature_color        = theme.cursor_color,
		active_underline_color = theme.syntax_keyword_foreground,
	}
	anchor := AnchorScreenPosition{
		cursor_screen_top_y = pa.cursor_screen_top_y,
		cursor_line_height  = pa.cursor_line_height,
		character_width     = pa.character_width,
		text_left_x         = pa.text_left_x,
		pane_top_y          = pa.pane_top_y,
	}
	render(state, &md_ctx, chrome, viewport_width, viewport_height, anchor)
}
