#!/usr/bin/env python3
"""Report localization gaps: keys used in code but missing/empty in .lproj files."""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KEY_RE = re.compile(r'(?:L10n\.t|NSLocalizedString)\(\s*"([^"]+)"')
used = {}
for path in ROOT.glob("Telegram/**/*.swift"):
    for m in KEY_RE.finditer(path.read_text()):
        used.setdefault(m.group(1), 0)
        used[m.group(1)] += 1

def load(lang):
    p = ROOT / f"{lang}.lproj" / "Localizable.strings"
    table = {}
    if not p.exists():
        return table
    for line in p.read_text().splitlines():
        m = re.match(r'\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', line)
        if m:
            table[m.group(1)] = m.group(2)
    return table

missing_total = 0
for lang in ["ru", "en", "es", "de", "zh"]:
    table = load(lang)
    missing = [k for k in used if not table.get(k)]
    missing_total += len(missing)
    print(f"{lang}: keys={len(table)} missing={len(missing)}")
    for key in missing[:12]:
        print(f"   - {key}")
print("total gaps:", missing_total)
if missing_total == 0:
    print("ПОЛНАЯ ЛОКАЛИЗАЦИЯ ИНТЕРФЕЙСА ЗАВЕРШЕНА")
sys.exit(0 if missing_total == 0 else 1)
