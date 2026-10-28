#!/usr/bin/env python3
"""Targeted localization for computed labels/rows that the generic scanner misses."""
import hashlib, json, re, ssl, time, urllib.parse, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / "Tools" / "translations_cache.json"
cache = json.loads(CACHE.read_text()) if CACHE.exists() else {}
CTX = ssl._create_unverified_context()
CYR = re.compile(r'[А-Яа-яЁё]')

def translate(text, lang):
    if not CYR.search(text): return text
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
                cache[ck] = out; return out
        except Exception:
            time.sleep(0.3 * (attempt + 1))
    return text

def esc(v): return v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

entries = {}
def entry(text, key_prefix="AutoT"):
    key = f"{key_prefix}." + hashlib.md5(text.encode()).hexdigest()[:10]
    vals = {"ru": text}
    for lang in ["en", "es", "de", "zh"]:
        vals[lang] = translate(text, lang)
    entries[key] = vals
    return key

# 1) Settings rows: row("...")
p = ROOT / "Telegram/UI/Models/Fignyagram/SettingsView.swift"
s = p.read_text()
def row_repl(m):
    text = m.group(1)
    if not CYR.search(text): return m.group(0)
    return f'row(L10n.t("{entry(text)}")'
s = re.sub(r'row\("((?:[^"\\]|\\.)*)"', row_repl, s)
s = s.replace('.searchable(text: $search, prompt: "Поиск чатов, каналов, контактов")',
              '.searchable(text: $search, prompt: L10n.t("' + entry("Поиск чатов, каналов, контактов") + '"))')
p.write_text(s)

# 2) Music labels returned from computed properties and picker titles
p = ROOT / "Telegram/UI/Models/Fignyagram/Music/MusicView.swift"
s = p.read_text()
def ret_repl(m):
    text = m.group(1)
    if not CYR.search(text): return m.group(0)
    return f'return L10n.t("{entry(text)}")'
s = re.sub(r'return "((?:[^"\\]|\\.)*)"', ret_repl, s)
def picker_repl(m):
    text = m.group(1)
    if not CYR.search(text): return m.group(0)
    return f'ChatPickerView(title: L10n.t("{entry(text)}")'
s = re.sub(r'ChatPickerView\(title: "((?:[^"\\]|\\.)*)"', picker_repl, s)
s = s.replace('?? "Чат"', '?? L10n.t("' + entry("Чат") + '")')
p.write_text(s)

# 3) Pin/unpin menu label
p = ROOT / "Telegram/UI/ChatListView.swift"
s = p.read_text()
s = s.replace('Label(isPinned(chat) ? "Открепить" : "Закрепить", systemImage: "pin.fill")',
              f'Label(isPinned(chat) ? L10n.t("{entry("Открепить")}") : L10n.t("{entry("Закрепить")}"), systemImage: "pin.fill")')
p.write_text(s)

for lang in ["ru", "en", "es", "de", "zh"]:
    p = ROOT / f"{lang}.lproj" / "Localizable.strings"
    existing = p.read_text()
    kept = [ln for ln in existing.splitlines(True) if not any(ln.startswith(f'"{k}"') for k in entries)]
    add = "".join(f'"{k}" = "{esc(v[lang])}";\n' for k, v in entries.items())
    p.write_text("".join(kept) + add)
CACHE.write_text(json.dumps(cache, ensure_ascii=False))
print("targeted keys:", len(entries))
