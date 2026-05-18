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
	Symbol,        // identifiers declared in the current file (functions, types, …)
}

// Coarse symbol classification. Used to display a short tag in the F6
// jump-to-symbol dialog and could feed per-kind coloring in the future.
SymbolKind :: enum u8 {
	Function,
	Type,
	Variable,
	Module,
	Other,
}

// One declared symbol in the active file. `column` is the byte offset of the
// symbol's name inside the line (NOT the start of its declaration), so
// jumping to it places the cursor on the name itself. `depth` is the brace
// nesting depth at the point the symbol was declared — 0 for package/file
// scope, +1 inside each `{ … }` block — and is used by the F6 dialog to
// group symbols visually under their enclosing parent.
Symbol :: struct {
	name:   string, // owned
	kind:   SymbolKind,
	line:   u32,
	column: u32,
	depth:  u8,
}

// One token inside a symbol pattern. Patterns are whitespace-separated lists
// of tokens matched against a line's lexeme stream. Anything in `{ ... }` is
// a placeholder; anything else is a literal that must equal the lexeme text.
//
// Placeholders:
//   {NAME}    - captures any identifier-like lexeme as the symbol's name
//               (keywords are refused so `if`, `while`, … never get caught)
//   {TYPE}    - matches a type identifier: a built-in name from `types` OR a
//               user-declared Type-kind symbol elsewhere in the same file
//   {NOTHING} - zero-width anchor; only matches when the current position is
//               at the very start of the line's lexeme stream (whitespace
//               and comments do not count, since the lexer already skips
//               them). Use this to prevent patterns like `{NAME} :` from
//               firing inside `case .QUIT:` or `func(x, y):` etc.
//   {ANY}     - matches exactly one lexeme of any kind (useful as a single-
//               lexeme wildcard between known tokens)
//   ...       - non-greedy wildcard: consumes zero or more lexemes up to the
//               next pattern token. Lets you span arbitrary content, e.g.
//               `{NAME} :: proc ( ... ) -> {TYPE}` matches procs with any
//               parameter list. `{...}` is also accepted as a synonym.
//   {OPTIONAL:X} - tries to match X; if it doesn't match, skips it
//               (zero-width) and continues with the next token. X is any of
//               the placeholders above OR a literal word, e.g.
//               `{OPTIONAL:static} {OPTIONAL:const} {TYPE} {NAME} ( ... )`
//               collapses the static/const cross-product into one pattern.
//               Nested OPTIONAL and OPTIONAL-wrapped ellipsis are not
//               supported (they would be redundant).
//   {NOT:X}   - zero-width negative lookahead. Fails the pattern if X would
//               match at the current position; passes (without consuming
//               anything) if it doesn't. X is any of the placeholders above
//               or a literal word. Example: `{TYPE} {NOT:.} {NAME}` rejects
//               `MyType .field` while accepting `MyType var`.
//   {OPTION:A|B|C} - mandatory alternation; the pattern fails unless one of
//               the pipe-separated alternatives matches at the current
//               position. Each alternative is a placeholder (`NAME`, `TYPE`,
//               `ANY`, …) or a literal word. Example:
//               `{OPTION:public|private|protected} {TYPE} {NAME} ( ... )`
//               matches a method declared with any of the three access
//               keywords but no other prefix.
//
// Legacy: a bare `NAME` (without braces) is still accepted as `{NAME}` so
// existing language definitions keep working.
PatternTokenKind :: enum u8 {
	Literal,  // exact text match (`text` field holds the token)
	Name,     // {NAME}    — capture identifier
	Type,     // {TYPE}    — built-in or user-declared type
	Nothing,  // {NOTHING} — zero-width: start-of-line anchor
	Any,      // {ANY}     — single-lexeme wildcard
	Ellipsis, // ...       — non-greedy run of zero or more lexemes
	Optional, // {OPTIONAL:X}    — try to match X; if it doesn't match, skip
	Not,      // {NOT:X}         — zero-width: fail if X would match here
	Option,   // {OPTION:A|B|C}  — mandatory alternation: exactly one must match
}

// Field roles by kind:
//   .Literal          → `text` holds the literal token
//   .Optional, .Not   → `inner_token` points to the wrapped sub-token. The
//                       inner can be any placeholder, a literal, or a fully
//                       nested OPTION (so `{OPTIONAL:{OPTION:A|B}}` works).
//   .Option           → `alternatives` holds one PatternToken per alternative
//   anything else     → fields unused
PatternToken :: struct {
	kind:         PatternTokenKind,
	text:         string,           // owned when kind == .Literal
	inner_token:  ^PatternToken,    // owned; populated for .Optional / .Not
	alternatives: []PatternToken,   // owned; populated for .Option
}

// A whitespace-separated pattern matched against the whole-file lexeme
// stream. See `extract_symbols_from_lines` for matching semantics and
// `PatternToken` for the placeholder vocabulary.
SymbolPattern :: struct {
	tokens: []PatternToken,
	kind:   SymbolKind,
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
//
// `scope_start` / `scope_end` are the lexeme texts that respectively open
// and close a nesting scope. The symbol matcher uses them to track depth
// and to bound the `...` ellipsis (it may stop at a scope token but not
// cross one). They default to `["{"]` / `["}"]` when the JSON omits them
// — every C-family definition continues to work unchanged. Languages
// whose blocks are delimited by keywords (VB's `Class … End Class`,
// `Sub … End Sub`, …) should populate these lists explicitly.
Definition :: struct {
	name:                string,
	extensions:          []string,
	line_comment:        string,
	block_comment_start: string,
	block_comment_end:   string,
	preprocessor_prefix: string,  // "#" for C-likes, "" otherwise
	keywords:            []string,
	types:               []string,
	scope_start:         []string,
	scope_end:           []string,
	symbol_patterns:     []SymbolPattern,
}

// --- Registry -------------------------------------------------------------

@(private="file")
global_language_definitions: [dynamic]^Definition

// Register a parsed definition with the global registry. Called once per
// language at startup (see `init`).
@(private)
register :: proc(definition: ^Definition) {
	append(&global_language_definitions, definition)
}

// Look up the definition for a given file path by examining its extension.
// Returns nil when no language matches (the renderer then falls back to
// plain text rendering).
get_definition_for_path :: proc(path: string) -> ^Definition {
	if len(path) == 0 { return nil }

	// Find the last '.'
	last_dot_index := -1
	for path_char_index := len(path) - 1; path_char_index >= 0; path_char_index -= 1 {
		path_character := path[path_char_index]
		if path_character == '/' || path_character == '\\' { break }
		if path_character == '.' { last_dot_index = path_char_index; break }
	}
	if last_dot_index < 0 || last_dot_index == len(path) - 1 { return nil }

	extension := path[last_dot_index + 1:]
	for language_definition in global_language_definitions {
		for definition_extension in language_definition.extensions {
			if strings.equal_fold(definition_extension, extension) {
				return language_definition
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
	for language_definition in global_language_definitions {
		free_definition(language_definition)
	}
	delete(global_language_definitions)
	global_language_definitions = nil
}

// Recursively release everything a PatternToken owns: its literal text, any
// nested `inner_token` sub-token (Optional / Not), and any alternation
// `alternatives`. Cleanup walks the same shape the loader built, so changes
// here must stay in lockstep with `parse_pattern_token` / `parse_inner_token`.
@(private)
free_pattern_token :: proc(pattern_token: PatternToken) {
	if pattern_token.kind == .Literal { delete(pattern_token.text) }
	if pattern_token.inner_token != nil {
		free_pattern_token(pattern_token.inner_token^)
		free(pattern_token.inner_token)
	}
	if pattern_token.alternatives != nil {
		for alternative in pattern_token.alternatives { free_pattern_token(alternative) }
		delete(pattern_token.alternatives)
	}
}

@(private="file")
free_definition :: proc(language_definition: ^Definition) {
	delete(language_definition.name)
	for extension_string in language_definition.extensions { delete(extension_string) }
	delete(language_definition.extensions)
	delete(language_definition.line_comment)
	delete(language_definition.block_comment_start)
	delete(language_definition.block_comment_end)
	delete(language_definition.preprocessor_prefix)
	for keyword_string in language_definition.keywords { delete(keyword_string) }
	delete(language_definition.keywords)
	for type_string in language_definition.types { delete(type_string) }
	delete(language_definition.types)
	for scope_start_string in language_definition.scope_start { delete(scope_start_string) }
	delete(language_definition.scope_start)
	for scope_end_string in language_definition.scope_end { delete(scope_end_string) }
	delete(language_definition.scope_end)
	for pattern in language_definition.symbol_patterns {
		for pattern_token in pattern.tokens { free_pattern_token(pattern_token) }
		delete(pattern.tokens)
	}
	delete(language_definition.symbol_patterns)
	free(language_definition)
}
