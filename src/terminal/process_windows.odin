#+build windows
package terminal

import win32 "core:sys/windows"

// ConPTY-flavored process state. We keep separate "host" handles (what the
// parent reads/writes) and "pty" handles (what gets handed to the child via
// CreatePseudoConsole). The pty handles get closed right after the console
// is created — they're owned by the kernel from that point on.
PtyState :: struct {
	pseudo_console_handle:    HPCON,
	process_handle:           win32.HANDLE,
	thread_handle:            win32.HANDLE,
	pipe_to_shell_stdin:      win32.HANDLE, // host writes to shell stdin
	pipe_from_shell_stdout:   win32.HANDLE, // host reads from shell stdout/stderr
	attribute_list:           rawptr,
	attribute_list_size:      win32.SIZE_T,
}

HPCON :: distinct rawptr

EXTENDED_STARTUPINFO_PRESENT          :: 0x00080000
PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE   :: 0x00020016

STARTUPINFOEXW :: struct {
	StartupInfo:     win32.STARTUPINFOW,
	lpAttributeList: rawptr,
}

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention="system")
foreign kernel32 {
	CreatePseudoConsole :: proc(
		size:        win32.COORD,
		h_input:     win32.HANDLE,
		h_output:    win32.HANDLE,
		dw_flags:    win32.DWORD,
		ph_pc:       ^HPCON,
	) -> win32.HRESULT ---

	ResizePseudoConsole :: proc(h_pc: HPCON, size: win32.COORD) -> win32.HRESULT ---

	ClosePseudoConsole :: proc(h_pc: HPCON) ---

	InitializeProcThreadAttributeList :: proc(
		lp_attribute_list:  rawptr,
		dw_attribute_count: win32.DWORD,
		dw_flags:           win32.DWORD,
		lp_size:            ^win32.SIZE_T,
	) -> win32.BOOL ---

	UpdateProcThreadAttribute :: proc(
		lp_attribute_list:  rawptr,
		dw_flags:           win32.DWORD,
		attribute:          uintptr,
		lp_value:           rawptr,
		cb_size:            win32.SIZE_T,
		lp_previous_value:  rawptr,
		lp_return_size:     ^win32.SIZE_T,
	) -> win32.BOOL ---

	DeleteProcThreadAttributeList :: proc(lp_attribute_list: rawptr) ---
}

// Spawn powershell.exe attached to a fresh pseudo-console sized columns x rows.
// On success, `terminal.pty_state` is fully populated and ready for read/write.
// On failure, everything is closed and the proc returns false; the caller
// typically falls back to "no terminal".
@(private)
pty_spawn :: proc(terminal: ^Terminal, columns, rows: i32) -> bool {
	pty_state := &terminal.pty_state
	pty_state^ = PtyState{}

	// Two pairs of anonymous pipes — one in each direction.
	pty_input_read_handle,    pty_input_write_handle:  win32.HANDLE
	pty_output_read_handle,   pty_output_write_handle: win32.HANDLE

	security_attributes := win32.SECURITY_ATTRIBUTES{}
	security_attributes.nLength = size_of(win32.SECURITY_ATTRIBUTES)
	security_attributes.bInheritHandle = true

	if !win32.CreatePipe(&pty_input_read_handle,  &pty_input_write_handle,  &security_attributes, 0) { return false }
	if !win32.CreatePipe(&pty_output_read_handle, &pty_output_write_handle, &security_attributes, 0) {
		win32.CloseHandle(pty_input_read_handle);  win32.CloseHandle(pty_input_write_handle)
		return false
	}

	console_size := win32.COORD{ X = i16(columns), Y = i16(rows) }
	creation_result := CreatePseudoConsole(console_size, pty_input_read_handle, pty_output_write_handle, 0, &pty_state.pseudo_console_handle)
	// CreatePseudoConsole duplicates the handles it cares about; we can
	// close the child-side pipes once the call returns.
	win32.CloseHandle(pty_input_read_handle)
	win32.CloseHandle(pty_output_write_handle)
	if creation_result != 0 {
		win32.CloseHandle(pty_input_write_handle); win32.CloseHandle(pty_output_read_handle)
		return false
	}

	pty_state.pipe_to_shell_stdin    = pty_input_write_handle
	pty_state.pipe_from_shell_stdout = pty_output_read_handle

	// Build the STARTUPINFOEX with one extended attribute carrying the pseudo-console handle.
	attribute_list_size_needed: win32.SIZE_T
	InitializeProcThreadAttributeList(nil, 1, 0, &attribute_list_size_needed)
	pty_state.attribute_list      = raw_alloc(int(attribute_list_size_needed))
	pty_state.attribute_list_size = attribute_list_size_needed
	if pty_state.attribute_list == nil {
		pty_close(terminal); pty_finalize(terminal)
		return false
	}
	if !InitializeProcThreadAttributeList(pty_state.attribute_list, 1, 0, &attribute_list_size_needed) {
		pty_close(terminal); pty_finalize(terminal)
		return false
	}
	if !UpdateProcThreadAttribute(
		pty_state.attribute_list,
		0,
		PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
		rawptr(pty_state.pseudo_console_handle),
		size_of(HPCON),
		nil,
		nil,
	) {
		pty_close(terminal); pty_finalize(terminal)
		return false
	}

	startup_info := STARTUPINFOEXW{}
	startup_info.StartupInfo.cb = u32(size_of(STARTUPINFOEXW))
	startup_info.lpAttributeList = pty_state.attribute_list

	// Build the command line in a writable wide buffer — CreateProcessW
	// requires lpCommandLine to be mutable.
	command_line_wstring := win32.utf8_to_wstring(`powershell.exe -NoLogo`)

	process_information := win32.PROCESS_INFORMATION{}
	process_created := win32.CreateProcessW(
		nil,                          // lpApplicationName
		command_line_wstring,         // lpCommandLine (writable wstring)
		nil, nil,
		false,                        // bInheritHandles — handles flow via the attribute list
		EXTENDED_STARTUPINFO_PRESENT,
		nil, nil,
		&startup_info.StartupInfo,
		&process_information,
	)
	if !process_created {
		pty_close(terminal); pty_finalize(terminal)
		return false
	}

	pty_state.process_handle = process_information.hProcess
	pty_state.thread_handle  = process_information.hThread
	return true
}

// Phase 1 of shutdown — terminate the child and close the host-side pipes.
// Doing the kill first means ClosePseudoConsole (called later in
// `pty_finalize`) won't sit there waiting for the shell to exit. Closing
// `pipe_from_shell_stdout` is what releases a ReadFile that the reader
// thread might be blocked in, so this MUST run before joining that thread.
@(private)
pty_close :: proc(terminal: ^Terminal) {
	pty_state := &terminal.pty_state

	if pty_state.process_handle != nil {
		win32.TerminateProcess(pty_state.process_handle, 0)
	}
	if pty_state.pipe_to_shell_stdin != nil {
		win32.CloseHandle(pty_state.pipe_to_shell_stdin);  pty_state.pipe_to_shell_stdin = nil
	}
	if pty_state.pipe_from_shell_stdout != nil {
		win32.CloseHandle(pty_state.pipe_from_shell_stdout); pty_state.pipe_from_shell_stdout = nil
	}
}

// Phase 2 of shutdown — only safe once the reader thread is no longer
// touching anything in `terminal.pty_state`. Releases the pseudo-console,
// the process / thread handles, and the proc-thread attribute list.
@(private)
pty_finalize :: proc(terminal: ^Terminal) {
	pty_state := &terminal.pty_state

	if pty_state.pseudo_console_handle != nil {
		ClosePseudoConsole(pty_state.pseudo_console_handle);   pty_state.pseudo_console_handle = nil
	}
	if pty_state.process_handle != nil {
		win32.CloseHandle(pty_state.process_handle);  pty_state.process_handle = nil
	}
	if pty_state.thread_handle != nil {
		win32.CloseHandle(pty_state.thread_handle); pty_state.thread_handle = nil
	}
	if pty_state.attribute_list != nil {
		DeleteProcThreadAttributeList(pty_state.attribute_list)
		raw_free(pty_state.attribute_list)
		pty_state.attribute_list = nil
	}
}

@(private)
pty_resize :: proc(terminal: ^Terminal, columns, rows: i32) {
	if terminal.pty_state.pseudo_console_handle == nil { return }
	ResizePseudoConsole(terminal.pty_state.pseudo_console_handle, win32.COORD{ X = i16(columns), Y = i16(rows) })
}

// Poll the output pipe instead of blocking on `ReadFile` directly.
//
// On Windows, `CloseHandle` from another thread does NOT reliably unblock a
// synchronous `ReadFile` already in progress — the reader stays parked and a
// subsequent `thread.join` hangs forever. So we use `PeekNamedPipe` first:
// it returns immediately, tells us how many bytes are queued, and surfaces
// pipe-closed errors. When nothing is available we yield with a short
// `Sleep` so `terminal.is_alive` gets reconsulted on the next loop
// iteration. That's the actual shutdown signal — the reader notices it and
// exits on its own.
@(private)
pty_read :: proc(terminal: ^Terminal, read_buffer: []u8) -> (bytes_read: int, read_succeeded: bool) {
	if terminal.pty_state.pipe_from_shell_stdout == nil { return 0, false }

	bytes_available: u32
	if !win32.PeekNamedPipe(terminal.pty_state.pipe_from_shell_stdout, nil, 0, nil, &bytes_available, nil) {
		// Pipe broken / closed → tell the caller to bail out of its loop.
		return 0, false
	}
	if bytes_available == 0 {
		// Idle-wait briefly so we're not pegging a core, then surface a
		// "successful zero-byte read" so the caller can re-check is_alive.
		win32.Sleep(10)
		return 0, true
	}

	bytes_to_read := u32(len(read_buffer))
	if bytes_to_read > bytes_available { bytes_to_read = bytes_available }

	bytes_actually_read: u32
	if !win32.ReadFile(terminal.pty_state.pipe_from_shell_stdout, raw_data(read_buffer), bytes_to_read, &bytes_actually_read, nil) {
		return 0, false
	}
	return int(bytes_actually_read), true
}

@(private)
pty_write :: proc(terminal: ^Terminal, data: []u8) -> int {
	if terminal.pty_state.pipe_to_shell_stdin == nil || len(data) == 0 { return 0 }
	bytes_written: u32
	if !win32.WriteFile(terminal.pty_state.pipe_to_shell_stdin, raw_data(data), u32(len(data)), &bytes_written, nil) {
		return 0
	}
	return int(bytes_written)
}

// --- Helpers ------------------------------------------------------------

@(private="file")
raw_alloc :: proc(byte_count: int) -> rawptr {
	process_heap_handle := win32.GetProcessHeap()
	return win32.HeapAlloc(process_heap_handle, 0, win32.SIZE_T(byte_count))
}

@(private="file")
raw_free :: proc(pointer_to_free: rawptr) {
	if pointer_to_free == nil { return }
	process_heap_handle := win32.GetProcessHeap()
	win32.HeapFree(process_heap_handle, 0, pointer_to_free)
}
