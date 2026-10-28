#!/usr/bin/env python3
"""Audit + auto-wrap user-facing Russian literals in SwiftUI views.

Usage:
  python3 Tools/localize_audit.py            # report remaining literals
  python3 Tools/localize_audit.py --apply    # wrap known literals in L10n.t
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SWIFT = list(ROOT.glob("Telegram/**/*.swift"))

# High-frequency UI strings that are safe to wrap (never used as identifiers).
MAP = {
    "Закрыть": "Common.Close", "Отмена": "Common.Cancel", "Сохранить": "Common.Save",
    "Готово": "Common.Done", "Удалить": "Common.Delete", "Добавить": "Common.Add",
    "Открыть": "Common.Open", "Чат": "Common.Chat", "Сообщение": "Common.Message",
    "Настройки": "Common.Settings", "Профиль": "Common.Profile", "Прокси": "Common.Proxy",
    "Уведомления": "Common.Notifications", "Отправить": "Common.Send",
    "Открепить": "Common.Unpin", "Закрепить": "Common.Pin",
}
CALLS = r'(Text|Label|Button|Section|Toggle|Picker|navigationTitle|alert|confirmationDialog|TextField)'
pattern = re.compile(CALLS + r'\(\s*"([^"\\]+)"')

def audit(deep=False):
    count = 0
    for path in SWIFT:
        text = path.read_text()
        for m in pattern.finditer(text):
            value = m.group(2)
            if re.search(r'[А-Яа-яЁё]', value):
                count += 1
                if deep:
                    line = text[:m.start()].count("\n") + 1
                    print(f"{path.relative_to(ROOT)}:{line}: {m.group(0)}")
    print(f"remaining user-facing Russian literals: {count}")

def apply():
    changed = 0
    for path in SWIFT:
        text = path.read_text()
        def repl(m):
            nonlocal changed
            call, value = m.group(1), m.group(2)
            key = MAP.get(value)
            if key is None and re.search(r'[А-Яа-яЁё]', value):
                return m.group(0)  # unknown strings stay for manual review
            if key is None:
                return m.group(0)
            changed += 1
            return f'{call}(L10n.t("{key}")'
        new = pattern.sub(repl, text)
        if new != text:
            path.write_text(new)
    print(f"wrapped {changed} literals")

if __name__ == "__main__":
    apply() if "--apply" in sys.argv else audit(deep="--deep" in sys.argv)
