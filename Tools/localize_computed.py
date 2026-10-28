#!/usr/bin/env python3
"""Localize computed user-facing strings (return/assignment) that stayed Russian."""
import hashlib, json, re, ssl, time, urllib.parse, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / "Tools" / "translations_cache.json"
cache = json.loads(CACHE.read_text()) if CACHE.exists() else {}
CTX = ssl._create_unverified_context()
CYR = re.compile(r'[А-Яа-яЁё]')
INTERP = re.compile(r'\\\(([^()]*)\)')
FILES = [
    "Telegram/UI/Models/MessageFormatter.swift",
    "Telegram/UI/Models/Fignyagram/CallManager.swift",
    "Telegram/UI/Models/Fignyagram/GroupCallManager.swift",
    "Telegram/UI/Models/Fignyagram/Music/MusicPlayer.swift",
]
PATTERN = re.compile(r'(return |stateText = |status = |title = )"((?:[^"\\]|\\.)*)"')

def translate(text, lang):
    if not text.strip() or not CYR.search(text):
        return text
    ck = f"{lang}:{text}"
    if ck in cache: return cache[ck]
    url = ("https://translate.googleapis.com/translate_a/single?client=gtx"
           f"&sl=ru&tl={lang}&dt=t&q={urllib.parse.quote(text)}")
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=20, context=CTX) as r:
                data = json.loads(r.read().decode())
            out = "".join(p[0] for p in data[0] if p and p[0])
            if out:
                cache[ck] = out
                return out
        except Exception:
            time.sleep(0.3 * (attempt + 1))
    return text

def esc(v): return v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

entries = {}
wrapped = 0
for rel in FILES:
    path = ROOT / rel
    if not path.exists(): continue
    text = path.read_text()
    def repl(m):
        global wrapped
        prefix, raw = m.group(1), m.group(2)
        if not CYR.search(raw) or "\\(" not in raw and raw.endswith("%@"):
            return m.group(0)
        parts = INTERP.split(raw)
        literals, exprs = parts[0::2], parts[1::2]
        template = ""
        for i, lit in enumerate(literals):
            template += lit
            if i < len(exprs): template += "%@"
        key = "AutoR." + hashlib.md5(template.encode()).hexdigest()[:10]
        values = {"ru": template}
        for lang in ["en", "es", "de", "zh"]:
            out = ""
            for i, lit in enumerate(literals):
                out += translate(lit.replace('\\"', '"'), lang)
                if i < len(exprs): out += "%@"
            values[lang] = out
        entries[key] = values
        wrapped += 1
        if exprs:
            args = ", ".join(f"String(describing: {e})" for e in exprs)
            return f'{prefix}String(format: L10n.t("{key}"), {args})'
        return f'{prefix}L10n.t("{key}")'
    new = PATTERN.sub(repl, text)
    if new != text:
        path.write_text(new)

for lang in ["ru", "en", "es", "de", "zh"]:
    p = ROOT / f"{lang}.lproj" / "Localizable.strings"
    existing = p.read_text()
    kept = [ln for ln in existing.splitlines(True) if not any(ln.startswith(f'"{k}"') for k in entries)]
    add = "".join(f'"{k}" = "{esc(v[lang])}";\n' for k, v in entries.items())
    p.write_text("".join(kept) + add)
CACHE.write_text(json.dumps(cache, ensure_ascii=False))
print("computed strings localized:", wrapped, "unique:", len(entries))
