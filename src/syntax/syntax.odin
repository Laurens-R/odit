package syntax

import "core:strings"

// --- Tokens ---------------------------------------------------------------

// Semantic kinds the renderer can color differently. Keep generic — language
// definitions map their own concepts onto these categories.
TokenKind :: enum u8 {
	Default,       // plain text, identifiers without classification
	Keyword,       // language keywords (if, for, return, …)
	Type,          // built-in / well-known type names
	String,        // string literals (includes opening / closing quotes)
	Number,        // numeric literals
	Comment,       // line and block comments
	Preprocessor,  // C-style preprocessor lines (#include, #define, …)
	Punctuation,   // operators, braces, semicolons (currently unused, reserved)
}

// A coloured run of bytes inside a single line of source. `start` and `end`
// are byte offsets within the line, with `start` inclusive and `end`
// exclusive.
Token :: struct {
	kind:  TokenKind,
	start: int,
	end:   int,
}

// --- Language definitions -------------------------------------------------

// One language's lexical rules. Mirrors the JSON schema 1:1 — see
// `src/syntax/languages/*.json`. Add languages by dropping another file
// into that directory and registering it in `loader.odin`.
//
// `block_comment_start` / `block_comment_end` are paired; leave both ""
// for languages with no block comments (e.g. plain JSON).
Definition :: struct {
	name:                string,
	extensions:          []string,
	line_comment:        string,
	block_comment_start: string,
	block_comment_end:   string,
	preprocessor_prefix: string,  // "#" for C-likes, "" otherwise
	keywords:            []string,
	types:               []string,
}

// --- Registry -------------------------------------------------------------

@(private="file")
g_definitions: [dynamic]^Definition

// Register a parsed definition with the global registry. Called once per
// language at startup (see `init`).
@(private)
register :: proc(def: ^Definition) {
	append(&g_definitions, def)
}

// Look up the definition for a given file path by examining its extension.
// Returns nil when no language matches (the renderer then falls back to
// plain text rendering).
get_definition_for_path :: proc(path: string) -> ^Definition {
	if len(path) == 0 { return nil }

	// Find the last '.'
	dot := -1
	for i := len(path) - 1; i >= 0; i -= 1 {
		c := path[i]
		if c == '/' || c == '\\' { break }
		if c == '.' { dot = i; break }
	}
	if dot < 0 || dot == len(path) - 1 { return nil }

	ext := path[dot + 1:]
	for def in g_definitions {
		for e in def.extensions {
			if strings.equal_fold(e, ext) {
				return def
			}
		}
	}
	return nil
}

// --- Lifecycle ------------------------------------------------------------

// Parses every embedded language JSON, registers each definition.
init :: proc() {
	load_builtin_definitions()
}

// Tear down everything `init` allocated.
destroy :: proc() {
	for def in g_definitions {
		free_definition(def)
	}
	delete(g_definitions)
	g_definitions = nil
}

@(private="file")
free_definition :: proc(def: ^Definition) {
	delete(def.name)
	for s in def.extensions { delete(s) }
	delete(def.extensions)
	delete(def.line_comment)
	delete(def.block_comment_start)
	delete(def.block_comment_end)
	delete(def.preprocessor_prefix)
	for s in def.keywords { delete(s) }
	delete(def.keywords)
	for s in def.types { delete(s) }
	delete(def.types)
	free(def)
}
