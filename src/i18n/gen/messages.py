# Writes src/i18n/tests_message_cases.zig from mygo's i18n/testdata/messages.json.
import json, re, sys
d = json.load(open(sys.argv[1], encoding='utf8'))
out = open(sys.argv[2], 'w', encoding='utf8', newline='\n')
BS = chr(92)

def zs(s):
    r = '"'
    for ch in s:
        o = ord(ch)
        if ch == '"': r += BS + '"'
        elif ch == BS: r += BS + BS
        elif ch == '\n': r += BS + 'n'
        elif o < 0x20 or o == 0x7f: r += BS + 'x%02x' % o
        elif o == 0xa0 or 0x2000 <= o <= 0x200f or 0x2028 <= o <= 0x202f: r += BS + 'u{%x}' % o
        else: r += ch
    return r + '"'

def numeric(msg, name):
    return re.search(r'\{\s*' + re.escape(name) + r'\s*,\s*(plural|selectordinal|number)', msg) is not None

def used(msg):
    names = set(re.findall(r'\{\s*([A-Za-z0-9_]+)\s*[,}]', msg))
    return {n for n in names if len(re.findall(r'\{\s*' + n + r'\b', msg)) > len(re.findall(r"'\{\s*" + n + r'\b', msg))}

def value(msg, name, v):
    if isinstance(v, bool): return 'true' if v else 'false'
    if isinstance(v, int): return str(v)
    if isinstance(v, float): return '@as(f64, %r)' % v
    if numeric(msg, name):
        if not re.fullmatch(r'-?\d+(\.\d+)?', v): return None
        return 'args.exact(%s)' % zs(v)
    return zs(v)

lines = ['// Generated from mygo\'s i18n/testdata/messages.json by src/i18n/gen/messages.py. Do not edit.',
         '//! Messages and what they format to, which mygo\'s Go and its pages both check.',
         'const std = @import("std");', 'const args = @import("args.zig");', 'const fm = @import("format_message.zig");', 'const msg = @import("message.zig");', '',
         'fn expect(locale: []const u8, comptime message: []const u8, a: anytype, want: []const u8) !void {',
         '    var buf: [512]u8 = undefined;',
         '    const got = try fm.bufFormatMessage(&buf, locale, message, a);',
         '    if (!std.mem.eql(u8, got, want)) {',
         '        std.debug.print("{s} in {s}: got ' + BS + '"{s}' + BS + '", want ' + BS + '"{s}' + BS + '"' + BS + 'n", .{ message, locale, got, want });',
         '        return error.TestUnexpectedResult;', '    }', '}', '',
         'test "messages as mygo formats them" {']
skipped = 0
for c in d['format'] + d['pseudo']:
    m = c['message']; a = c.get('args', {})
    names = used(m)
    if any(not re.fullmatch(r'[A-Za-z_]\w*', n) for n in list(names) + list(a)) or not names <= set(a):
        skipped += 1; continue
    vals = []
    ok = True
    for k, v in a.items():
        if k not in names: continue
        z = value(m, k, v)
        if z is None: ok = False; break
        vals.append('.%s = %s' % (k, z))
    if not ok: skipped += 1; continue
    lines.append('    try expect(%s, %s, .{%s}, %s);' % (zs(c.get('locale', 'en')), zs(m), (' ' + ', '.join(vals) + ' ') if vals else '', zs(c['want'])))
lines.append('}')
lines.append('')
lines.append('test "messages that do not parse" {')
lines.append('    inline for (.{')
for e in d['errors']:
    lines.append('        %s,' % zs(e))
lines.append('    }) |m| try std.testing.expect(comptime msg.parse(m) == .err);')
lines.append('}')
out.write('\n'.join(lines) + '\n')
print('skipped', skipped)
