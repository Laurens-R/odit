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
//   * On a miss we evict whatever's at `next_eviction_index`, clone the key,
//     and create a fresh `^ttf.Text` in its place.
//
// The cache holds GPU resources — call `text_cache_destroy` to release
// them. Call `text_cache_clear` when the font (size) changes so cached
// shaped runs don't render at the wrong metrics.
TextCache :: struct {
	engine:               ^ttf.TextEngine,
	font:                 ^ttf.Font,
	entries_by_key:       map[string]int,
	entries:              []TextCacheEntry,
	next_eviction_index:  int,
	capacity:             int,
}

@(private)
TextCacheEntry :: struct {
	text_object: ^ttf.Text,
	key:         string, // owned by the cache
}

text_cache_init :: proc(cache: ^TextCache, engine: ^ttf.TextEngine, font: ^ttf.Font, capacity: int = 1024) {
	cache.engine               = engine
	cache.font                 = font
	cache.capacity             = capacity
	cache.entries              = make([]TextCacheEntry, capacity)
	cache.next_eviction_index  = 0
}

text_cache_destroy :: proc(cache: ^TextCache) {
	if cache == nil { return }
	for entry in cache.entries {
		if entry.text_object != nil { ttf.DestroyText(entry.text_object) }
		if len(entry.key) > 0 { delete(entry.key) }
	}
	delete(cache.entries)
	delete(cache.entries_by_key)
	cache.entries        = nil
	cache.entries_by_key = nil
}

// Drop every cached entry. Use after a font-size change so the next frame
// re-shapes everything at the new metrics.
text_cache_clear :: proc(cache: ^TextCache) {
	if cache == nil { return }
	for entry_index in 0..<len(cache.entries) {
		if cache.entries[entry_index].text_object != nil {
			ttf.DestroyText(cache.entries[entry_index].text_object)
			cache.entries[entry_index].text_object = nil
		}
		if len(cache.entries[entry_index].key) > 0 {
			delete(cache.entries[entry_index].key)
			cache.entries[entry_index].key = ""
		}
	}
	clear(&cache.entries_by_key)
	cache.next_eviction_index = 0
}

// Look up `text` in the cache, creating + caching it if needed. Returns the
// `^ttf.Text` (or nil on creation failure). The cache retains ownership.
text_cache_get :: proc(cache: ^TextCache, text: string) -> ^ttf.Text {
	if cache == nil || cache.engine == nil || cache.font == nil || cache.capacity == 0 {
		return nil
	}

	if existing_entry_index, found := cache.entries_by_key[text]; found {
		return cache.entries[existing_entry_index].text_object
	}

	entry_index := cache.next_eviction_index
	cache.next_eviction_index = (cache.next_eviction_index + 1) % cache.capacity

	// Evict whatever was there.
	if old_text_object := cache.entries[entry_index].text_object; old_text_object != nil {
		ttf.DestroyText(old_text_object)
		cache.entries[entry_index].text_object = nil
	}
	if old_key := cache.entries[entry_index].key; len(old_key) > 0 {
		delete_key(&cache.entries_by_key, old_key)
		delete(old_key)
		cache.entries[entry_index].key = ""
	}

	text_as_c_string := strings.clone_to_cstring(text, context.temp_allocator)
	new_text_object := ttf.CreateText(cache.engine, cache.font, text_as_c_string, 0)
	if new_text_object == nil { return nil }

	new_key := strings.clone(text)
	cache.entries[entry_index] = TextCacheEntry{ text_object = new_text_object, key = new_key }
	cache.entries_by_key[new_key] = entry_index
	return new_text_object
}
