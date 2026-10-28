#!/usr/bin/env python3
"""Force-localize every remaining Cyrillic Swift string literal.

Safety rails: comparisons, switch cases, UserDefaults keys, file paths, search
keywords and log calls are left untouched, because their values are data rather
than UI text. Everything else becomes NSLocalizedString("Generated.key").
"""
import hashlib, json, re, ssl, sys, time, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / "Tools" / "translations_cache.json"
cache = json.loads(CACHE.read_text()) if CACHE.exists() else {}
CTX = ssl._create_unverified_context()
CYR = re.compile(r'[А-Яа-яЁё]')
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')
SKIP_LINE = ("==", "!=", "case ", "forKey:", "hasPrefix", ".contains(",
             "Notification.Name", "CallDiag.log", "DiagnosticsLog",
             "URL(fileURLWithPath", "FileManager", "NSPredicate", "#selector",
             "L10n.t(", "NSLocalizedString(", "\\( ")

def translate(text, lang):
    if lang == "ru" or not CYR.search(text): return text
    ck = f"{lang}:{text}"
    if ck in cache: return cache[ck]
    url = ("https://translate.googleapis.com/translate_a/single?client=gtx"
           f"&sl=ru&tl={lang}&dt=t&q={urllib.parse.quote(text)}")
    for _ in range(3):
        try:
            with urllib.request.urlopen(url, timeout=20, context=CTX) as r:
                data = json.loads(r.read().decode())
            out = "".join(p[0] for p in data[0] if p and p[0])
            if out:
                cache[ck] = out
                return out
        except Exception:
            time.sleep(0.3)
    return text

def esc(v): return v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

pending = {}   # raw -> key
files = [p for p in ROOT.glob("Telegram/**/*.swift") if "ThirdParty" not in str(p)]
for path in files:
    text = path.read_text()
    for line in text.splitlines():
        if any(token in line for token in SKIP_LINE): continue
        if "\\(" in line: continue
        for m in LITERAL.finditer(line):
            raw = m.group(1)
            if CYR.search(raw) and "\\(" not in raw:
                key = "Generated." + hashlib.md5((path.stem + raw).encode()).hexdigest()[:12]
                pending[raw] = key

unique = list(pending.keys())
print(f"unique strings to translate: {len(unique)}", flush=True)
for lang in ["en", "es", "de", "zh"]:
    with ThreadPoolExecutor(max_workers=12) as pool:
        list(pool.map(lambda s: translate(s, lang), unique))
    CACHE.write_text(json.dumps(cache, ensure_ascii=False))
    print(f"translated: {lang}", flush=True)

entries = {}
changed = 0
for path in files:
    text = path.read_text()
    out_lines = []
    for line in text.splitlines(True):
        if any(token in line for token in SKIP_LINE) or "\\(" in line:
            out_lines.append(line); continue
        def repl(m):
            global changed
            raw = m.group(1)
            if raw not in pending: return m.group(0)
            changed += 1
            return f'NSLocalizedString("{pending[raw]}", comment: "")'
        out_lines.append(LITERAL.sub(repl, line))
    new = "".join(out_lines)
    if new != text:
        path.write_text(new)
    for raw, key in pending.items():
        entries[key] = {"ru": raw, **{lang: cache.get(f"{lang}:{raw}", raw) for lang in ["en","es","de","zh"]}}

for lang in ["ru", "en", "es", "de", "zh"]:
    p = ROOT / f"{lang}.lproj" / "Localizable.strings"
    existing = p.read_text()
    kept = [ln for ln in existing.splitlines(True) if not any(ln.startswith(f'"{k}"') for k in entries)]
    add = "".join(f'"{k}" = "{esc(v[lang])}";\n' for k, v in entries.items())
    p.write_text("".join(kept) + add)
CACHE.write_text(json.dumps(cache, ensure_ascii=False))
print("force-localized literals:", changed, "keys:", len(entries))
