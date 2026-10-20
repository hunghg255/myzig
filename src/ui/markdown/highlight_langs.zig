//! More languages for the highlighter: C-like languages, scripting
//! languages, functional languages, config formats, and markup, Markdown
//! and diffs (`highlight_markup.zig`), by keywords, comments and quotes.
const std = @import("std");
const Language = @import("highlight.zig").Language;

const c_types = [_][]const u8{ "int", "char", "short", "long", "float", "double", "void", "unsigned", "signed", "bool", "size_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t", "auto" };

const c: Language = .{
    .keywords = &.{ "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "goto", "struct", "union", "enum", "typedef", "static", "extern", "const", "volatile", "inline", "sizeof", "register", "restrict", "class", "namespace", "template", "typename", "public", "private", "protected", "virtual", "override", "new", "delete", "using", "constexpr", "noexcept", "operator", "friend", "this", "throw", "try", "catch", "static_cast", "dynamic_cast", "reinterpret_cast", "const_cast", "explicit", "mutable", "final" },
    .constants = &(c_types ++ [_][]const u8{ "true", "false", "NULL", "nullptr" }),
    .line_comment = "//",
    .block_comment = true,
};
const rust: Language = .{
    .keywords = &.{ "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "static", "struct", "super", "trait", "type", "unsafe", "use", "where", "while" },
    .constants = &.{ "true", "false", "self", "Self", "None", "Some", "Ok", "Err", "i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64", "bool", "char", "str", "String", "Vec", "Option", "Result", "Box" },
    .line_comment = "//",
    .block_comment = true,
    .quotes = "\"",
};
const java: Language = .{
    .keywords = &.{ "abstract", "assert", "break", "case", "catch", "class", "const", "continue", "default", "do", "else", "enum", "extends", "final", "finally", "for", "goto", "if", "implements", "import", "instanceof", "interface", "native", "new", "package", "private", "protected", "public", "return", "static", "super", "switch", "synchronized", "this", "throw", "throws", "try", "volatile", "while", "var", "record", "sealed", "yield", "fun", "val", "when", "object", "companion", "data", "override", "open", "internal", "lateinit", "suspend", "namespace", "using", "async", "await", "readonly", "struct", "get", "set", "init", "partial", "func", "let", "guard", "extension", "protocol", "deinit", "inout" },
    .constants = &.{ "true", "false", "null", "nil", "int", "long", "short", "byte", "char", "float", "double", "boolean", "void", "String", "Int", "Long", "Boolean", "Unit", "Any", "string", "bool", "object", "decimal", "Self", "self" },
    .line_comment = "//",
    .block_comment = true,
    .multiline = '`',
};
const ruby: Language = .{
    .keywords = &.{ "alias", "and", "begin", "break", "case", "class", "def", "do", "else", "elsif", "end", "ensure", "for", "if", "in", "module", "next", "not", "or", "redo", "rescue", "retry", "return", "super", "then", "undef", "unless", "until", "when", "while", "yield", "require", "attr_accessor", "attr_reader", "puts" },
    .constants = &.{ "true", "false", "nil", "self" },
    .line_comment = "#",
};
const php: Language = .{
    .keywords = &.{ "abstract", "and", "as", "break", "case", "catch", "class", "clone", "const", "continue", "declare", "default", "do", "echo", "else", "elseif", "extends", "final", "finally", "fn", "for", "foreach", "function", "global", "if", "implements", "include", "instanceof", "interface", "match", "namespace", "new", "or", "private", "protected", "public", "require", "return", "static", "switch", "throw", "trait", "try", "use", "while", "yield" },
    .constants = &.{ "true", "false", "null", "TRUE", "FALSE", "NULL" },
    .line_comment = "//",
    .block_comment = true,
    .sigil = '$',
};
const lua: Language = .{
    .keywords = &.{ "and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if", "in", "local", "not", "or", "repeat", "return", "then", "until", "while" },
    .constants = &.{ "true", "false", "nil" },
    .line_comment = "--",
};
const sql: Language = .{
    .keywords = &.{ "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter", "add", "index", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having", "limit", "offset", "as", "and", "or", "not", "in", "is", "like", "between", "union", "all", "distinct", "primary", "key", "foreign", "references", "default", "case", "when", "then", "else", "end", "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "DROP", "ALTER", "JOIN", "ON", "GROUP", "BY", "ORDER", "AS", "AND", "OR", "NOT", "LIMIT" },
    .constants = &.{ "null", "NULL", "true", "false", "TRUE", "FALSE" },
    .line_comment = "--",
    .block_comment = true,
};
const powershell: Language = .{
    .keywords = &.{ "begin", "break", "catch", "class", "continue", "data", "do", "dynamicparam", "else", "elseif", "end", "exit", "filter", "finally", "for", "foreach", "from", "function", "if", "in", "param", "process", "return", "switch", "throw", "trap", "try", "until", "using", "while" },
    .constants = &.{ "true", "false", "null" },
    .line_comment = "#",
    .sigil = '$',
};
const yaml: Language = .{ .keywords = &.{}, .constants = &.{ "true", "false", "null", "yes", "no", "on", "off" }, .line_comment = "#" };
const toml: Language = .{ .keywords = &.{}, .constants = &.{ "true", "false" }, .line_comment = "#" };
const css: Language = .{
    .keywords = &.{ "important", "media", "import", "keyframes", "supports", "tailwind", "apply", "layer" },
    .constants = &.{ "none", "auto", "inherit", "initial", "unset", "block", "inline", "flex", "grid", "absolute", "relative", "fixed", "solid" },
    .block_comment = true,
};
const scss: Language = .{
    .keywords = css.keywords ++ &[_][]const u8{ "mixin", "include", "extend", "use", "forward", "if", "else", "each", "for", "function", "return" },
    .constants = css.constants,
    .line_comment = "//",
    .block_comment = true,
    .sigil = '$',
};
const markup: Language = .{ .keywords = &.{}, .mode = .markup, .block = .{ "<!--", "-->" } };
const markdown: Language = .{ .keywords = &.{}, .mode = .markdown, .block = .{ "<!--", "-->" } };
const diff: Language = .{ .keywords = &.{}, .mode = .diff };
const haskell: Language = .{
    .keywords = &.{ "case", "class", "data", "default", "deriving", "do", "else", "if", "import", "in", "infix", "infixl", "infixr", "instance", "let", "module", "newtype", "of", "then", "type", "where", "forall", "qualified", "hiding", "as" },
    .constants = &.{ "True", "False", "Nothing", "Just", "Left", "Right" },
    .line_comment = "--",
    .block = .{ "{-", "-}" },
    .quotes = "\"",
};
const ml: Language = .{
    .keywords = &.{ "let", "rec", "in", "and", "fun", "function", "match", "with", "type", "of", "module", "open", "struct", "sig", "end", "if", "then", "else", "begin", "val", "mutable", "when", "member", "use", "do", "done", "for", "while", "to", "exception", "raise", "try", "namespace", "private", "public", "static", "override", "abstract", "interface", "inherit", "new", "yield", "async" },
    .constants = &.{ "true", "false", "None", "Some", "unit", "int", "string", "float", "bool", "list", "option" },
    .line_comment = "//",
    .block = .{ "(*", "*)" },
    .quotes = "\"",
};
const elixir: Language = .{
    .keywords = &.{ "def", "defp", "defmodule", "defmacro", "defstruct", "defimpl", "defprotocol", "do", "end", "fn", "if", "else", "unless", "case", "cond", "with", "when", "and", "or", "not", "in", "import", "alias", "require", "use", "quote", "unquote", "receive", "after", "try", "catch", "rescue", "raise" },
    .constants = &.{ "true", "false", "nil" },
    .line_comment = "#",
    .triple = true,
};
const erlang: Language = .{
    .keywords = &.{ "after", "begin", "case", "catch", "end", "fun", "if", "of", "receive", "try", "when", "and", "or", "not", "andalso", "orelse", "module", "export", "import", "define", "record", "spec", "type" },
    .constants = &.{ "true", "false", "undefined", "ok", "error" },
    .line_comment = "%",
};
const lisp: Language = .{
    .keywords = &.{ "defun", "defn", "defmacro", "defvar", "defparameter", "def", "define", "lambda", "fn", "let", "let*", "letrec", "if", "when", "unless", "cond", "case", "do", "loop", "progn", "begin", "set!", "setq", "setf", "quote", "require", "ns", "import", "and", "or", "not" },
    .constants = &.{ "nil", "t", "true", "false", "#t", "#f" },
    .line_comment = ";",
    .quotes = "\"",
};
const nix: Language = .{
    .keywords = &.{ "let", "in", "with", "rec", "inherit", "if", "then", "else", "assert", "import", "or" },
    .constants = &.{ "true", "false", "null", "builtins", "pkgs", "lib" },
    .line_comment = "#",
    .block_comment = true,
    .quotes = "\"",
};
const julia: Language = .{
    .keywords = &.{ "function", "end", "if", "elseif", "else", "for", "while", "return", "begin", "let", "local", "global", "const", "struct", "mutable", "module", "using", "import", "export", "try", "catch", "finally", "macro", "quote", "do", "break", "continue", "abstract", "type", "where", "in" },
    .constants = &.{ "true", "false", "nothing", "missing", "Int", "Float64", "String", "Bool", "Vector", "Array", "Dict" },
    .line_comment = "#",
    .block = .{ "#=", "=#" },
    .triple = true,
};
const hcl: Language = .{
    .keywords = &.{ "resource", "data", "variable", "output", "module", "provider", "terraform", "locals", "for", "in", "if", "for_each", "count", "depends_on", "dynamic", "content", "backend", "required_providers" },
    .constants = &.{ "true", "false", "null", "string", "number", "bool", "list", "map", "object", "any" },
    .line_comment = "#",
    .block_comment = true,
    .quotes = "\"",
};
const r: Language = .{
    .keywords = &.{ "if", "else", "for", "while", "repeat", "function", "return", "break", "next", "in", "library", "require" },
    .constants = &.{ "TRUE", "FALSE", "NULL", "NA", "Inf", "NaN", "T", "F" },
    .line_comment = "#",
};
const perl: Language = .{
    .keywords = &.{ "my", "our", "local", "sub", "if", "elsif", "else", "unless", "while", "until", "for", "foreach", "do", "last", "next", "redo", "return", "use", "require", "package", "print", "say", "die", "eval", "and", "or", "not" },
    .constants = &.{ "undef" },
    .line_comment = "#",
    .sigil = '$',
};
const nim: Language = .{
    .keywords = &.{ "proc", "func", "method", "iterator", "template", "macro", "type", "object", "enum", "var", "let", "const", "if", "elif", "else", "case", "of", "when", "while", "for", "in", "return", "yield", "import", "from", "include", "export", "try", "except", "finally", "raise", "discard", "block", "break", "continue", "and", "or", "not", "ref", "ptr", "distinct", "concept", "async", "await" },
    .constants = &.{ "true", "false", "nil", "int", "float", "string", "bool", "seq", "char" },
    .line_comment = "#",
    .block = .{ "#[", "]#" },
    .triple = true,
};
const gdscript: Language = .{
    .keywords = &.{ "if", "elif", "else", "for", "while", "match", "break", "continue", "pass", "return", "class", "class_name", "extends", "is", "as", "self", "signal", "func", "static", "const", "enum", "var", "onready", "export", "setget", "await", "yield", "load", "preload", "in", "and", "or", "not", "def", "lambda", "load", "struct" },
    .constants = &.{ "true", "false", "null", "True", "False", "None", "PI", "TAU", "INF", "NAN" },
    .line_comment = "#",
    .triple = true,
};
const cmake: Language = .{
    .keywords = &.{ "if", "elseif", "else", "endif", "foreach", "endforeach", "while", "endwhile", "function", "endfunction", "macro", "endmacro", "set", "project", "add_executable", "add_library", "target_link_libraries", "include", "find_package", "option", "message", "install", "add_subdirectory", "target_include_directories" },
    .constants = &.{ "ON", "OFF", "TRUE", "FALSE", "PUBLIC", "PRIVATE", "INTERFACE", "REQUIRED" },
    .line_comment = "#",
    .sigil = '$',
};
const vim: Language = .{
    .keywords = &.{ "let", "set", "if", "elseif", "else", "endif", "for", "endfor", "while", "endwhile", "function", "endfunction", "return", "call", "map", "nnoremap", "inoremap", "vnoremap", "noremap", "autocmd", "augroup", "command", "syntax", "highlight", "source" },
    .line_comment = "\"",
    .quotes = "'",
};
const tex: Language = .{
    .keywords = &.{ "documentclass", "usepackage", "begin", "end", "section", "subsection", "chapter", "title", "author", "date", "maketitle", "label", "ref", "cite", "newcommand", "renewcommand", "include", "input", "item", "textbf", "textit", "emph" },
    .line_comment = "%",
    .quotes = "",
    .sigil = '\\',
};
const matlab: Language = .{
    .keywords = &.{ "function", "end", "if", "elseif", "else", "for", "while", "switch", "case", "otherwise", "try", "catch", "return", "break", "continue", "global", "persistent" },
    .constants = &.{ "true", "false", "pi", "inf", "nan", "eps" },
    .line_comment = "%",
    .block = .{ "%{", "%}" },
};
const fortran: Language = .{
    .keywords = &.{ "program", "end", "subroutine", "function", "module", "use", "implicit", "none", "integer", "real", "character", "logical", "if", "then", "else", "do", "while", "call", "return", "contains", "type", "allocate", "deallocate", "print", "write", "read", "PROGRAM", "END", "SUBROUTINE", "FUNCTION", "MODULE", "USE", "IMPLICIT", "NONE", "INTEGER", "REAL", "IF", "THEN", "ELSE", "DO", "CALL", "RETURN" },
    .constants = &.{ ".true.", ".false." },
    .line_comment = "!",
};
const vb: Language = .{
    .keywords = &.{ "Dim", "As", "If", "Then", "Else", "ElseIf", "End", "Sub", "Function", "Return", "For", "Each", "Next", "While", "Wend", "Do", "Loop", "Select", "Case", "Class", "Module", "Public", "Private", "Imports", "New", "Set", "Call", "And", "Or", "Not", "Nothing" },
    .constants = &.{ "True", "False", "Nothing", "Integer", "String", "Boolean", "Double" },
    .line_comment = "'",
    .quotes = "\"",
};
const batch: Language = .{
    .keywords = &.{ "echo", "set", "if", "else", "goto", "call", "exit", "for", "in", "do", "not", "exist", "defined", "setlocal", "endlocal", "shift", "pause", "rem", "ECHO", "SET", "IF", "ELSE", "GOTO", "CALL", "EXIT", "FOR", "IN", "DO", "NOT", "EXIST", "REM" },
    .constants = &.{ "on", "off", "ON", "OFF" },
    .line_comment = "::",
    .sigil = '%',
};
const asm_: Language = .{
    .keywords = &.{ "mov", "add", "sub", "mul", "div", "jmp", "je", "jne", "jz", "jnz", "call", "ret", "push", "pop", "cmp", "lea", "and", "or", "xor", "inc", "dec", "section", "global", "extern", "db", "dw", "dd", "dq" },
    .line_comment = ";",
};
const graphql: Language = .{
    .keywords = &.{ "query", "mutation", "subscription", "fragment", "on", "type", "input", "enum", "interface", "union", "scalar", "schema", "extend", "implements", "directive" },
    .constants = &.{ "true", "false", "null", "String", "Int", "Float", "Boolean", "ID" },
    .line_comment = "#",
    .triple = true,
};
const proto: Language = .{
    .keywords = &.{ "syntax", "package", "import", "option", "message", "enum", "service", "rpc", "returns", "repeated", "optional", "required", "oneof", "map", "reserved", "extend", "stream" },
    .constants = &.{ "true", "false", "int32", "int64", "uint32", "uint64", "string", "bool", "bytes", "double", "float" },
    .line_comment = "//",
    .block_comment = true,
};
const prolog: Language = .{ .keywords = &.{ "is", "not" }, .constants = &.{ "true", "fail" }, .line_comment = "%", .block_comment = true };
const vhdl: Language = .{
    .keywords = &.{ "library", "use", "entity", "is", "port", "end", "architecture", "of", "begin", "signal", "process", "if", "then", "else", "elsif", "case", "when", "others", "in", "out", "inout", "generic", "map", "component", "constant", "variable", "type" },
    .constants = &.{ "std_logic", "std_logic_vector", "integer", "boolean", "true", "false" },
    .line_comment = "--",
    .quotes = "\"",
};
const hash_config: Language = .{
    .keywords = &.{ "FROM", "RUN", "CMD", "COPY", "ADD", "ENV", "ARG", "WORKDIR", "EXPOSE", "ENTRYPOINT", "VOLUME", "USER", "LABEL", "include", "ifeq", "ifneq", "endif", "export" },
    .line_comment = "#",
    .sigil = '$',
};

/// A language by a file extension or name, among those of this file.
pub fn language(name: []const u8) ?*const Language {
    const Entry = struct { []const u8, *const Language };
    const names = [_]Entry{
        .{ "c", &c },           .{ "h", &c },             .{ "cpp", &c },          .{ "cc", &c },
        .{ "cxx", &c },         .{ "hpp", &c },           .{ "hh", &c },           .{ "m", &c },
        .{ "mm", &c },          .{ "rs", &rust },         .{ "rust", &rust },      .{ "java", &java },
        .{ "kt", &java },       .{ "kts", &java },        .{ "cs", &java },        .{ "swift", &java },
        .{ "scala", &java },    .{ "dart", &java },       .{ "groovy", &java },    .{ "gradle", &java },
        .{ "rb", &ruby },       .{ "ruby", &ruby },       .{ "php", &php },        .{ "lua", &lua },
        .{ "sql", &sql },       .{ "ps1", &powershell },  .{ "psm1", &powershell }, .{ "powershell", &powershell },
        .{ "yml", &yaml },      .{ "yaml", &yaml },       .{ "toml", &toml },      .{ "ini", &toml },
        .{ "css", &css },       .{ "scss", &css },        .{ "less", &css },       .{ "dockerfile", &hash_config },
        .{ "makefile", &hash_config }, .{ "mk", &hash_config }, .{ "env", &hash_config }, .{ "gitignore", &hash_config },
        .{ "properties", &toml }, .{ "conf", &hash_config },
        .{ "sass", &scss },     .{ "html", &markup },     .{ "htm", &markup },     .{ "xhtml", &markup },
        .{ "xml", &markup },    .{ "svg", &markup },      .{ "vue", &markup },     .{ "svelte", &markup },
        .{ "astro", &markup },  .{ "xaml", &markup },     .{ "plist", &markup },   .{ "csproj", &markup },
        .{ "xsl", &markup },    .{ "md", &markdown },     .{ "markdown", &markdown }, .{ "mdx", &markdown },
        .{ "diff", &diff },     .{ "patch", &diff },      .{ "hs", &haskell },     .{ "haskell", &haskell },
        .{ "elm", &haskell },   .{ "purs", &haskell },    .{ "ml", &ml },          .{ "mli", &ml },
        .{ "fs", &ml },         .{ "fsx", &ml },          .{ "fsi", &ml },         .{ "ocaml", &ml },
        .{ "ex", &elixir },     .{ "exs", &elixir },      .{ "elixir", &elixir },  .{ "erl", &erlang },
        .{ "hrl", &erlang },    .{ "clj", &lisp },        .{ "cljs", &lisp },      .{ "edn", &lisp },
        .{ "lisp", &lisp },     .{ "el", &lisp },         .{ "scm", &lisp },       .{ "rkt", &lisp },
        .{ "fnl", &lisp },      .{ "nix", &nix },         .{ "jl", &julia },       .{ "julia", &julia },
        .{ "tf", &hcl },        .{ "tfvars", &hcl },      .{ "hcl", &hcl },        .{ "r", &r },
        .{ "pl", &perl },       .{ "pm", &perl },         .{ "perl", &perl },      .{ "nim", &nim },
        .{ "gd", &gdscript },   .{ "cmake", &cmake },     .{ "vim", &vim },        .{ "vimrc", &vim },
        .{ "tex", &tex },       .{ "sty", &tex },         .{ "latex", &tex },      .{ "bib", &tex },
        .{ "matlab", &matlab }, .{ "f90", &fortran },     .{ "f95", &fortran },    .{ "f", &fortran },
        .{ "for", &fortran },   .{ "vb", &vb },           .{ "vbs", &vb },         .{ "bas", &vb },
        .{ "bat", &batch },     .{ "cmd", &batch },       .{ "asm", &asm_ },       .{ "s", &asm_ },
        .{ "nasm", &asm_ },     .{ "graphql", &graphql }, .{ "gql", &graphql },    .{ "proto", &proto },
        .{ "pro", &prolog },    .{ "prolog", &prolog },   .{ "vhd", &vhdl },       .{ "vhdl", &vhdl },
        .{ "v", &proto },       .{ "sv", &c },            .{ "glsl", &c },         .{ "hlsl", &c },
        .{ "vert", &c },        .{ "frag", &c },          .{ "wgsl", &rust },      .{ "odin", &c },
        .{ "gleam", &rust },    .{ "cr", &ruby },         .{ "rake", &ruby },      .{ "gemfile", &ruby },
        .{ "bzl", &hash_config }, .{ "star", &hash_config }, .{ "build", &hash_config }, .{ "fish", &hash_config },
        .{ "editorconfig", &toml }, .{ "gitattributes", &hash_config }, .{ "npmrc", &toml }, .{ "lock", &toml },
    };
    for (names) |e| if (std.ascii.eqlIgnoreCase(e[0], name)) return e[1];
    return null;
}

test language {
    try std.testing.expect(language("rs") != null);
    try std.testing.expect(language("Dockerfile") != null);
    try std.testing.expect(language("nothing") == null);
    try std.testing.expect(language("vue").?.mode == .markup);
    try std.testing.expectEqualStrings("{-", language("hs").?.block.?[0]);
}
