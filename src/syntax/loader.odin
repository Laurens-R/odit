package syntax

import "core:encoding/json"
import "core:strings"

// Mirrors the JSON schema. Distinct from `Definition` so we can carefully
// re-own each string out of the temporary JSON allocator and into our
// long-lived registry.
@(private="file")
DefinitionJSON :: struct {
	name:                string,
	extensions:          []string,
	line_comment:        string,
	block_comment_start: string,
	block_comment_end:   string,
	preprocessor_prefix: string,
	keywords:            []string,
	types:               []string,
}

// Each language is embedded at compile time so the binary is self-contained.
// Add a new language by dropping its JSON file into `src/syntax/languages/`
// and appending a `#load` entry to this slice.
@(private="file")
LANGUAGE_BLOBS := [?]string{
	#load("languages/odin.json",       string),
	#load("languages/cpp.json",        string),
	#load("languages/javascript.json", string),
	#load("languages/typescript.json", string),
	#load("languages/json.json",       string),
}

@(private)
load_builtin_definitions :: proc() {
	for blob in LANGUAGE_BLOBS {
		raw: DefinitionJSON
		if err := json.unmarshal_string(blob, &raw, allocator = context.temp_allocator); err != nil {
			continue // skip malformed — silent fallback to plain rendering
		}

		def := new(Definition)
		def.name                = strings.clone(raw.name)
		def.extensions          = clone_string_slice(raw.extensions)
		def.line_comment        = strings.clone(raw.line_comment)
		def.block_comment_start = strings.clone(raw.block_comment_start)
		def.block_comment_end   = strings.clone(raw.block_comment_end)
		def.preprocessor_prefix = strings.clone(raw.preprocessor_prefix)
		def.keywords            = clone_string_slice(raw.keywords)
		def.types               = clone_string_slice(raw.types)
		register(def)
	}
}

@(private="file")
clone_string_slice :: proc(src: []string) -> []string {
	out := make([]string, len(src))
	for s, i in src { out[i] = strings.clone(s) }
	return out
}
