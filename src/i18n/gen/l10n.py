# Writes myzig's own strings, src/l10n/{en,zh-Hans,zh-Hant}.json, from
# mygo's internal/l10n/en.json and locales/<tag>/<tag>.json: the keys that
# myzig's widgets and menus say.
import json, sys
mygo, out = sys.argv[1], sys.argv[2]
keys = """previousMonth nextMonth undo cut copy paste delete selectAll find search clear removeToken
saturation hex divider more noResults noMatches previous next done close colorValue hours minutes dayPeriod
untitled cancel save rename ok open selectFolder
menuUndo menuRedo menuCut menuCopy menuPaste menuPasteAndMatchStyle menuDelete menuSelectAll
menuReload menuToggleDevTools menuActualSize menuZoomIn menuZoomOut menuToggleFullScreen
menuMinimize menuZoom menuBringAllToFront menuClose menuCloseWindow menuNew menuOpen menuSave
menuQuitApp menuAbout menuHide menuQuit menuExit menuHideOthers menuShowAll menuServices
menuFile menuEdit menuView menuWindow menuHelp""".split()

def load(p):
    return json.load(open(p, encoding='utf8'))

def write(path, d):
    with open(path, 'w', encoding='utf8', newline='\n') as f:
        json.dump(d, f, ensure_ascii=False, indent=2)
        f.write('\n')

en = load(mygo + '/internal/l10n/en.json')
src = {'@@locale': 'en'}
for k in keys:
    src[k] = en[k]
    if '@' + k in en:
        src['@' + k] = en['@' + k]
write(out + '/en.json', src)
for tag in ['zh-Hans', 'zh-Hant']:
    t = load('%s/locales/%s/%s.json' % (mygo, tag, tag))
    d = {'@@locale': tag}
    for k in keys:
        if k in t:
            d[k] = t[k]
    write('%s/%s.json' % (out, tag), d)
print(len(keys), 'keys')
