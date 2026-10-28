# Localization — обязательный чеклист для новых функций

Каждая новая настройка/кнопка/подпись ОБЯЗАНА быть переведена на все языки:
ru, en, es, de, zh.

1. В коде никаких сырых строк в UI:
   `Text(L10n.t("Settings.MyFeature"))`, `Label(L10n.t("Settings.MyFeature"), systemImage: ...)`
   Для форматирования — `String(format: L10n.t("Key"), value)`.
2. Добавить ключ в `ru.lproj/Localizable.strings` (русский текст).
3. Запустить автозаполнение остальных языков:
   `python3 Tools/fill_localizations.py`
4. Проверить полноту:
   `python3 Tools/localization_check.py` — должно быть `missing=0` во всех пяти языках.
5. Проверить, что не осталось литералов:
   `python3 Tools/localize_audit.py` — должно быть `0`.
6. Собрать Debug + Release и прогнать `./Tests/run_tests.sh`.
7. Проверить в iOS Настройки → Fignyagram → Язык: ru/en/es/de/zh.

Полезные инструменты: `localize_computed.py` (return/assignment), `localize_targeted.py`
(строки внутри row()/picker-ов), `translate_interpolations.py` (интерполяции).
Кэш переводов: `Tools/translations_cache.json`.
