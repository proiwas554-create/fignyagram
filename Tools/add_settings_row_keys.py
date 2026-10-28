import json, ssl, time, urllib.parse, urllib.request
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
cache=json.loads((ROOT/"Tools/translations_cache.json").read_text())
CTX=ssl._create_unverified_context()
def tr(text, lang):
    if lang=="ru": return text
    ck=f"{lang}:{text}"
    if ck in cache: return cache[ck]
    url=("https://translate.googleapis.com/translate_a/single?client=gtx"
         f"&sl=ru&tl={lang}&dt=t&q={urllib.parse.quote(text)}")
    for _ in range(3):
        try:
            with urllib.request.urlopen(url, timeout=20, context=CTX) as r:
                data=json.loads(r.read().decode())
            out="".join(p[0] for p in data[0] if p and p[0])
            if out: cache[ck]=out; return out
        except Exception: time.sleep(0.4)
    return text
keys={
 "Settings.Row.Proxy":"Прокси",
 "Settings.Row.General":"Настройки",
 "Settings.Row.Notifications":"Уведомления",
 "Settings.Row.Cache":"Память и кэш",
 "Settings.Row.Optimization":"Оптимизация",
 "Settings.Row.Privacy":"Приватность",
 "Settings.Row.Limits":"Лимиты отображения",
 "Settings.Row.Developer":"Для разработчиков",
}
for lang in ["ru","en","es","de","zh"]:
    p=ROOT/f"{lang}.lproj"/"Localizable.strings"
    existing=p.read_text()
    kept=[ln for ln in existing.splitlines(True) if not any(ln.startswith(f'"{k}"') for k in keys)]
    add="".join(f'"{k}" = "{tr(v,lang)}";\n' for k,v in keys.items())
    p.write_text("".join(kept)+add)
(ROOT/"Tools/translations_cache.json").write_text(json.dumps(cache, ensure_ascii=False))
print("settings row keys added")
