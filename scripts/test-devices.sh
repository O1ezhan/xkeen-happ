#!/bin/sh
# ==============================================================================
# test-devices.sh — автотесты вкладки «Устройства» (xkeen-rci-setup devices).
# Данные RCI подставляются через окружение (XKEEN_TEST_*), роутер не нужен.
# Запуск: sh scripts/test-devices.sh   (нужны: sh, jq)
# ==============================================================================

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RCI="$ROOT/opt/bin/xkeen-rci-setup"
FAIL=0; TOTAL=0
ok()  { TOTAL=$((TOTAL + 1)); printf '  ok   %s\n' "$1"; }
bad() { TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %s\n        %s\n' "$1" "$2"; }

run_devices() { sh "$RCI" devices 2>/dev/null; }

echo "== Устройства: автотесты =="

# 1) show/ip/hotspot с обёрткой host, у устройств пустые name/hostname — раньше
#    sort_by(.name|ascii_downcase) падал на null и вкладка оставалась пустой.
HS='{"host":[{"mac":"7a:ca:d6:81:a4:b1","ip":"192.168.1.138","hostname":"","name":"","policy":"Policy0","active":true},{"mac":"70:89:76:dc:22:6c","ip":"192.168.1.141","hostname":"tuya","name":"","policy":"","active":false}]}'
CONF='[{"mac":"28:3a:4d:b7:f5:47","access":"permit"},{"mac":"7a:ca:d6:81:a4:b1","access":"permit"}]'
ARP='[{"ip":"192.168.1.141","mac":"70:89:76:dc:22:6c","name":"tuya","state":"REACHABLE"}]'
out=$(XKEEN_TEST_HS="$HS" XKEEN_TEST_CONF="$CONF" XKEEN_TEST_ARP="$ARP" \
      XKEEN_TEST_XK=Policy0 XKEEN_TEST_DR=Policy1 XKEEN_TEST_SEG=Policy0 run_devices)
[ "$(printf '%s' "$out" | jq 'length' 2>/dev/null)" = "2" ] && ok "обёртка host: 2 устройства" || bad "обёртка host: 2 устройства" "got: $out"
[ "$(printf '%s' "$out" | jq -r '.[0].name' 2>/dev/null)" = "7a:ca:d6:81:a4:b1" ] && ok "пустое имя заменяется MAC" || bad "пустое имя заменяется MAC" "got: $out"
[ "$(printf '%s' "$out" | jq -r '.[] | select(.name=="tuya") | .ip' 2>/dev/null)" = "192.168.1.141" ] && ok "hostname используется как имя" || bad "hostname используется как имя" "got: $out"
[ "$(printf '%s' "$out" | jq -r '.[0].mode' 2>/dev/null)" = "vpn" ] && ok "политика сегмента → vpn" || bad "политика сегмента → vpn" "got: $out"

# 2) конфиг ip/hotspot/host объектом (по MAC) — нормализуется, имя берётся из name
HS2='[{"mac":"aa:bb:cc:dd:ee:ff","ip":"192.168.1.7","name":"Телефон - Home network - 2026","active":true}]'
CONF2='{"aa:bb:cc:dd:ee:ff":{"access":"permit","policy":"Policy1"}}'
out2=$(XKEEN_TEST_HS="$HS2" XKEEN_TEST_CONF="$CONF2" XKEEN_TEST_ARP='[]' \
       XKEEN_TEST_XK=Policy0 XKEEN_TEST_DR=Policy1 XKEEN_TEST_SEG=Policy0 run_devices)
[ "$(printf '%s' "$out2" | jq -r '.[0].name' 2>/dev/null)" = "Телефон" ] && ok "имя из name до « - »" || bad "имя из name до « - »" "got: $out2"
[ "$(printf '%s' "$out2" | jq -r '.[0].mode' 2>/dev/null)" = "direct" ] && ok "политика Policy1 → direct" || bad "политика Policy1 → direct" "got: $out2"

# 3) всё пусто — пустой список без ошибки
out3=$(XKEEN_TEST_HS='{}' XKEEN_TEST_CONF='[]' XKEEN_TEST_ARP='[]' \
       XKEEN_TEST_XK=Policy0 XKEEN_TEST_DR=Policy1 XKEEN_TEST_SEG=Policy0 run_devices)
[ "$(printf '%s' "$out3" | jq 'length' 2>/dev/null)" = "0" ] && ok "пустые данные → []" || bad "пустые данные → []" "got: $out3"

echo
echo "Итог: $((TOTAL - FAIL))/$TOTAL тестов пройдено."
[ "$FAIL" -eq 0 ] || exit 1
