package i18n

// Dumps the CLDR data myzig's src/i18n keeps, from mygo's i18n (CLDR 48.2),
// as Zig, with the cases its formatting tests compare. Copy this file into
// mygo's i18n/ (it reads the package's unexported tables), run
//
//	go test ./i18n -run TestZZDump -count=1 -out <myzig>/src/i18n
//
// and zig fmt the files it writes (data_*.zig, tests_*_cases.zig). The
// plural rules come from mygo's i18n/tables.go through plurals.py, the
// message cases from its testdata/messages.json through messages.py, and
// myzig's own strings from its internal/l10n through l10n.py.

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
	"unicode"

	"golang.org/x/text/language"
)

var outDir = flag.String("out", "", "myzig's src/i18n")

var fmtLocales = strings.Fields(`en en-001 en-150 en-AU en-CA en-GB en-IE en-IN en-NZ en-ZA
de de-AT de-CH fr fr-BE fr-CA fr-CH es es-419 es-MX es-US it pt pt-PT nl sv da nb fi is
pl cs sk sl hr sr sr-Latn bg ro hu el et lv lt ru uk tr he ar ar-EG fa ur hi bn ta th vi id ms
fil ja ko zh zh-Hant zh-Hant-HK ca`)

const header = "// Generated from mygo's i18n (CLDR " + CLDRVersion + ") by src/i18n/gen/dump_test.go. Do not edit.\n"

func zs(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch {
		case r == '"' || r == '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		case r == ' ' || (r < 0x80 && unicode.IsPrint(r)):
			b.WriteRune(r)
		case r >= 0x80 && unicode.IsPrint(r) && !unicode.IsSpace(r) && !unicode.Is(unicode.Cf, r):
			b.WriteRune(r)
		default:
			fmt.Fprintf(&b, "\\u{%x}", r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

func joined(v []string) string {
	for i := range v {
		v[i] = strings.ReplaceAll(v[i], " ", " ")
	}
	return zs(strings.Join(v, "|"))
}

func affixes(p numberPattern, pct bool) string {
	var parts []string
	def := numberPattern{negPrefix: "-", primary: 3, secondary: 3, maxFrac: 3, minInt: 1}
	pctDef := def
	pctDef.suffix, pctDef.negSuffix, pctDef.maxFrac = "%", "%", 0
	if pct && p == pctDef {
		return ".{}"
	}
	add := func(name, v, d string) {
		if v != d {
			parts = append(parts, "."+name+" = "+zs(v))
		}
	}
	addN := func(name string, v, d int) {
		if v != d {
			parts = append(parts, fmt.Sprintf(".%s = %d", name, v))
		}
	}
	add("prefix", p.prefix, def.prefix)
	add("suffix", p.suffix, def.suffix)
	add("neg_prefix", p.negPrefix, def.negPrefix)
	add("neg_suffix", p.negSuffix, def.negSuffix)
	addN("primary", p.primary, def.primary)
	addN("secondary", p.secondary, def.secondary)
	addN("max_frac", p.maxFrac, def.maxFrac)
	addN("min_int", p.minInt, def.minInt)
	return ".{" + strings.Join(parts, ", ") + "}"
}

func system(s *numberSystem) string {
	var parts []string
	if !s.latin {
		r := []rune(s.digits[0])
		parts = append(parts, fmt.Sprintf(".zero = 0x%x", r[0]))
	}
	for _, f := range []struct{ name, v, d string }{
		{"decimal", s.decimalSep, "."}, {"group", s.group, ","}, {"minus", s.minus, "-"},
		{"percent", s.percentSign, "%"}, {"nan", s.nan, "NaN"},
	} {
		if f.v != f.d {
			parts = append(parts, "."+f.name+" = "+zs(f.v))
		}
	}
	if s.minGrouping != 1 {
		parts = append(parts, fmt.Sprintf(".min_grouping = %d", s.minGrouping))
	}
	if a := affixes(s.decimal, false); a != ".{}" {
		parts = append(parts, ".dec = "+a)
	}
	if a := affixes(s.percent, true); a != ".{}" {
		parts = append(parts, ".pct = "+a)
	}
	return ".{" + strings.Join(parts, ", ") + "}"
}

var skeletons = strings.Fields("yMd yMMMd yMMMMd yMMMEd yMMMMEEEEd yM yMMM yMMMM y Md MMMd MMMMd MEd MMMEd Ed d MMM LLLL E EEEE jm jms Hm Hms hm hms")

func write(t *testing.T, name, body string) {
	if err := os.WriteFile(filepath.Join(*outDir, name), []byte(header+body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestZZDump(t *testing.T) {
	if *outDir == "" {
		t.Skip("no -out")
	}
	have := map[string]bool{}
	for _, l := range FormatLocales() {
		have[l] = true
	}
	var nums strings.Builder
	nums.WriteString("//! The numbers of each locale myzig formats with: symbols, digits and patterns.\nconst data = @import(\"locale_data.zig\");\n\n/// The locales, sorted as `dates`, and the index of their numbering\n/// system in `systems` (and of their Latin one, -u-nu-latn).\npub const numbers = [_]data.Numbers{\n")
	var systems []string
	sysIndex := func(s string) int {
		for i, x := range systems {
			if x == s {
				return i
			}
		}
		systems = append(systems, s)
		return len(systems) - 1
	}
	var dates []string
	for _, loc := range fmtLocales {
		if !have[loc] {
			t.Fatalf("no data of %s", loc)
		}
		k := keyOf(loc)
		d := k.dates()
		def := d.numbers(false)
		latn := d.numbers(true)
		line := fmt.Sprintf("    .{ .tag = %s, .sys = %d", zs(loc), sysIndex(system(def)))
		if latn != def {
			line += fmt.Sprintf(", .latn = %d", sysIndex(system(latn)))
		}
		nums.WriteString(line + " },\n")

		v := d.v
		var months []string
		for _, ctxW := range [][2]int{{0, 2}, {0, 0}, {0, 1}, {1, 2}, {1, 0}, {1, 1}} {
			base := slotMonths + (ctxW[0]*3+ctxW[1])*12
			months = append(months, joined(append([]string(nil), v[base:base+12]...)))
		}
		var days []string
		for _, ctxW := range [][2]int{{0, 3}, {0, 0}, {0, 2}, {0, 1}, {1, 3}, {1, 0}, {1, 2}, {1, 1}} {
			base := slotDays + (ctxW[0]*4+ctxW[1])*7
			days = append(days, joined(append([]string(nil), v[base:base+7]...)))
		}
		var periods []string
		for w := 0; w < 3; w++ {
			base := slotDayPeriods + w*len(periodNames)
			periods = append(periods, v[base], v[base+1])
		}
		flex := ""
		if periodRules(k.lang, d.tag) != nil {
			base := slotDayPeriods
			flex = joined(append([]string(nil), v[base+2:base+12]...))
		}
		var t12, t24 []string
		for s := FullStyle; s >= ShortStyle; s-- {
			t12 = append(t12, NewDateFormatter(loc, DateOptions{Time: s, HourCycle: 12}).Pattern())
			t24 = append(t24, NewDateFormatter(loc, DateOptions{Time: s, HourCycle: 24}).Pattern())
		}
		var skel []string
		for _, s := range skeletons {
			skel = append(skel, NewDateFormatter(loc, DateOptions{Skeleton: s}).Pattern())
		}
		at := append([]string(nil), v[slotAtTimeFormats:slotZone]...)
		for i := range at {
			if at[i] == "" {
				at[i] = v[slotDateTimeFormats+i]
			}
		}
		hour := k.defaultHour()
		rec := fmt.Sprintf("    .{\n        .tag = %s, .autonym = %s, .hour = '%c', .first_day = %d,\n", zs(loc), zs(Autonym(loc)), hour, FirstWeekday(loc))
		rec += "        .months = .{ " + strings.Join(months[:3], ", ") + " },\n"
		rec += "        .months_alone = .{ " + strings.Join(months[3:], ", ") + " },\n"
		rec += "        .days = .{ " + strings.Join(days[:4], ", ") + " },\n"
		rec += "        .days_alone = .{ " + strings.Join(days[4:], ", ") + " },\n"
		rec += "        .periods = " + joined(periods) + ",\n"
		if flex != "" {
			rec += "        .flex = " + flex + ",\n"
		}
		rec += "        .eras = " + joined(append([]string(nil), v[slotEras:slotDateFormats]...)) + ",\n"
		rec += "        .date = " + joined(append([]string(nil), v[slotDateFormats:slotTimeFormats]...)) + ",\n"
		rec += "        .time = " + joined(append([]string(nil), v[slotTimeFormats:slotDateTimeFormats]...)) + ",\n"
		rec += "        .time12 = " + joined(t12) + ",\n"
		rec += "        .time24 = " + joined(t24) + ",\n"
		rec += "        .glue = " + joined(at) + ",\n"
		rec += "        .zone = " + joined(append([]string(nil), v[slotZone:slotNumbers]...)) + ",\n"
		rec += "        .skeletons = " + joined(skel) + ",\n"
		rec += "    },\n"
		dates = append(dates, rec)
	}
	nums.WriteString("};\n\n/// The numbering systems of the locales.\npub const systems = [_]data.System{\n")
	for _, x := range systems {
		nums.WriteString("    " + x + ",\n")
	}
	nums.WriteString("};\n")
	write(t, "data_numbers.zig", nums.String())

	third := (len(dates) + 2) / 3
	for i, part := range [][]string{dates[:third], dates[third : 2*third], dates[2*third:]} {
		body := fmt.Sprintf("//! The dates of locales myzig formats with (part %d of 3): names and patterns.\nconst Dates = @import(\"locale_data.zig\").Dates;\n\npub const dates = [_]Dates{\n%s};\n", i+1, strings.Join(part, ""))
		write(t, fmt.Sprintf("data_dates_%d.zig", i+1), body)
	}
	var sk strings.Builder
	for i, s := range skeletons {
		if i > 0 {
			sk.WriteString(", ")
		}
		sk.WriteString(zs(s))
	}
	tags(t, sk.String())
	golden(t)
}

// tags writes data_tags.zig: likely subtags, scripts by region, parents,
// week and hour data.
func tags(t *testing.T, skel string) {
	langs := map[string]bool{}
	for _, l := range cardinalLangs {
		langs[strings.Split(l, "-")[0]] = true
	}
	for _, l := range ordinalLangs {
		langs[strings.Split(l, "-")[0]] = true
	}
	for _, l := range FormatLocales() {
		langs[strings.Split(l, "-")[0]] = true
	}
	for _, l := range parentChildren {
		langs[strings.Split(l, "-")[0]] = true
	}
	for _, l := range strings.Fields("arc mzn lrc glk syr nqo yi ks ckb dv ps sd ug ur fa he ar ku az pa sr uz mn bs ha ms ff kk ky shi vai yue zh tg iu sat") {
		langs[l] = true
	}
	delete(langs, "und")
	var sorted []string
	for l := range langs {
		sorted = append(sorted, l)
	}
	sort.Strings(sorted)
	var b strings.Builder
	b.WriteString("//! Tags: the likely script and region of languages, the scripts of\n//! languages in regions, CLDR's parent locales, and week and hour data.\n\n")
	b.WriteString("/// \"lang Script RG\" entries, sorted by language, separated by `;`.\npub const likely =\n")
	var entries []string
	for _, l := range sorted {
		tg := language.Make(l)
		s, _ := tg.Script()
		r, _ := tg.Region()
		entries = append(entries, l+" "+s.String()+" "+r.String())
	}
	for i := 0; i < len(entries); i += 6 {
		end := min(i+6, len(entries))
		sep := " ++\n"
		if end == len(entries) {
			sep = ";\n\n"
		}
		b.WriteString("    " + zs(strings.Join(entries[i:end], ";")+";") + sep)
	}
	// Scripts other than the language's likely one, by region, and the
	// likely region of a language in another script.
	var regions []string
	for a := 'A'; a <= 'Z'; a++ {
		for c := 'A'; c <= 'Z'; c++ {
			if r, err := language.ParseRegion(string([]rune{a, c})); err == nil && r.IsCountry() {
				regions = append(regions, r.String())
			}
		}
	}
	var byRegion, scripted []string
	for _, l := range sorted {
		ls, _ := language.Make(l).Script()
		seen := map[string]bool{}
		for _, r := range regions {
			s, conf := language.Make(l + "-" + r).Script()
			if conf != language.No && s != ls {
				byRegion = append(byRegion, l+"-"+r+" "+s.String())
				seen[s.String()] = true
			}
		}
		for _, s := range strings.Fields("Latn Cyrl Arab Hans Hant Deva Guru Hebr Mong Tfng Vaii Adlm Orya Telu Beng") {
			if s == ls.String() {
				continue
			}
			tg, err := language.Parse(l + "-" + s)
			if err != nil {
				continue
			}
			if r, conf := tg.Region(); conf != language.No && (seen[s] || conf >= language.High) {
				m, _ := language.Make(l).Region()
				if r != m || seen[s] {
					scripted = append(scripted, l+"-"+s+" "+r.String())
				}
			}
		}
	}
	b.WriteString("/// \"lang-RG Script\" where a region writes a language in another script, sorted.\npub const region_scripts = [_][]const u8{\n")
	for i := 0; i < len(byRegion); i += 8 {
		end := min(i+8, len(byRegion))
		b.WriteString("    ")
		for _, e := range byRegion[i:end] {
			b.WriteString(zs(e) + ", ")
		}
		b.WriteString("\n")
	}
	b.WriteString("};\n\n/// \"lang-Script RG\": the likely region of a language in a script other than its own, sorted.\npub const script_regions = [_][]const u8{\n")
	sort.Strings(scripted)
	for i := 0; i < len(scripted); i += 8 {
		end := min(i+8, len(scripted))
		b.WriteString("    ")
		for _, e := range scripted[i:end] {
			b.WriteString(zs(e) + ", ")
		}
		b.WriteString("\n")
	}
	b.WriteString("};\n\n/// CLDR's parent locales: the children, sorted, and their parents (\"\" for the root).\npub const parent_children = [_][]const u8{\n")
	list := func(v []string) {
		for i := 0; i < len(v); i += 8 {
			end := min(i+8, len(v))
			b.WriteString("    ")
			for _, e := range v[i:end] {
				b.WriteString(zs(e) + ", ")
			}
			b.WriteString("\n")
		}
	}
	list(parentChildren[:])
	b.WriteString("};\npub const parent_locales = [_][]const u8{\n")
	list(parentLocales[:])
	b.WriteString("};\n\n")
	loadTables()
	b.WriteString("/// The regions of CLDR's week data, sorted, and their first day of the\n/// week (0 Sunday) in the low 4 bits of `week`.\npub const week_regions = [_][]const u8{\n")
	list(tables.weekRegions)
	b.WriteString("};\npub const week = " + zs(fmtWeek) + ";\n\n")
	b.WriteString("/// The keys of CLDR's time data (regions, and lang-RG), sorted, and the\n/// hour symbol each prefers.\npub const hour_keys = [_][]const u8{\n")
	list(tables.hourKeys)
	b.WriteString("};\npub const hours = " + zs(fmtHours) + ";\n\n")
	b.WriteString("/// The names of languages in themselves of tags apps use that are not\n/// locales of the dates' data, sorted.\npub const autonyms = [_][2][]const u8{\n")
	for _, a := range strings.Fields("de-DE en-US es-ES fr-FR it-IT ja-JP ko-KR pt-BR ru-RU sr-Cyrl zh-Hans zh-Hans-CN zh-Hant-TW zh-TW") {
		b.WriteString("    .{ " + zs(a) + ", " + zs(Autonym(a)) + " },\n")
	}
	b.WriteString("};\n\n")
	b.WriteString("/// The skeletons of `Dates.skeletons`, in their order.\npub const skeletons = [_][]const u8{ " + skel + " };\n")
	write(t, "data_tags.zig", b.String())
}

// golden writes the tests' cases: what mygo writes, which matches ICU.
func golden(t *testing.T) {
	locs := strings.Fields("en en-GB en-IN de de-CH fr es es-MX pt-BR it nl pl ru uk tr he ar ar-EG fa hi bn ja ko zh zh-TW sv")
	numbers := []string{"0", "1", "-1", "1.5", "0.001234", "1234.5", "-1234567.891", "12345", "1234", "1000000", "2.5", "99999.9999"}
	var b strings.Builder
	b.WriteString("//! What mygo's i18n writes for these numbers, which matches ICU: the formatting tests compare.\n\n")
	b.WriteString("pub const Num = struct { locale: []const u8, value: []const u8, kind: enum { plain, percent, min2, no_group, half_even, integer } = .plain, want: []const u8 };\n\n")
	b.WriteString("pub const nums = [_]Num{\n")
	for _, loc := range locs {
		var line []string
		for _, n := range numbers {
			line = append(line, fmt.Sprintf(".{ .locale = %s, .value = %s, .want = %s }", zs(loc), zs(n), zs(FormatNumber(loc, n, NumberOptions{}))))
		}
		for _, c := range []struct {
			kind, n string
			o       NumberOptions
		}{
			{"percent", "0.256", NumberOptions{Percent: true}}, {"percent", "-0.5", NumberOptions{Percent: true}},
			{"min2", "1234.5", NumberOptions{MinFractionDigits: 2}}, {"no_group", "1234567.891", NumberOptions{NoGrouping: true}},
			{"half_even", "2.5", NumberOptions{Integer: true, HalfEven: true}}, {"integer", "2.5", NumberOptions{Integer: true}},
		} {
			line = append(line, fmt.Sprintf(".{ .locale = %s, .value = %s, .kind = .%s, .want = %s }", zs(loc), zs(c.n), c.kind, zs(FormatNumber(loc, c.n, c.o))))
		}
		for i := 0; i < len(line); i += 2 {
			b.WriteString("    " + strings.Join(line[i:min(i+2, len(line))], ", ") + ",\n")
		}
	}
	b.WriteString("};\n")
	write(t, "tests_number_cases.zig", b.String())

	b.Reset()
	b.WriteString("//! What mygo's i18n writes for these dates, which matches ICU: the formatting tests compare.\n\n")
	b.WriteString("pub const Date = struct { locale: []const u8, unix: i64, date: u3 = 0, time: u3 = 0, skeleton: []const u8 = \"\", hour_cycle: u8 = 0, want: []const u8 };\n\n")
	b.WriteString("pub const dates = [_]Date{\n")
	times := []time.Time{time.Date(2026, 1, 5, 13, 7, 9, 0, time.UTC), time.Date(2025, 12, 29, 0, 7, 9, 0, time.UTC)}
	for _, loc := range locs {
		for ti, tm := range times {
			var line []string
			add := func(o DateOptions, extra string) {
				line = append(line, fmt.Sprintf(".{ .locale = %s, .unix = %d%s, .want = %s }", zs(loc), tm.Unix(), extra, zs(strings.ReplaceAll(FormatDate(loc, tm, o), "\u202f", " "))))
			}
			for s := ShortStyle; s <= FullStyle; s++ {
				add(DateOptions{Date: s}, fmt.Sprintf(", .date = %d", s))
			}
			add(DateOptions{Time: ShortStyle}, ", .time = 1")
			add(DateOptions{Time: MediumStyle}, ", .time = 2")
			add(DateOptions{Date: ShortStyle, Time: ShortStyle}, ", .date = 1, .time = 1")
			add(DateOptions{Date: FullStyle, Time: ShortStyle}, ", .date = 4, .time = 1")
			if ti == 0 {
				add(DateOptions{Time: LongStyle}, ", .time = 3")
				for _, s := range []string{"yMMMd", "yMMMM", "MMMd", "Ed", "jm", "LLLL", "yMMMEd"} {
					add(DateOptions{Skeleton: s}, ", .skeleton = "+zs(s))
				}
				add(DateOptions{Time: ShortStyle, HourCycle: 12}, ", .time = 1, .hour_cycle = 12")
				add(DateOptions{Time: ShortStyle, HourCycle: 24}, ", .time = 1, .hour_cycle = 24")
				add(DateOptions{Skeleton: "jm", HourCycle: 24}, ", .skeleton = \"jm\", .hour_cycle = 24")
			}
			for i := 0; i < len(line); i += 2 {
				b.WriteString("    " + strings.Join(line[i:min(i+2, len(line))], ", ") + ",\n")
			}
		}
	}
	b.WriteString("};\n")
	write(t, "tests_date_cases.zig", b.String())
}
