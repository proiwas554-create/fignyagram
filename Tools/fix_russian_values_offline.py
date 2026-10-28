#!/usr/bin/env python3
"""Fix Russian values in non-Russian tables using already translated duplicates."""
import re
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
CYR = re.compile(r'[А-Яа-яЁё]')

def load(lang):
    table = {}
    order = []
    for line in (ROOT / f"{lang}.lproj" / "Localizable.strings").read_text().splitlines(True):
        m = re.match(r'\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$', line)
        if m:
            table[m.group(1)] = m.group(2)
            order.append((m.group(1), line))
        else:
            order.append((None, line))
    return table, order

ru, _ = load("ru")
by_text = {}
for lang in ["en", "es", "de", "zh"]:
    table, _ = load(lang)
    for key, value in table.items():
        if key in ru and not CYR.search(value):
            by_text.setdefault(lang, {}).setdefault(ru[key], value)

total = 0
for lang in ["en", "es", "de", "zh"]:
    table, order = load(lang)
    out = []
    for key, line in order:
        if key and key in ru and CYR.search(table.get(key, "")):
            mapped = by_text.get(lang, {}).get(ru[key])
            if mapped:
                out.append(f'"{key}" = "{mapped.replace(chr(92), chr(92)*2).replace(chr(34), chr(92)+chr(34))}";\n')
                total += 1
                continue
        out.append(line)
    (ROOT / f"{lang}.lproj" / "Localizable.strings").write_text("".join(out))
print("offline-fixed values:", total)
