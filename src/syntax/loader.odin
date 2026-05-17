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
	#load("languages/odin.json",       string),
	#load("languages/cpp.json",        string),
	#load("languages/javascript.json", string),
	#load("languages/typescript.json", string),
	#load("languages/json.json",       string),
	#load("languages/go.json",         string),
	#load("languages/rust.json",       string),
	#load("languages/bash.json",       string),
	#load("languages/powershell.json", string),
	#load("languages/batch.json",      string),
	#load("languages/yaml.json",       string),
	#load("languages/toml.json",       string),
	#load("languages/java.json",       string),
	#load("languages/ruby.json",       string),
	#load("languages/html.json",       string),
	#load("languages/css.json",        string),
	#load("languages/zig.json",        string),
	#load("languages/csharp.json",     string),
	#load("languages/vbnet.json",      string),
	#load("languages/vb6.json",        string),
	#load("languages/basic.json",      string),
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
		def.scope_start         = clone_scope_slice(raw.scope_start, "{")
		def.scope_end           = clone_scope_slice(raw.scope_end,   "}")
		def.symbol_patterns     = build_symbol_patterns(raw.symbol_patterns)
		register(def)
	}
}

// Like `clone_string_slice` but substitutes a single-element default when the
// JSON omitted the field or provided an empty list. Used for scope_start /
// scope_end so every existing C-family JSON keeps the historical `{` / `}`
// behavior without needing a code change.
@(private="file")
clone_scope_slice :: proc(src: []string, default_token: string) -> []string {
	if len(src) == 0 {
		out := make([]string, 1)
		out[0] = strings.clone(default_token)
		return out
	}
	return clone_string_slice(src)
}

@(private="file")
build_symbol_patterns :: proc(raw: []SymbolPatternJSON) -> []SymbolPattern {
	out := make([]SymbolPattern, len(raw))
	for r, i in raw {
		tokens := strings.fields(r.pattern, context.temp_allocator)
		owned := make([]PatternToken, len(tokens))
		for t, k in tokens { owned[k] = parse_pattern_token(t) }
		out[i] = SymbolPattern{
			tokens = owned,
			kind   = parse_symbol_kind(r.kind),
		}
	}
	return out
}

@(private="file")
parse_pattern_token :: proc(t: string) -> PatternToken {
	// Bare `...` is the non-greedy run wildcard. `{...}` is accepted as a
	// synonym for consistency with the other braced placeholders.
	if t == "..." { return PatternToken{kind = .Ellipsis} }

	// {PLACEHOLDER} forms
	if len(t) >= 2 && t[0] == '{' && t[len(t)-1] == '}' {
		inner := t[1:len(t)-1]

		// {OPTIONAL:X} — try to match X, skip if it doesn't. X can be a
		// placeholder, a literal, or another braced operator (notably
		// `{OPTION:A|B|C}` so optional-alternation works).
		if len(inner) >= len("OPTIONAL:") && inner[:len("OPTIONAL:")] == "OPTIONAL:" {
			sub := inner[len("OPTIONAL:"):]
			ip := new(PatternToken)
			ip^ = parse_inner_token(sub)
			return PatternToken{kind = .Optional, inner = ip}
		}

		// {NOT:X} — zero-width negative lookahead. Same inner grammar as
		// OPTIONAL but the pattern fails when X matches instead of succeeding.
		if len(inner) >= len("NOT:") && inner[:len("NOT:")] == "NOT:" {
			sub := inner[len("NOT:"):]
			ip := new(PatternToken)
			ip^ = parse_inner_token(sub)
			return PatternToken{kind = .Not, inner = ip}
		}

		// {OPTION:A|B|C} — mandatory alternation. Each pipe-separated piece
		// is a sub-token (placeholder OR literal). Empty pieces are kept as-
		// is; they'll simply never match (use them sparingly).
		if len(inner) >= len("OPTION:") && inner[:len("OPTION:")] == "OPTION:" {
			sub := inner[len("OPTION:"):]
			parts := strings.split(sub, "|", context.temp_allocator)
			opts := make([]PatternToken, len(parts))
			for part, k in parts {
				opts[k] = parse_inner_token(part)
			}
			return PatternToken{kind = .Option, options = opts}
		}

		switch inner {
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
	if t == "NAME" { return PatternToken{kind = .Name} }
	return PatternToken{kind = .Literal, text = strings.clone(t)}
}

// Parse the body of an `{OPTIONAL:X}` / `{NOT:X}` / `{OPTION:…|X|…}` slot.
// If the body itself begins with `{`, we recurse into the full pattern-token
// parser so nested operators (most usefully `{OPTION:A|B|C}` inside an
// OPTIONAL wrapper) are honored. Otherwise we accept bare placeholder names
// or fall back to a Literal.
@(private="file")
parse_inner_token :: proc(s: string) -> PatternToken {
	if len(s) >= 2 && s[0] == '{' && s[len(s)-1] == '}' {
		return parse_pattern_token(s)
	}
	switch s {
	case "NAME":    return PatternToken{kind = .Name}
	case "TYPE":    return PatternToken{kind = .Type}
	case "NOTHING": return PatternToken{kind = .Nothing}
	case "ANY":     return PatternToken{kind = .Any}
	case "...":     return PatternToken{kind = .Ellipsis}
	}
	return PatternToken{kind = .Literal, text = strings.clone(s)}
}

@(private="file")
parse_symbol_kind :: proc(s: string) -> SymbolKind {
	switch s {
	case "Function": return .Function
	case "Type":     return .Type
	case "Variable": return .Variable
	case "Module":   return .Module
	}
	return .Other
}

@(private="file")
clone_string_slice :: proc(src: []string) -> []string {
	out := make([]string, len(src))
	for s, i in src { out[i] = strings.clone(s) }
	return out
}
