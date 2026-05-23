// Dispatcher glue: drives `handle_event` and routes intents through
// the host. Filesystem ops + undo bookkeeping live on the host side.
package browse_prompt

import "vendor:sdl3"

dispatch_event :: proc(state: ^State, host: ^Host, event: ^sdl3.Event) -> (needs_redraw: bool) {
	intent, redraw := handle_event(state, event)
	if intent != nil && host != nil {
		#partial switch intent_value in intent {
		case SubmitRename:
			if host.apply_rename != nil { host.apply_rename(host.user_data, intent_value.old_name, intent_value.new_name) }
		case SubmitNewFile:
			if host.apply_new_file != nil { host.apply_new_file(host.user_data, intent_value.name) }
		case SubmitNewFolder:
			if host.apply_new_folder != nil { host.apply_new_folder(host.user_data, intent_value.name) }
		}
	}
	return redraw
}
