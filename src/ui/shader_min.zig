//! Shader sources as apps embed them: without comments, indentation or
//! blank lines, at compile time. The renderers compile their sources at
//! run time (OpenGL, WebGL, Metal, and Direct3D's effect passes), and the
//! text is in every app: what explains it to people need not be.
const std = @import("std");

/// `src` with `//` comments, leading spaces and blank lines removed;
/// lines stay lines (preprocessor directives need theirs).
pub fn minify(comptime src: []const u8) *const [minifiedLen(src):0]u8 {
    comptime {
        @setEvalBranchQuota(src.len * 40 + 1000);
        var out: [minifiedLen(src):0]u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |raw| {
            const line = strip(raw);
            if (line.len == 0) continue;
            @memcpy(out[n..][0..line.len], line);
            out[n + line.len] = '\n';
            n += line.len + 1;
        }
        out[n] = 0;
        const final = out;
        return &final;
    }
}

fn minifiedLen(comptime src: []const u8) usize {
    @setEvalBranchQuota(src.len * 40 + 1000);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const line = strip(raw);
        if (line.len > 0) n += line.len + 1;
    }
    return n;
}

/// A line without its comment and the spaces around it.
fn strip(raw: []const u8) []const u8 {
    var line = raw;
    if (std.mem.indexOf(u8, line, "//")) |at| line = line[0..at];
    return std.mem.trim(u8, line, " \t\r");
}

test "comments, indentation and blank lines go; code and directives stay" {
    const out = comptime minify(
        \\#version 330 core
        \\// A comment.
        \\
        \\float f(float x) { // trailing
        \\    return x * 2.0;
        \\}
        \\
    );
    try std.testing.expectEqualStrings("#version 330 core\nfloat f(float x) {\nreturn x * 2.0;\n}\n", out);
}
