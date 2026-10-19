//! GitHub's extensions: tables, task lists, strikethrough, autolinks.
//! Generated from the spec's examples (markdown, the HTML cmark writes).
const t = @import("tests_spec_run.zig");

pub const examples = [_]t.Example{
    .{ .n = 198, .md = "| foo | bar |\n| --- | --- |\n| baz | bim |\n", .html = "<table>\n<thead>\n<tr>\n<th>foo</th>\n<th>bar</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>baz</td>\n<td>bim</td>\n</tr>\n</tbody>\n</table>\n" },
    .{ .n = 199, .md = "| abc | defghi |\n:-: | -----------:\nbar | baz\n", .html = "<table>\n<thead>\n<tr>\n<th align=\"center\">abc</th>\n<th align=\"right\">defghi</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td align=\"center\">bar</td>\n<td align=\"right\">baz</td>\n</tr>\n</tbody>\n</table>\n" },
    .{ .n = 200, .md = "| f\\|oo  |\n| ------ |\n| b `\\|` az |\n| b **\\|** im |\n", .html = "<table>\n<thead>\n<tr>\n<th>f|oo</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>b <code>|</code> az</td>\n</tr>\n<tr>\n<td>b <strong>|</strong> im</td>\n</tr>\n</tbody>\n</table>\n" },
    .{ .n = 201, .md = "| abc | def |\n| --- | --- |\n| bar | baz |\n> bar\n", .html = "<table>\n<thead>\n<tr>\n<th>abc</th>\n<th>def</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>bar</td>\n<td>baz</td>\n</tr>\n</tbody>\n</table>\n<blockquote>\n<p>bar</p>\n</blockquote>\n" },
    .{ .n = 202, .md = "| abc | def |\n| --- | --- |\n| bar | baz |\nbar\n\nbar\n", .html = "<table>\n<thead>\n<tr>\n<th>abc</th>\n<th>def</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>bar</td>\n<td>baz</td>\n</tr>\n<tr>\n<td>bar</td>\n<td></td>\n</tr>\n</tbody>\n</table>\n<p>bar</p>\n" },
    .{ .n = 203, .md = "| abc | def |\n| --- |\n| bar |\n", .html = "<p>| abc | def |\n| --- |\n| bar |</p>\n" },
    .{ .n = 204, .md = "| abc | def |\n| --- | --- |\n| bar |\n| bar | baz | boo |\n", .html = "<table>\n<thead>\n<tr>\n<th>abc</th>\n<th>def</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td>bar</td>\n<td></td>\n</tr>\n<tr>\n<td>bar</td>\n<td>baz</td>\n</tr>\n</tbody>\n</table>\n" },
    .{ .n = 205, .md = "| abc | def |\n| --- | --- |\n", .html = "<table>\n<thead>\n<tr>\n<th>abc</th>\n<th>def</th>\n</tr>\n</thead>\n</table>\n" },
    .{ .n = 491, .md = "~~Hi~~ Hello, world!\n", .html = "<p><del>Hi</del> Hello, world!</p>\n" },
    .{ .n = 492, .md = "This ~~has a\n\nnew paragraph~~.\n", .html = "<p>This ~~has a</p>\n<p>new paragraph~~.</p>\n" },
    .{ .n = 621, .md = "www.commonmark.org\n", .html = "<p><a href=\"http://www.commonmark.org\">www.commonmark.org</a></p>\n" },
    .{ .n = 622, .md = "Visit www.commonmark.org/help for more information.\n", .html = "<p>Visit <a href=\"http://www.commonmark.org/help\">www.commonmark.org/help</a> for more information.</p>\n" },
    .{ .n = 623, .md = "Visit www.commonmark.org.\n\nVisit www.commonmark.org/a.b.\n", .html = "<p>Visit <a href=\"http://www.commonmark.org\">www.commonmark.org</a>.</p>\n<p>Visit <a href=\"http://www.commonmark.org/a.b\">www.commonmark.org/a.b</a>.</p>\n" },
    .{ .n = 624, .md = "www.google.com/search?q=Markup+(business)\n\nwww.google.com/search?q=Markup+(business)))\n\n(www.google.com/search?q=Markup+(business))\n\n(www.google.com/search?q=Markup+(business)\n", .html = "<p><a href=\"http://www.google.com/search?q=Markup+(business)\">www.google.com/search?q=Markup+(business)</a></p>\n<p><a href=\"http://www.google.com/search?q=Markup+(business)\">www.google.com/search?q=Markup+(business)</a>))</p>\n<p>(<a href=\"http://www.google.com/search?q=Markup+(business)\">www.google.com/search?q=Markup+(business)</a>)</p>\n<p>(<a href=\"http://www.google.com/search?q=Markup+(business)\">www.google.com/search?q=Markup+(business)</a></p>\n" },
    .{ .n = 625, .md = "www.google.com/search?q=(business))+ok\n", .html = "<p><a href=\"http://www.google.com/search?q=(business))+ok\">www.google.com/search?q=(business))+ok</a></p>\n" },
    .{ .n = 626, .md = "www.google.com/search?q=commonmark&hl=en\n\nwww.google.com/search?q=commonmark&hl;\n", .html = "<p><a href=\"http://www.google.com/search?q=commonmark&amp;hl=en\">www.google.com/search?q=commonmark&amp;hl=en</a></p>\n<p><a href=\"http://www.google.com/search?q=commonmark\">www.google.com/search?q=commonmark</a>&amp;hl;</p>\n" },
    .{ .n = 627, .md = "www.commonmark.org/he<lp\n", .html = "<p><a href=\"http://www.commonmark.org/he\">www.commonmark.org/he</a>&lt;lp</p>\n" },
    .{ .n = 628, .md = "http://commonmark.org\n\n(Visit https://encrypted.google.com/search?q=Markup+(business))\n\nAnonymous FTP is available at ftp://foo.bar.baz.\n", .html = "<p><a href=\"http://commonmark.org\">http://commonmark.org</a></p>\n<p>(Visit <a href=\"https://encrypted.google.com/search?q=Markup+(business)\">https://encrypted.google.com/search?q=Markup+(business)</a>)</p>\n<p>Anonymous FTP is available at <a href=\"ftp://foo.bar.baz\">ftp://foo.bar.baz</a>.</p>\n" },
    .{ .n = 629, .md = "foo@bar.baz\n", .html = "<p><a href=\"mailto:foo@bar.baz\">foo@bar.baz</a></p>\n" },
    .{ .n = 630, .md = "hello@mail+xyz.example isn't valid, but hello+xyz@mail.example is.\n", .html = "<p>hello@mail+xyz.example isn't valid, but <a href=\"mailto:hello+xyz@mail.example\">hello+xyz@mail.example</a> is.</p>\n" },
    .{ .n = 631, .md = "a.b-c_d@a.b\n\na.b-c_d@a.b.\n\na.b-c_d@a.b-\n\na.b-c_d@a.b_\n", .html = "<p><a href=\"mailto:a.b-c_d@a.b\">a.b-c_d@a.b</a></p>\n<p><a href=\"mailto:a.b-c_d@a.b\">a.b-c_d@a.b</a>.</p>\n<p>a.b-c_d@a.b-</p>\n<p>a.b-c_d@a.b_</p>\n" },
};

test "GitHub's extensions: tables, task lists, strikethrough, autolinks" {
    try t.run(&examples, .gfm);
}
