// Editor binding for the Ctrl+Space LSP completion popup. Active
// — consumes navigation keys (Esc / arrows / Enter / Tab) when
// open; mirrors typing into the filter buffer otherwise. All
// editor coupling flows through `binding.EditorAPI`.
package completion_popup

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
		name         = "completion_popup",
		state        = rawptr(binding_context),
		visible      = binding_visible,
		destroy      = binding_destroy,
		handle_event = binding_handle_event,
		render       = binding_render,
	}
}

// Bound to Ctrl+Space and the LSP trigger-character path. Fires an
// LSP completion request at the active pane's cursor; the response
// is picked up by `update_via_api` next frame.
trigger_at_cursor_via_api :: proc(state: ^State, api: ^binding.EditorAPI) {
	if api == nil { return }
	cursor := api.active_pane_cursor(api.editor)
	if !cursor.is_editor { return }

	open(state, cursor.pane_index, cursor.cursor_line, cursor.cursor_column)
	if !api.lsp_request_completion(api.editor) {
		// LSP not ready — leave the popup in `request_pending = true`
		// so the next typed char still tries to fill it; but if we
		// reached here from Ctrl+Space the user gets a "loading…"
		// stub for an instant before it auto-closes.
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
		cursor_column  = cursor.cursor_column,
		pane_is_editor = cursor.is_editor,
	}
	if auto_close_if_cursor_moved(state, cursor_state) { return }

	if !state.request_pending { return }

	items, ok := api.lsp_poll_completion(api.editor, context.temp_allocator)
	if !ok { return }

	sources := make([]ItemSource, len(items), context.temp_allocator)
	for raw_item, item_index in items {
		sources[item_index] = ItemSource{
			label       = raw_item.label,
			detail      = raw_item.detail,
			insert_text = raw_item.insert_text,
		}
	}
	// We're outside the render loop so we don't have a real
	// `ui.Context`. Pass an empty one — `set_items` skips
	// pre-measurement when there's no font, and the renderer
	// fills in widths lazily on its first paint via
	// `ensure_item_widths_measured`.
	empty_ui_context := ui.Context{}
	set_items(state, &empty_ui_context, sources)
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
	binding_context := cast(^BindingContext)state_ptr
	state := binding_context.state
	if !state.visible { return false, false }

	#partial switch event.type {
	case .KEY_DOWN:
		if event.key.key == sdl3.K_BACKSPACE {
			_, redraw := consume_backspace(state)
			return false, redraw
		}
		intent, key_consumed, redraw := handle_key(state, event)
		if intent != nil {
			#partial switch accept in intent {
			case Accept:
				if api != nil && api.apply_completion_at_cursor != nil {
					api.apply_completion_at_cursor(api.editor, state.pane_index, accept.insert_text)
				}
			}
		}
		return key_consumed, redraw

	case .TEXT_INPUT:
		input_text := string(event.text.text)
		_, redraw := consume_text(state, input_text)
		return false, redraw
	}
	return false, false
}

@(private="file")
binding_render :: proc(state_ptr: rawptr, api: ^binding.EditorAPI, renderer: ^sdl3.Renderer, ui_context: ^ui.Context, viewport_width, viewport_height: i32) {
	binding_context := cast(^BindingContext)state_ptr
	state := binding_context.state
	if !state.visible { return }
	if api == nil { return }

	pa    := api.pane_anchor(api.editor, state.pane_index, state.anchor_line)
	theme := api.theme(api.editor)

	chrome := Chrome{
		background     = theme.background_color,
		border         = theme.divider_color,
		selection      = theme.selection_color,
		label          = theme.foreground_color,
		label_selected = theme.cursor_color,
		detail         = theme.line_number_color,
		stub           = theme.line_number_color,
	}

	// `cursor_screen_x` is the screen-x for the anchor *column*,
	// not just the pane edge — recompute it from the pane anchor
	// using the popup's saved anchor_column.
	cursor_screen_x := pa.text_left_x + i32(state.anchor_column) * pa.character_width
	anchor := AnchorScreenPosition{
		cursor_screen_top_y = pa.cursor_screen_top_y,
		cursor_line_height  = pa.cursor_line_height,
		character_width     = pa.character_width,
		cursor_screen_x     = cursor_screen_x,
	}

	render(state, ui_context, chrome, anchor, viewport_width, viewport_height)
}
