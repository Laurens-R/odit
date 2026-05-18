package ui

import "core:strings"
import "vendor:sdl3/ttf"

// FIFO cache of `^ttf.Text` objects keyed by string content. The editor and
// terminal both render a lot of small text runs every frame, and most of
// those strings repeat unchanged from one frame to the next (a line of code,
// a syntax token, a shell prompt). Without caching, every run pays for a
// fresh `ttf.CreateText` + `ttf.DestroyText` pair — each is effectively a
// small GPU texture allocation, and SDL_ttf shapes the text each time.
//
// The cache is intentionally minimal:
//   * String key (cloned with the default allocator) is hashed via the
//     standard map; entries also live in a ring buffer so we can evict in
//     a single index step when the cache fills.
//   * On a hit we just hand back the existing `^ttf.Text`; the caller sets
//     the color and draws.
//   * On a miss we evict whatever's at `head`, clone the key, and create a
//     fresh `^ttf.Text` in its place.
//
// The cache holds GPU resources — call `text_cache_destroy` to release
// them. Call `text_cache_clear` when the font (size) changes so cached
// shaped runs don't render at the wrong metrics.
TextCache :: struct {
	engine:  ^ttf.TextEngine,
	font:    ^ttf.Font,
	by_key:  map[string]int,
	entries: []TextCacheEntry,
	head:    int,
	cap:     int,
}

@(private)
TextCacheEntry :: struct {
	text: ^ttf.Text,
	key:  string, // owned by the cache
}

text_cache_init :: proc(cache: ^TextCache, engine: ^ttf.TextEngine, font: ^ttf.Font, capacity: int = 1024) {
	cache.engine  = engine
	cache.font    = font
	cache.cap     = capacity
	cache.entries = make([]TextCacheEntry, capacity)
	cache.head    = 0
}

text_cache_destroy :: proc(cache: ^TextCache) {
	if cache == nil { return }
	for entry in cache.entries {
		if entry.text != nil { ttf.DestroyText(entry.text) }
		if len(entry.key) > 0 { delete(entry.key) }
	}
	delete(cache.entries)
	delete(cache.by_key)
	cache.entries = nil
	cache.by_key  = nil
}

// Drop every cached entry. Use after a font-size change so the next frame
// re-shapes everything at the new metrics.
text_cache_clear :: proc(cache: ^TextCache) {
	if cache == nil { return }
	for i in 0..<len(cache.entries) {
		if cache.entries[i].text != nil {
			ttf.DestroyText(cache.entries[i].text)
			cache.entries[i].text = nil
		}
		if len(cache.entries[i].key) > 0 {
			delete(cache.entries[i].key)
			cache.entries[i].key = ""
		}
	}
	clear(&cache.by_key)
	cache.head = 0
}

// Look up `text` in the cache, creating + caching it if needed. Returns the
// `^ttf.Text` (or nil on creation failure). The cache retains ownership.
text_cache_get :: proc(cache: ^TextCache, text: string) -> ^ttf.Text {
	if cache == nil || cache.engine == nil || cache.font == nil || cache.cap == 0 {
		return nil
	}

	if idx, ok := cache.by_key[text]; ok {
		return cache.entries[idx].text
	}

	idx := cache.head
	cache.head = (cache.head + 1) % cache.cap

	// Evict whatever was there.
	if old := cache.entries[idx].text; old != nil {
		ttf.DestroyText(old)
		cache.entries[idx].text = nil
	}
	if old_key := cache.entries[idx].key; len(old_key) > 0 {
		delete_key(&cache.by_key, old_key)
		delete(old_key)
		cache.entries[idx].key = ""
	}

	cstr := strings.clone_to_cstring(text, context.temp_allocator)
	new_text := ttf.CreateText(cache.engine, cache.font, cstr, 0)
	if new_text == nil { return nil }

	new_key := strings.clone(text)
	cache.entries[idx] = TextCacheEntry{ text = new_text, key = new_key }
	cache.by_key[new_key] = idx
	return new_text
}
