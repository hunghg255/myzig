# Converts the plural rules of mygo's i18n/tables.go to Zig.
import re, sys
src = open(sys.argv[1], encoding='utf8').read().split('\n')
out_dir = sys.argv[2]

def cond(c):
    c = c.replace('&&', 'and').replace('||', 'or')
    c = re.sub(r'uint64\(o\.([A-Z])\)', lambda m: 'o.' + m.group(1).lower(), c)
    c = re.sub(r'o\.([A-Z])\b', lambda m: 'o.' + m.group(1).lower(), c)
    return c

cats = {'PluralZero': 'zero', 'PluralOne': 'one', 'PluralTwo': 'two', 'PluralFew': 'few', 'PluralMany': 'many', 'PluralOther': 'other'}

def convert(kind):
    lines = []
    i = 0
    while not src[i].startswith('func %sRule' % kind): i += 1
    lines.append('/// The category of `o` by the %s rules of rule set `r`.' % kind)
    lines.append('pub fn rule(r: u8, o: *const Operands) Plural {')
    i += 1
    open_case = False
    while True:
        l = src[i]; i += 1
        s = l.strip()
        if s == 'switch r {':
            lines.append('    switch (r) {')
        elif s.startswith('case '):
            if open_case: lines.append('        },')
            lines.append('        %s => {' % s[5:-1]); open_case = True
        elif s.startswith('//'):
            lines.append('            ' + s)
        elif s.startswith('if ') and s.endswith('{'):
            lines.append('            if (%s) {' % cond(s[3:-2]))
        elif s.startswith('return Plural'):
            if l.startswith('\treturn'):
                lines.append('    return .other;')
            else:
                lines.append('                return .%s;' % cats[s[7:]])
        elif s == '}':
            if l == '\t\t}':
                lines.append('            }')
            elif l == '\t}':
                if open_case: lines.append('        },')
                lines.append('        else => {},')
                lines.append('    }')
            elif l == '}':
                lines.append('}'); break
        elif s == '':
            pass
        else:
            raise SystemExit('unknown line: ' + l)
    def arr(name, zig, typ):
        j = 0
        while not src[j].startswith('var %s = ' % name): j += 1
        res = ['pub const %s = [_]%s{' % (zig, typ)]
        j += 1
        while src[j] != '}':
            res.append('    ' + src[j].strip()); j += 1
        res.append('};')
        return res
    lines.append('')
    lines.append('/// The languages with %s rules, sorted, and the rule set of each.' % kind)
    lines += arr(kind + 'Langs', 'langs', '[]const u8')
    lines += arr(kind + 'Rules', 'rules', 'u8')
    lines.append('/// The categories of each rule set, a bit per `Plural`.')
    lines += arr(kind + 'Categories', 'categories', 'u8')
    head = ['// Generated from mygo\'s i18n/tables.go (CLDR 48.2.0) by src/i18n/gen/plurals.py. Do not edit.',
            '//! The %s plural rules of CLDR, a branch per distinct rule set.' % kind,
            'const plural = @import("plural.zig");',
            'const Plural = plural.Plural;',
            'const Operands = plural.Operands;', '']
    open('%s/plural_%s.zig' % (out_dir, kind), 'w', encoding='utf8', newline='\n').write('\n'.join(head + lines) + '\n')

convert('cardinal')
convert('ordinal')
