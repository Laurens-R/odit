package main

import "core:bytes"
import "core:fmt"
import "core:image"
import "core:image/png"
import "core:time"
import "vendor:sdl3"
import "vendor:sdl3/ttf"

import "editor"
import "keybindings"

window: ^sdl3.Window
renderer: ^sdl3.Renderer
text_engine: ^ttf.TextEngine
font: ^ttf.Font
editor_state: editor.Editor

WINDOW_WIDTH :: 1920
WINDOW_HEIGHT :: 1080
FONT_SIZE :: 16.0

init_sdl :: proc() -> bool
{
	_ = sdl3.SetAppMetadata("odit", "0.1.0", "com.glowingideas.odit")

	if !sdl3.Init(sdl3.INIT_VIDEO)
	{
		sdl3.Log("Couldn't initialize SDL3")
		return false
	}

	if !ttf.Init()
	{
		sdl3.Log("Couldn't initialize SDL3_ttf")
		return false
	}

	if !sdl3.CreateWindowAndRenderer(
		"odit",
		WINDOW_WIDTH,
		WINDOW_HEIGHT,
		sdl3.WINDOW_RESIZABLE,
		&window,
		&renderer,
	)
	{
		sdl3.Log("Couldn't create window and renderer.")
		return false
	}

	// Window / taskbar icon. Sourced from `vendor/icon/icon.bmp` (staged
	// to `<exe_dir>/icon/icon.bmp` by the build scripts). Best-effort:
	// failure here is a missing-file cosmetic glitch, not a startup blocker.
	try_apply_window_icon()

	text_engine = ttf.CreateRendererTextEngine(renderer)
	if text_engine == nil
	{
		sdl3.Log("Couldn't create text engine.")
		return false
	}

	// Load a monospace font — try common system paths
	font = try_load_font()
	if font == nil
	{
		sdl3.Log("Couldn't load any monospace font.")
		return false
	}

	return true
}

// Load the bundled PNG icon (if present) and hand it to SDL. Decoded with
// core:image/png so we don't have to ship SDL_image as a runtime dep —
// PNG is the only image format we care about here, and core handles it
// fine. Silently skipped when the file is absent; the OS shows its
// generic placeholder.
try_apply_window_icon :: proc()
{
	// `icon/icon.png` is the build-staged location (`vendor/icon/icon.png`
	// → `out/<target>/<config>/icon/icon.png`); `icon.png` is checked as a
	// convenience for users who drop the file next to the binary directly.
	candidate_paths := []string{"icon/icon.png", "icon.png"}
	for path in candidate_paths
	{
		// `alpha_add_if_missing` guarantees a 4-channel RGBA8 result so
		// the surface format below always matches; PNGs without an alpha
		// channel get an opaque one synthesised.
		decoded_image, decode_error := png.load_from_file(
			path,
			image.Options{.alpha_add_if_missing},
		)
		if decode_error != nil || decoded_image == nil
		{continue}
		defer image.destroy(decoded_image)

		if decoded_image.channels != 4 || decoded_image.depth != 8
		{continue}

		pixel_bytes := bytes.buffer_to_bytes(&decoded_image.pixels)
		// SDL.RGBA32 is the memory-order alias (handles endianness for us)
		// so the byte layout from core:image/png lines up regardless of
		// host platform.
		icon_surface := sdl3.CreateSurfaceFrom(
			i32(decoded_image.width),
			i32(decoded_image.height),
			.RGBA32,
			raw_data(pixel_bytes),
			i32(decoded_image.width * 4),
		)
		if icon_surface == nil
		{continue}

		_ = sdl3.SetWindowIcon(window, icon_surface)
		// SetWindowIcon copies the pixel data into the window's own
		// storage, so we can drop the surface (and the pixel buffer via
		// the deferred image.destroy) immediately.
		sdl3.DestroySurface(icon_surface)
		return
	}
}

try_load_font :: proc() -> ^ttf.Font
{
	// Try bundled font first, then system fonts
	candidate_font_paths := []cstring \
	{
		"font.ttf",
		"fonts/font.ttf",
		// Windows
		"C:/Windows/Fonts/consola.ttf",
		"C:/Windows/Fonts/CascadiaMono.ttf",
		"C:/Windows/Fonts/lucon.ttf",
		// Linux
		"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
		// macOS
		"/System/Library/Fonts/SFMono-Regular.otf",
		"/System/Library/Fonts/Menlo.ttc",
	}

	for font_path in candidate_font_paths
	{
		loaded_font := ttf.OpenFont(font_path, FONT_SIZE)
		if loaded_font != nil
		{
			return loaded_font
		}
	}
	return nil
}

destroy_sdl :: proc()
{
	if font != nil
	{ttf.CloseFont(font)}
	if text_engine != nil
	{ttf.DestroyRendererTextEngine(text_engine)}
	ttf.Quit()
	sdl3.DestroyWindow(window)
	sdl3.DestroyRenderer(renderer)
	sdl3.Quit()
}

main :: proc()
{
	if !init_sdl()
	{
		fmt.eprintln("Failed to initialize.")
		return
	}
	defer destroy_sdl()

	// Initialize editor
	editor.editor_init(&editor_state, text_engine, font, FONT_SIZE)
	defer editor.editor_destroy(&editor_state)

	// Start with SDL text input enabled
	_ = sdl3.StartTextInput(window)
	defer
	{_ = sdl3.StopTextInput(window)}

	is_running := true
	last_tick_time := time.tick_now()

	for is_running
	{
		// Delta time
		current_tick_time := time.tick_now()
		delta_time := time.duration_seconds(
			time.tick_diff(last_tick_time, current_tick_time),
		)
		last_tick_time = current_tick_time

		sdl_event: sdl3.Event
		for sdl3.PollEvent(&sdl_event)
		{
			#partial switch sdl_event.type
			{
			case .QUIT:
				is_running = false
			case .KEY_DOWN:
				// Quit is the only shortcut main.odin handles directly — the
				// editor can't service it itself because that would leave the
				// outer event loop running with a torn-down editor. Looking it
				// up through the same keybindings table keeps the JSON the
				// single source of truth.
				if keybindings.lookup(
					   &editor_state.keybindings,
					   sdl_event.key.key,
					   sdl_event.key.mod,
				   ) ==
				   .Quit
				{
					is_running = false
				}
				 else
				{
					editor.editor_handle_event(&editor_state, &sdl_event)
				}
			case .TEXT_INPUT:
				editor.editor_handle_event(&editor_state, &sdl_event)
			case .MOUSE_WHEEL:
				editor.editor_handle_event(&editor_state, &sdl_event)
			case .MOUSE_BUTTON_DOWN:
				editor.editor_handle_event(&editor_state, &sdl_event)
			case .MOUSE_BUTTON_UP:
				editor.editor_handle_event(&editor_state, &sdl_event)
			case .MOUSE_MOTION:
				editor.editor_handle_event(&editor_state, &sdl_event)
			case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_EXPOSED:
				editor.editor_mark_dirty(&editor_state)
			}
		}

		// File > Quit (or anything else that sets the flag) ends the loop.
		if editor_state.quit_requested
		{is_running = false}

		// Update — animations / blink / terminal drain all live here. The
		// editor flips its own `needs_redraw` flag when anything visible
		// changes, so the render path below is free to skip work on idle
		// frames.
		editor.editor_update(&editor_state, delta_time)

		if editor.editor_needs_render(&editor_state)
		{
			current_window_width, current_window_height: i32
			sdl3.GetWindowSize(
				window,
				&current_window_width,
				&current_window_height,
			)

			sdl3.SetRenderDrawColorFloat(renderer, 0.11, 0.11, 0.14, 1.0)
			sdl3.RenderClear(renderer)

			editor.editor_render(
				&editor_state,
				renderer,
				current_window_width,
				current_window_height,
			)

			sdl3.RenderPresent(renderer)
			editor.editor_mark_clean(&editor_state)
			// Status-bar FPS readout. Hooked here (not in editor_update) so it
			// measures actual presented frames rather than loop iterations —
			// otherwise the number would just track main.odin's sleep budget.
			editor.editor_record_frame_presented(&editor_state, delta_time)
		}

		// Release every per-frame temp_allocator alloc — line displays,
		// syntax token buffers, scratch strings, etc. — before sleeping.
		// Without this, the scratch arena keeps growing every frame the
		// editor renders or the terminal drains output, eventually
		// spilling into the heap as a permanent leak.
		free_all(context.temp_allocator)

		sdl3.Delay(1)
	}
}
