#!/bin/sh
# ==============================================================================
# test-profiles.sh — автотесты профилей подписок (xkeen-sub profile ...).
# Работают в отдельной временной папке, реальный /opt не трогают.
# Запуск: sh scripts/test-profiles.sh   (нужны: sh, jq)
# ==============================================================================

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUB="$ROOT/opt/bin/xkeen-sub"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export XKEEN_HAPP_CONF_DIR="$TMP"

FAIL=0; TOTAL=0
ok() { TOTAL=$((TOTAL + 1)); printf '  ok   %s\n' "$1"; }
bad() { TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

profiles() { sh "$SUB" profile list | jq -c '{a:.active_profile, n:(.profiles|length)}'; }
save() { printf '%s' "$1" | sh "$SUB" profile save >/dev/null; }

echo "== Профили подписок: автотесты =="

# пусто
[ "$(profiles)" = '{"a":"","n":0}' ] && ok "изначально пусто" || bad "изначально пусто: $(profiles)"

# сохранить два профиля с уникальными id
save '{"name":"Основной","sub_url":"https://sub.example.com/a","routing_mode":"except_ru"}'
save '{"name":"Запасной","manual_links":"vless://u@h:443#x","routing_mode":"full"}'
n=$(sh "$SUB" profile list | jq '.profiles | length')
[ "$n" = "2" ] && ok "два профиля сохранены" || bad "ожидали 2, получили $n"
ids=$(sh "$SUB" profile list | jq '[.profiles[].id] | unique | length')
[ "$ids" = "2" ] && ok "id уникальны" || bad "id не уникальны"

# применить первый профиль
id1=$(sh "$SUB" profile list | jq -r '.profiles[0].id')
sh "$SUB" profile apply "$id1" >/dev/null
[ "$(jq -r '.sub_url' "$TMP/config.json")" = "https://sub.example.com/a" ] && ok "apply: sub_url перенесён" || bad "apply: sub_url не тот"
[ "$(jq -r '.routing_mode' "$TMP/config.json")" = "except_ru" ] && ok "apply: routing_mode перенесён" || bad "apply: routing_mode не тот"
[ "$(jq -r '.active_profile' "$TMP/config.json")" = "$id1" ] && ok "apply: active_profile установлен" || bad "apply: active_profile не установлен"

# удалить второй профиль
id2=$(sh "$SUB" profile list | jq -r '.profiles[] | select(.id != "'$id1'") | .id')
sh "$SUB" profile del "$id2" >/dev/null
[ "$(sh "$SUB" profile list | jq '.profiles | length')" = "1" ] && ok "del: остался один профиль" || bad "del: не удалился"

# удалить активный — active_profile сбрасывается
sh "$SUB" profile del "$id1" >/dev/null
[ "$(sh "$SUB" profile list | jq -r '.active_profile')" = "" ] && ok "del активного: active_profile сброшен" || bad "del активного: active_profile не сброшен"

echo
echo "Итог: $((TOTAL - FAIL))/$TOTAL тестов пройдено."
[ "$FAIL" -eq 0 ] || exit 1
