#!/usr/bin/env python3
"""Fills missing keys in es/de/zh by translating the Russian table."""
import json, re, ssl, time, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / "Tools" / "translations_cache.json"
cache = json.loads(CACHE.read_text()) if CACHE.exists() else {}
CTX = ssl._create_unverified_context()

def load(lang):
    p = ROOT / f"{lang}.lproj" / "Localizable.strings"
    table = {}
    for line in p.read_text().splitlines() if p.exists() else []:
        m = re.match(r'\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', line)
        if m:
            table[m.group(1)] = m.group(2)
    return table

def translate(text, lang):
    ck = f"{lang}:{text}"
    if ck in cache:
        return cache[ck]
    url = ("https://translate.googleapis.com/translate_a/single?client=gtx"
           f"&sl=ru&tl={lang}&dt=t&q={urllib.parse.quote(text)}")
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=20, context=CTX) as r:
                data = json.loads(r.read().decode())
            out = "".join(part[0] for part in data[0] if part and part[0])
            if out:
                cache[ck] = out
                return out
        except Exception:
            time.sleep(0.3 * (attempt + 1))
    return text

def escape(v):
    return v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

ru = load("ru")
for lang in ["en", "es", "de", "zh"]:
    table = load(lang)
    missing = {k: v for k, v in ru.items() if k not in table or not table[k]}
    print(lang, "missing:", len(missing))
    if not missing:
        continue
    with ThreadPoolExecutor(max_workers=10) as pool:
        values = list(pool.map(lambda kv: translate(kv[1], lang), missing.items()))
    p = ROOT / f"{lang}.lproj" / "Localizable.strings"
    add = "".join(f'"{k}" = "{escape(v)}";\n' for k, v in zip(missing.keys(), values))
    p.write_text(p.read_text() + add)
CACHE.write_text(json.dumps(cache, ensure_ascii=False))
