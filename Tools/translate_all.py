#!/usr/bin/env python3
"""Wrap every remaining user-facing Russian literal and translate it.

- finds `Text/Label/Button/Section/Toggle/Picker/navigationTitle/alert/TextField("...")`
- replaces the literal with L10n.t("Auto.<hash>")
- translates each unique string to en/es/de/zh and writes Localizable.strings
"""
import hashlib, json, re, ssl, sys, time, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SWIFT = list(ROOT.glob("Telegram/**/*.swift"))
CALLS = r'(Text|Label|Button|Section|Toggle|Picker|navigationTitle|alert|confirmationDialog|TextField)'
PATTERN = re.compile(CALLS + r'\(\s*"([^"\\]+)"')
CYR = re.compile(r'[А-Яа-яЁё]')
CTX = ssl._create_unverified_context()
CACHE = ROOT / "Tools" / "translations_cache.json"
cache = json.loads(CACHE.read_text()) if CACHE.exists() else {}

def key_for(text: str) -> str:
    return "Auto." + hashlib.md5(text.encode("utf-8")).hexdigest()[:10]

def translate(text: str, lang: str) -> str:
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

def escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

def main():
    strings = {}
    changed = 0
    for path in SWIFT:
        text = path.read_text()
        def repl(m):
            nonlocal changed
            call, value = m.group(1), m.group(2)
            if not CYR.search(value) or "\\(" in value or len(value) > 300:
                return m.group(0)
            k = key_for(value)
            strings[k] = value
            changed += 1
            return f'{call}(L10n.t("{k}")'
        new = PATTERN.sub(repl, text)
        if new != text:
            path.write_text(new)
    print(f"wrapped: {changed}, unique: {len(strings)}")

    langs = ["en", "es", "de", "zh"]
    for lang in langs:
        with ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda kv: translate(kv[1], lang), strings.items()))
        CACHE.write_text(json.dumps(cache, ensure_ascii=False))

    all_values = {"ru": {k: v for k, v in strings.items()},
                  **{lang: {k: cache.get(f"{lang}:{v}", v) for k, v in strings.items()}
                     for lang in langs}}
    for lang, values in all_values.items():
        p = ROOT / f"{lang}.lproj" / "Localizable.strings"
        existing = p.read_text() if p.exists() else ""
        kept = [ln for ln in existing.splitlines(True)
                if not any(ln.startswith(f'"{k}"') for k in strings)]
        add = "".join(f'"{k}" = "{escape(values[k])}";\n' for k in strings)
        p.write_text("".join(kept) + add)
    print("strings files updated")

if __name__ == "__main__":
    main()
