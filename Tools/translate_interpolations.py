#!/usr/bin/env python3
"""Localizes interpolated UI strings: "До \(n) сообщений" -> String(format: ..., n)."""
import hashlib, json, re, ssl, time, urllib.parse, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CALL_RE = re.compile(r'(Text|Label|Button|Section|Toggle|navigationTitle|alert)\("((?:[^"\\]|\\.)*\\\((?:[^"\\]|\\.)*)"\)')
INTERP_RE = re.compile(r'\\\(([^()]*)\)')
CYR = re.compile(r'[А-Яа-яЁё]')
CTX = ssl._create_unverified_context()
CACHE = ROOT / "Tools" / "translations_cache.json"
cache = json.loads(CACHE.read_text()) if CACHE.exists() else {}

def translate(text, lang):
    if not text.strip() or not CYR.search(text):
        return text
    ck = f"{lang}:{text}"
    if ck in cache:
        return cache[ck]
    url = ("https://translate.googleapis.com/translate_a/single?client=gtx"
           f"&sl=ru&tl={lang}&dt=t&q={urllib.parse.quote(text)}")
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=20, context=CTX) as r:
                data = json.loads(r.read().decode("utf-8"))
            out = "".join(part[0] for part in data[0] if part and part[0])
            if out:
                cache[ck] = out
                return out
        except Exception:
            time.sleep(0.4 * (attempt + 1))
    return text

def escape(v):
    return v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

entries = {}   # key -> {lang: value}
changed = 0
for path in ROOT.glob("Telegram/**/*.swift"):
    text = path.read_text()
    def repl(m):
        global changed
        call, raw = m.group(1), m.group(2)
        if not CYR.search(raw):
            return m.group(0)
        parts = INTERP_RE.split(raw)  # [text0, expr0, text1, expr1, ...]
        literals = parts[0::2]
        exprs = parts[1::2]
        template = ""
        for i, literal in enumerate(literals):
            template += literal
            if i < len(exprs):
                template += "%@"
        key = "AutoI." + hashlib.md5(template.encode()).hexdigest()[:10]
        values = {"ru": template}
        for lang in ["en", "es", "de", "zh"]:
            translated = ""
            for i, literal in enumerate(literals):
                translated += translate(literal, lang)
                if i < len(exprs):
                    translated += "%@"
            values[lang] = translated
        entries[key] = values
        args = ", ".join(f"String(describing: {expr})" for expr in exprs)
        changed += 1
        return f'{call}(String(format: L10n.t("{key}"), {args}))'
    new = CALL_RE.sub(repl, text)
    if new != text:
        path.write_text(new)

for lang in ["ru", "en", "es", "de", "zh"]:
    p = ROOT / f"{lang}.lproj" / "Localizable.strings"
    existing = p.read_text() if p.exists() else ""
    kept = [ln for ln in existing.splitlines(True) if not any(ln.startswith(f'"{k}"') for k in entries)]
    add = "".join(f'"{k}" = "{escape(v[lang])}";\n' for k, v in entries.items())
    p.write_text("".join(kept) + add)
CACHE.write_text(json.dumps(cache, ensure_ascii=False))
print("interpolated strings localized:", changed, "unique:", len(entries))
