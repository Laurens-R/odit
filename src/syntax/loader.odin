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
	scope_start:         []string,
	scope_end:           []string,
	symbol_patterns:     []SymbolPatternJSON,
}

@(private="file")
SymbolPatternJSON :: struct {
	pattern: string, // whitespace-separated, with "NAME" as the capture slot
	kind:    string, // "Function" | "Type" | "Variable" | "Module" | "Other"
}

// Each language is embedded at compile time so the binary is self-contained.
// Add a new language by dropping its JSON file into `src/syntax/languages/`
// and appending a `#load` entry to this slice.
@(private="file")
LANGUAGE_BLOBS := [?]string{
	#load("languages/odin.json",         string),
	#load("languages/cpp.json",          string),
	#load("languages/javascript.json",   string),
	#load("languages/typescript.json",   string),
	#load("languages/json.json",         string),
	#load("languages/go.json",           string),
	#load("languages/rust.json",         string),
	#load("languages/bash.json",         string),
	#load("languages/powershell.json",   string),
	#load("languages/batch.json",        string),
	#load("languages/yaml.json",         string),
	#load("languages/toml.json",         string),
	#load("languages/java.json",         string),
	#load("languages/ruby.json",         string),
	#load("languages/html.json",         string),
	#load("languages/css.json",          string),
	#load("languages/zig.json",          string),
	#load("languages/csharp.json",       string),
	#load("languages/vbnet.json",        string),
	#load("languages/vba.json",          string),
	#load("languages/vb6.json",          string),
	#load("languages/basic.json",        string),
	#load("languages/lua.json",          string),
	#load("languages/asm-intel.json",    string),
	#load("languages/asm-att.json",      string),
	#load("languages/delphi.json",       string),
	#load("languages/turbo-pascal.json", string),
	#load("languages/txt.json",          string),
}

@(private)
load_builtin_definitions :: proc() {
	for language_blob in LANGUAGE_BLOBS {
		raw_definition: DefinitionJSON
		if unmarshal_error := json.unmarshal_string(language_blob, &raw_definition, allocator = context.temp_allocator); unmarshal_error != nil {
			continue // skip malformed — silent fallback to plain rendering
		}

		language_definition := new(Definition)
		language_definition.name                = strings.clone(raw_definition.name)
		language_definition.extensions          = clone_string_slice(raw_definition.extensions)
		language_definition.line_comment        = strings.clone(raw_definition.line_comment)
		language_definition.block_comment_start = strings.clone(raw_definition.block_comment_start)
		language_definition.block_comment_end   = strings.clone(raw_definition.block_comment_end)
		language_definition.preprocessor_prefix = strings.clone(raw_definition.preprocessor_prefix)
		language_definition.keywords            = clone_string_slice(raw_definition.keywords)
		language_definition.types               = clone_string_slice(raw_definition.types)
		language_definition.scope_start         = clone_scope_slice(raw_definition.scope_start, "{")
		language_definition.scope_end           = clone_scope_slice(raw_definition.scope_end,   "}")
		language_definition.symbol_patterns     = build_symbol_patterns(raw_definition.symbol_patterns)
		register(language_definition)
	}
}

// Like `clone_string_slice` but substitutes a single-element default when the
// JSON omitted the field or provided an empty list. Used for scope_start /
// scope_end so every existing C-family JSON keeps the historical `{` / `}`
// behavior without needing a code change.
@(private="file")
clone_scope_slice :: proc(source_slice: []string, default_token: string) -> []string {
	if len(source_slice) == 0 {
		output_slice := make([]string, 1)
		output_slice[0] = strings.clone(default_token)
		return output_slice
	}
	return clone_string_slice(source_slice)
}

@(private="file")
build_symbol_patterns :: proc(raw_patterns: []SymbolPatternJSON) -> []SymbolPattern {
	output_patterns := make([]SymbolPattern, len(raw_patterns))
	for raw_pattern, pattern_index in raw_patterns {
		token_strings := strings.fields(raw_pattern.pattern, context.temp_allocator)
		owned_tokens := make([]PatternToken, len(token_strings))
		for token_string, token_index in token_strings { owned_tokens[token_index] = parse_pattern_token(token_string) }
		output_patterns[pattern_index] = SymbolPattern{
			tokens = owned_tokens,
			kind   = parse_symbol_kind(raw_pattern.kind),
		}
	}
	return output_patterns
}

@(private="file")
parse_pattern_token :: proc(token_string: string) -> PatternToken {
	// Bare `...` is the non-greedy run wildcard. `{...}` is accepted as a
	// synonym for consistency with the other braced placeholders.
	if token_string == "..." { return PatternToken{kind = .Ellipsis} }

	// {PLACEHOLDER} forms
	if len(token_string) >= 2 && token_string[0] == '{' && token_string[len(token_string)-1] == '}' {
		inner_content := token_string[1:len(token_string)-1]

		// {OPTIONAL:X} — try to match X, skip if it doesn't. X can be a
		// placeholder, a literal, or another braced operator (notably
		// `{OPTION:A|B|C}` so optional-alternation works).
		if len(inner_content) >= len("OPTIONAL:") && inner_content[:len("OPTIONAL:")] == "OPTIONAL:" {
			sub_token_string := inner_content[len("OPTIONAL:"):]
			inner_token_pointer := new(PatternToken)
			inner_token_pointer^ = parse_inner_token(sub_token_string)
			return PatternToken{kind = .Optional, inner_token = inner_token_pointer}
		}

		// {NOT:X} — zero-width negative lookahead. Same inner grammar as
		// OPTIONAL but the pattern fails when X matches instead of succeeding.
		if len(inner_content) >= len("NOT:") && inner_content[:len("NOT:")] == "NOT:" {
			sub_token_string := inner_content[len("NOT:"):]
			inner_token_pointer := new(PatternToken)
			inner_token_pointer^ = parse_inner_token(sub_token_string)
			return PatternToken{kind = .Not, inner_token = inner_token_pointer}
		}

		// {OPTION:A|B|C} — mandatory alternation. Each pipe-separated piece
		// is a sub-token (placeholder OR literal). Empty pieces are kept as-
		// is; they'll simply never match (use them sparingly).
		if len(inner_content) >= len("OPTION:") && inner_content[:len("OPTION:")] == "OPTION:" {
			sub_token_string := inner_content[len("OPTION:"):]
			alternative_strings := strings.split(sub_token_string, "|", context.temp_allocator)
			alternative_tokens := make([]PatternToken, len(alternative_strings))
			for alternative_string, alternative_index in alternative_strings {
				alternative_tokens[alternative_index] = parse_inner_token(alternative_string)
			}
			return PatternToken{kind = .Option, alternatives = alternative_tokens}
		}

		switch inner_content {
		case "NAME":    return PatternToken{kind = .Name}
		case "TYPE":    return PatternToken{kind = .Type}
		case "NOTHING": return PatternToken{kind = .Nothing}
		case "ANY":     return PatternToken{kind = .Any}
		case "...":     return PatternToken{kind = .Ellipsis}
		}
		// Unknown placeholder — fall through and treat as literal so it
		// surfaces visibly (matches nothing) rather than silently dropping.
	}
	// Backward compatibility: bare `NAME` is the original capture syntax.
	if token_string == "NAME" { return PatternToken{kind = .Name} }
	return PatternToken{kind = .Literal, text = strings.clone(token_string)}
}

// Parse the body of an `{OPTIONAL:X}` / `{NOT:X}` / `{OPTION:…|X|…}` slot.
// If the body itself begins with `{`, we recurse into the full pattern-token
// parser so nested operators (most usefully `{OPTION:A|B|C}` inside an
// OPTIONAL wrapper) are honored. Otherwise we accept bare placeholder names
// or fall back to a Literal.
@(private="file")
parse_inner_token :: proc(inner_string: string) -> PatternToken {
	if len(inner_string) >= 2 && inner_string[0] == '{' && inner_string[len(inner_string)-1] == '}' {
		return parse_pattern_token(inner_string)
	}
	switch inner_string {
	case "NAME":    return PatternToken{kind = .Name}
	case "TYPE":    return PatternToken{kind = .Type}
	case "NOTHING": return PatternToken{kind = .Nothing}
	case "ANY":     return PatternToken{kind = .Any}
	case "...":     return PatternToken{kind = .Ellipsis}
	}
	return PatternToken{kind = .Literal, text = strings.clone(inner_string)}
}

@(private="file")
parse_symbol_kind :: proc(kind_string: string) -> SymbolKind {
	switch kind_string {
	case "Function": return .Function
	case "Type":     return .Type
	case "Variable": return .Variable
	case "Module":   return .Module
	}
	return .Other
}

@(private="file")
clone_string_slice :: proc(source_slice: []string) -> []string {
	output_slice := make([]string, len(source_slice))
	for source_string, slice_index in source_slice { output_slice[slice_index] = strings.clone(source_string) }
	return output_slice
}
