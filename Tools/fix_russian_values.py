#!/usr/bin/env python3
"""Re-translate table values that are still Russian, using MyMemory (no key)."""
import json, re, ssl, time, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / "Tools" / "translations_cache.json"
cache = json.loads(CACHE.read_text()) if CACHE.exists() else {}
CTX = ssl._create_unverified_context()
CYR = re.compile(r'[А-Яа-яЁё]')

def load(lang):
    rows = []
    for line in (ROOT / f"{lang}.lproj" / "Localizable.strings").read_text().splitlines(True):
        m = re.match(r'\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$', line)
        rows.append((m.group(1), m.group(2)) if m else (None, line))
    return rows

def google(text, lang):
    url = ("https://translate.googleapis.com/translate_a/single?client=gtx"
           f"&sl=ru&tl={lang}&dt=t&q={urllib.parse.quote(text)}")
    try:
        with urllib.request.urlopen(url, timeout=20, context=CTX) as r:
            data = json.loads(r.read().decode())
        out = "".join(p[0] for p in data[0] if p and p[0])
        if out and not CYR.search(out): return out
    except Exception:
        return None
    return None

def mymemory(text, lang):
    url = ("https://api.mymemory.translated.net/get?q=" + urllib.parse.quote(text[:480]) +
           f"&langpair=ru|{lang}")
    try:
        with urllib.request.urlopen(url, timeout=25, context=CTX) as r:
            data = json.loads(r.read().decode())
        out = (data.get("responseData") or {}).get("translatedText") or ""
        if out and not CYR.search(out) and "MYMEMORY WARNING" not in out.upper():
            return out
    except Exception:
        return None
    return None

def translate(text, lang):
    for prefix in ("g", "mm"):
        ck = f"{prefix}:{lang}:{text}"
        if ck in cache: return cache[ck]
    for attempt in range(2):
        out = google(text, lang)
        if out:
            cache[f"g:{lang}:{text}"] = out
            return out
        out = mymemory(text, lang)
        if out:
            cache[f"mm:{lang}:{text}"] = out
            return out
        time.sleep(0.5 * (attempt + 1))
    return None

def esc(v): return v.replace("\\", "\\\\").replace('"', '\\"')

ru = dict((k, v) for k, v in load("ru") if k)
for lang in ["en", "es", "de", "zh"]:
    rows = load(lang)
    broken = [k for k, v in rows if k and v and CYR.search(v) and k in ru]
    print(lang, "russian leftovers:", len(broken), flush=True)
    with ThreadPoolExecutor(max_workers=6) as pool:
        fixed = list(pool.map(lambda k: (k, translate(ru[k], lang)), broken))
    mapping = {k: v for k, v in fixed if v}
    out = []
    for k, v in rows:
        if k and k in mapping:
            out.append(f'"{k}" = "{esc(mapping[k])}";\n')
        elif k:
            out.append(f'"{k}" = "{esc(v)}";\n')
        else:
            out.append(v)
    (ROOT / f"{lang}.lproj" / "Localizable.strings").write_text("".join(out))
    CACHE.write_text(json.dumps(cache, ensure_ascii=False))
    print(lang, "fixed:", len(mapping), "remaining:", len(broken) - len(mapping), flush=True)
