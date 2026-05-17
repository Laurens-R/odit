package main

import "core:fmt"
import "core:time"
import "vendor:sdl3"
import "vendor:sdl3/ttf"

import "editor"

window: ^sdl3.Window
renderer: ^sdl3.Renderer
text_engine: ^ttf.TextEngine
font: ^ttf.Font
ed: editor.Editor

WINDOW_W :: 960
WINDOW_H :: 640
FONT_SIZE :: 16.0

init_sdl :: proc() -> bool {
	_ = sdl3.SetAppMetadata("odit", "0.1.0", "com.glowingideas.odit")

	if !sdl3.Init(sdl3.INIT_VIDEO) {
		sdl3.Log("Couldn't initialize SDL3")
		return false
	}

	if !ttf.Init() {
		sdl3.Log("Couldn't initialize SDL3_ttf")
		return false
	}

	if !sdl3.CreateWindowAndRenderer("odit", WINDOW_W, WINDOW_H, sdl3.WINDOW_RESIZABLE, &window, &renderer) {
		sdl3.Log("Couldn't create window and renderer.")
		return false
	}

	text_engine = ttf.CreateRendererTextEngine(renderer)
	if text_engine == nil {
		sdl3.Log("Couldn't create text engine.")
		return false
	}

	// Load a monospace font — try common system paths
	font = try_load_font()
	if font == nil {
		sdl3.Log("Couldn't load any monospace font.")
		return false
	}

	return true
}

try_load_font :: proc() -> ^ttf.Font {
	// Try bundled font first, then system fonts
	paths := []cstring{
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

	for path in paths {
		f := ttf.OpenFont(path, FONT_SIZE)
		if f != nil {
			return f
		}
	}
	return nil
}

destroy_sdl :: proc() {
	if font != nil { ttf.CloseFont(font) }
	if text_engine != nil { ttf.DestroyRendererTextEngine(text_engine) }
	ttf.Quit()
	sdl3.DestroyWindow(window)
	sdl3.DestroyRenderer(renderer)
	sdl3.Quit()
}

main :: proc() {
	if !init_sdl() {
		fmt.eprintln("Failed to initialize.")
		return
	}
	defer destroy_sdl()

	// Initialize editor
	editor.editor_init(&ed, text_engine, font, FONT_SIZE)
	defer editor.editor_destroy(&ed)

	// Start with SDL text input enabled
	_ = sdl3.StartTextInput(window)
	defer { _ = sdl3.StopTextInput(window) }

	// Welcome text
	editor.editor_open_string(&ed, "Welcome to odit.\nStart typing to edit.\n")

	running := true
	last_time := time.tick_now()

	for running {
		// Delta time
		now := time.tick_now()
		dt := time.duration_seconds(time.tick_diff(last_time, now))
		last_time = now

		event: sdl3.Event
		for sdl3.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				running = false
			case .KEY_DOWN:
				if event.key.key == sdl3.K_ESCAPE && !editor.editor_is_modal_open(&ed) {
					running = false
				} else {
					editor.editor_handle_event(&ed, &event)
				}
			case .TEXT_INPUT:
				editor.editor_handle_event(&ed, &event)
			case .MOUSE_WHEEL:
				editor.editor_handle_event(&ed, &event)
			case .MOUSE_BUTTON_DOWN:
				editor.editor_handle_event(&ed, &event)
			case .MOUSE_BUTTON_UP:
				editor.editor_handle_event(&ed, &event)
			case .MOUSE_MOTION:
				editor.editor_handle_event(&ed, &event)
			}
		}

		// Update
		editor.editor_update(&ed, dt)

		// Render
		w, h: i32
		sdl3.GetWindowSize(window, &w, &h)

		sdl3.SetRenderDrawColorFloat(renderer, 0.11, 0.11, 0.14, 1.0)
		sdl3.RenderClear(renderer)

		editor.editor_render(&ed, renderer, w, h)

		sdl3.RenderPresent(renderer)

		// Cap at ~60fps to avoid burning CPU
		sdl3.Delay(16)
	}
}
