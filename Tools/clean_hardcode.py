#!/usr/bin/env python3
"""Wrap remaining Cyrillic literals in settings/menus and fill all languages."""
import hashlib, re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = []
FILES += [str(p.relative_to(ROOT)) for p in (ROOT / "Telegram/UI").rglob("*.swift")]
FILES += [
 "Telegram/UI/Models/Fignyagram/CacheSettingsView.swift",
 "Telegram/UI/Models/Fignyagram/CryptoNotes.swift",
 "Telegram/UI/Models/Fignyagram/AutomationEngine.swift",
 "Telegram/UI/Models/Fignyagram/HardwareSettingsView.swift",
 "Telegram/UI/Models/Fignyagram/Profiles/SecretProfiles.swift",
 "Telegram/UI/Models/Fignyagram/NewsFeedDataManager.swift",
 "Telegram/UI/Models/Fignyagram/DeveloperSettingsView.swift",
 "Telegram/UI/Models/Fignyagram/CommandPaletteView.swift",
 "Telegram/UI/Models/Fignyagram/Proxy/ProxySettingsView.swift",
]
CYR = re.compile(r'[А-Яа-яЁё]')
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')
SKIP = ("==", "!=", "case ", "forKey:", "contains(", "L10n.t(", "NSLocalizedString(",
        "hasPrefix", "CallDiag.log", "DiagnosticsLog", "URL(", "FileManager", "#selector")

def load(lang):
    table = {}
    path = ROOT / f"{lang}.lproj" / "Localizable.strings"
    for line in path.read_text().splitlines():
        m = re.match(r'\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', line)
        if m:
            table[m.group(1)] = m.group(2)
    return table

ru, en, es, de, zh = (load(l) for l in ["ru", "en", "es", "de", "zh"])
# reuse existing translations by Russian value
translations = {}
for key, value in ru.items():
    translations.setdefault(value, (
        en.get(key, value), es.get(key, value), de.get(key, value), zh.get(key, value)
    ))

entries = {}
changed = 0
for rel in FILES:
    path = ROOT / rel
    if not path.exists():
        continue
    text = path.read_text()
    out = []
    for line in text.splitlines(True):
        if any(token in line for token in SKIP) or "\\(" in line:
            out.append(line)
            continue
        # only simple single-literal lines: avoids touching interpolations
        if line.count('"') != 2:
            out.append(line)
            continue
        def repl(m):
            global changed
            raw = m.group(1)
            if not CYR.search(raw):
                return m.group(0)
            key = "SettingsGen." + hashlib.md5(raw.encode()).hexdigest()[:10]
            values = translations.get(raw, (raw, raw, raw, raw))
            entries[key] = (raw, *values)
            changed += 1
            return f'L10n.t("{key}")'
        out.append(LITERAL.sub(repl, line))
    new = "".join(out)
    if new != text:
        path.write_text(new)

for idx, lang in enumerate(["ru", "en", "es", "de", "zh"]):
    p = ROOT / f"{lang}.lproj" / "Localizable.strings"
    existing = p.read_text()
    kept = [ln for ln in existing.splitlines(True) if not any(ln.startswith(f'"{k}"') for k in entries)]
    add = "".join(f'"{k}" = "{v[idx].replace(chr(92), chr(92)*2).replace(chr(34), chr(92)+chr(34))}";\n'
                  for k, v in entries.items())
    p.write_text("".join(kept) + add)
print("wrapped:", changed, "unique:", len(entries))
