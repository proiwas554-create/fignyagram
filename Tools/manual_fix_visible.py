#!/usr/bin/env python3
"""Hand translations for the strings visible in the screenshots (all 5 languages)."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
T = {
 "Добавленные": ("Added", "Añadidos", "Hinzugefügt", "已添加"),
 "Для вас": ("For you", "Para ti", "Für dich", "为你推荐"),
 "Важное": ("Important", "Importante", "Wichtig", "重要"),
 "Собираем ленту…": ("Building your feed…", "Preparando el feed…", "Feed wird erstellt…", "正在生成信息流…"),
 "Моя": ("My", "Mía", "Meine", "我的"),
 "Чаты": ("Chats", "Chats", "Chats", "聊天"),
 "Избранное": ("Saved", "Guardados", "Gespeichert", "收藏"),
 "Любимые": ("Favorites", "Favoritos", "Favoriten", "最爱"),
 "Профиль": ("Profile", "Perfil", "Profil", "个人资料"),
 "Недавние": ("Recent", "Recientes", "Zuletzt", "最近"),
 "Плейлист пуст": ("Playlist is empty", "La lista está vacía", "Wiedergabeliste ist leer", "播放列表为空"),
 "Добавить из файлов": ("Add from files", "Añadir desde archivos", "Aus Dateien hinzufügen", "从文件添加"),
 "Память и кэш": ("Memory & cache", "Memoria y caché", "Speicher & Cache", "内存与缓存"),
 "Ограничения отображения": ("Display limits", "Límites de pantalla", "Anzeigelimits", "显示限制"),
 "Устройства и сессии": ("Devices & sessions", "Dispositivos y sesiones", "Geräte & Sitzungen", "设备与会话"),
 "Включить прокси": ("Enable proxy", "Activar proxy", "Proxy aktivieren", "启用代理"),
 "Живой": ("Online", "En línea", "Online", "在线"),
 "в сети": ("online", "en línea", "online", "在线"),
}
LANG_INDEX = {"en": 0, "es": 1, "de": 2, "zh": 3}

def load(lang):
    rows = []
    for line in (ROOT / f"{lang}.lproj" / "Localizable.strings").read_text().splitlines(True):
        m = re.match(r'\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$', line)
        rows.append([m.group(1), m.group(2), line] if m else [None, None, line])
    return rows

def esc(v): return v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

tables = {lang: load(lang) for lang in ["ru", "en", "es", "de", "zh"]}
ru_rows = {row[0]: row[1] for row in tables["ru"] if row[0]}
keys_by_text = {}
for key, value in ru_rows.items():
    keys_by_text.setdefault(value, []).append(key)

fixed = 0
for lang, idx in LANG_INDEX.items():
    rows = tables[lang]
    for row in rows:
        key = row[0]
        if not key or key not in ru_rows:
            continue
        original = ru_rows[key]
        if original in T:
            row[1] = T[original][idx]
            row[2] = f'"{key}" = "{esc(row[1])}";\n'
            fixed += 1
    (ROOT / f"{lang}.lproj" / "Localizable.strings").write_text("".join(r[2] for r in rows))
print("hand-translated entries:", fixed)
