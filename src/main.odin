package main;

import "core:fmt"
import "vendor:sdl3"
import "vendor:sdl3/ttf"

window : ^sdl3.Window;
renderer :^sdl3.Renderer;
text : ^ttf.TextEngine;
font : ^ttf.Font;

STATUS_ERROR :: 1;
STATUS_OK :: 0;

init_sdl :: proc() -> bool { 
	result := sdl3.SetAppMetadata("My example", "1.0", "com.glowingideas.odit");

	if !sdl3.Init(sdl3.INIT_VIDEO) {
		sdl3.Log("Couldn't initialize SDL3");
		return false;
	}

	if !sdl3.CreateWindowAndRenderer("odit", 640, 480, sdl3.WINDOW_RESIZABLE, &window, &renderer) { 
		sdl3.Log("Couldn't create window and renderer.");
		return false;
	}

	sdl3.SetRenderLogicalPresentation(renderer, 640, 480, sdl3.RendererLogicalPresentation.LETTERBOX);

	text = ttf.CreateRendererTextEngine(renderer);

	return true;
}

destroy_sdl :: proc() {
	ttf.DestroyRendererTextEngine(text);
	sdl3.DestroyWindow(window);
	sdl3.DestroyRenderer(renderer);
	sdl3.Quit();
}

main :: proc() {

	if !init_sdl() {
		return;
	}

	defer destroy_sdl();	
	
	running := true;

	for running {
		event : sdl3.Event;

		for sdl3.PollEvent(&event) {
			#partial switch event.type {
				case .QUIT:
					running = false;
				case .KEY_DOWN:
					if(event.key.key == sdl3.K_ESCAPE) {
						running = false;
					}
			}
		}

		sdl3.SetRenderDrawColor(renderer, 0, 0, 0, 1);
		sdl3.RenderClear(renderer);
		sdl3.RenderPresent(renderer);
	}
}