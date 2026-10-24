#!/bin/bash
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
cp "$ROOT/Tests/main.swift" "$TMP/main.swift"
swiftc -o "$TMP/fignyagram-tests" \
  "$ROOT/Telegram/UI/Models/Fignyagram/Proxy/ProxyCrypto.swift" \
  "$ROOT/Telegram/UI/Models/Fignyagram/SearchHistory.swift" \
  "$ROOT/Telegram/UI/Models/Fignyagram/DevicePerformance.swift" \
  "$ROOT/Telegram/UI/Models/Fignyagram/LocalAliases.swift" \
  "$ROOT/Telegram/UI/Models/Fignyagram/DraftStore.swift" \
  "$ROOT/Telegram/UI/Models/Fignyagram/ChatVisitHistory.swift" \
  "$ROOT/Telegram/UI/Models/Fignyagram/AdaptiveDebouncer.swift" \
  "$TMP/main.swift"
"$TMP/fignyagram-tests"
