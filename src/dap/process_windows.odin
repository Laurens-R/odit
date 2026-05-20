#+build windows
package dap

import "core:strings"
import win32 "core:sys/windows"

// Mirrors `src/lsp/process_windows.odin` — DAP adapters speak the same kind of
// stdio JSON-RPC the LSP layer already drives. The two implementations are
// intentionally near-duplicates so each package can evolve independently.

ProcessState :: struct {
	process_handle: win32.HANDLE,
	thread_handle:  win32.HANDLE,
	stdin_write:    win32.HANDLE,
	stdout_read:    win32.HANDLE,
	stderr_read:    win32.HANDLE,
}

@(private)
process_spawn :: proc(state: ^ProcessState, command_tokens: []string, working_directory: string = "") -> bool {
	state^ = ProcessState{}
	if len(command_tokens) == 0 { return false }

	security_attributes := win32.SECURITY_ATTRIBUTES{}
	security_attributes.nLength        = size_of(win32.SECURITY_ATTRIBUTES)
	security_attributes.bInheritHandle = true

	stdin_read, stdin_write_local: win32.HANDLE
	stdout_read, stdout_write:     win32.HANDLE
	stderr_read, stderr_write:     win32.HANDLE

	if !win32.CreatePipe(&stdin_read, &stdin_write_local, &security_attributes, 0) { return false }
	if !win32.CreatePipe(&stdout_read, &stdout_write, &security_attributes, 0) {
		win32.CloseHandle(stdin_read); win32.CloseHandle(stdin_write_local)
		return false
	}
	if !win32.CreatePipe(&stderr_read, &stderr_write, &security_attributes, 0) {
		win32.CloseHandle(stdin_read);  win32.CloseHandle(stdin_write_local)
		win32.CloseHandle(stdout_read); win32.CloseHandle(stdout_write)
		return false
	}

	win32.SetHandleInformation(stdin_write_local, win32.HANDLE_FLAG_INHERIT, 0)
	win32.SetHandleInformation(stdout_read,       win32.HANDLE_FLAG_INHERIT, 0)
	win32.SetHandleInformation(stderr_read,       win32.HANDLE_FLAG_INHERIT, 0)

	startup_info := win32.STARTUPINFOW{}
	startup_info.cb         = u32(size_of(win32.STARTUPINFOW))
	startup_info.dwFlags    = win32.STARTF_USESTDHANDLES
	startup_info.hStdInput  = stdin_read
	startup_info.hStdOutput = stdout_write
	startup_info.hStdError  = stderr_write

	command_line_string  := build_command_line(command_tokens)
	command_line_wstring := win32.utf8_to_wstring(command_line_string)

	working_directory_wstring: win32.wstring = nil
	if len(working_directory) > 0 { working_directory_wstring = win32.utf8_to_wstring(working_directory) }

	process_information := win32.PROCESS_INFORMATION{}
	process_created := win32.CreateProcessW(
		nil,
		command_line_wstring,
		nil, nil,
		true,
		win32.CREATE_NO_WINDOW,
		nil,
		working_directory_wstring,
		&startup_info,
		&process_information,
	)

	win32.CloseHandle(stdin_read)
	win32.CloseHandle(stdout_write)
	win32.CloseHandle(stderr_write)

	if !process_created {
		win32.CloseHandle(stdin_write_local)
		win32.CloseHandle(stdout_read)
		win32.CloseHandle(stderr_read)
		return false
	}

	state.process_handle = process_information.hProcess
	state.thread_handle  = process_information.hThread
	state.stdin_write    = stdin_write_local
	state.stdout_read    = stdout_read
	state.stderr_read    = stderr_read
	return true
}

@(private)
process_close :: proc(state: ^ProcessState) {
	if state.process_handle != nil { win32.TerminateProcess(state.process_handle, 0) }
	if state.stdin_write    != nil { win32.CloseHandle(state.stdin_write);  state.stdin_write  = nil }
	if state.stdout_read    != nil { win32.CloseHandle(state.stdout_read);  state.stdout_read  = nil }
	if state.stderr_read    != nil { win32.CloseHandle(state.stderr_read);  state.stderr_read  = nil }
}

@(private)
process_finalize :: proc(state: ^ProcessState) {
	if state.process_handle != nil { win32.CloseHandle(state.process_handle); state.process_handle = nil }
	if state.thread_handle  != nil { win32.CloseHandle(state.thread_handle);  state.thread_handle  = nil }
}

@(private)
process_read :: proc(state: ^ProcessState, buffer: []u8) -> (bytes_read: int, ok: bool) {
	if state.stdout_read == nil { return 0, false }

	bytes_available: u32
	if !win32.PeekNamedPipe(state.stdout_read, nil, 0, nil, &bytes_available, nil) {
		return 0, false
	}
	if bytes_available == 0 {
		win32.Sleep(10)
		return 0, true
	}

	to_read := u32(len(buffer))
	if to_read > bytes_available { to_read = bytes_available }

	actually_read: u32
	if !win32.ReadFile(state.stdout_read, raw_data(buffer), to_read, &actually_read, nil) {
		return 0, false
	}
	return int(actually_read), true
}

@(private)
process_write :: proc(state: ^ProcessState, data: []u8) -> int {
	if state.stdin_write == nil || len(data) == 0 { return 0 }
	written: u32
	if !win32.WriteFile(state.stdin_write, raw_data(data), u32(len(data)), &written, nil) {
		return 0
	}
	return int(written)
}

@(private="file")
build_command_line :: proc(tokens: []string) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, 0, 128, context.temp_allocator)
	for token, token_index in tokens {
		if token_index > 0 { strings.write_byte(&builder, ' ') }
		needs_quotes := false
		for character in token {
			if character == ' ' || character == '\t' { needs_quotes = true; break }
		}
		if needs_quotes {
			strings.write_byte(&builder, '"')
			strings.write_string(&builder, token)
			strings.write_byte(&builder, '"')
		} else {
			strings.write_string(&builder, token)
		}
	}
	return strings.to_string(builder)
}
