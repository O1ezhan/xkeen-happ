#!/bin/sh
# ==============================================================================
# test-parser.sh — автотесты парсера подписок (xkeen-sub parse).
# Проверяют, что ссылки vless/vmess/trojan/ss/hysteria2 с разными транспортами
# и опциями разбираются в ожидаемый JSON (outbounds + servers).
#
# Запуск:  sh scripts/test-parser.sh
# Требует: sh (POSIX), awk (mawk/gawk/busybox), jq.
# Выход:   0 — все тесты прошли, 1 — есть провалы.
# ==============================================================================

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARSE_CMD='sh "$ROOT/opt/bin/xkeen-sub" parse'

FAIL=0
TOTAL=0

# run <описание> <входные-ссылки> <jq-фильтр> <ожидаемое-значение>
run() {
    desc="$1"; input="$2"; filter="$3"; expected="$4"
    TOTAL=$((TOTAL + 1))
    got=$(printf '%s\n' "$input" | eval "$PARSE_CMD" | jq -r "$filter" 2>/dev/null)
    if [ "$got" = "$expected" ]; then
        printf '  ok   %s\n' "$desc"
    else
        printf '  FAIL %s\n        got=%s\n        want=%s\n' "$desc" "$got" "$expected"
        FAIL=$((FAIL + 1))
    fi
}

echo "== Парсер подписок: автотесты =="

# --- vless + reality (tcp) ---
VLESS_REALITY='vless://a62f9d5d-cb21-42dd-99c1-6670c1227723@45.118.249.95:24443?encryption=none&security=reality&sni=www.microsoft.com&fp=safari&pbk=aKE_ydb7jwvrKhmkZ2ROHj6r1QDQPduCNkRtmXETWAk&sid=27&spx=%2F&flow=xtls-rprx-vision&type=tcp#FI2-Reality-MS'
run "vless reality: protocol"            "$VLESS_REALITY" '.outbounds[0].protocol' 'vless'
run "vless reality: network"             "$VLESS_REALITY" '.outbounds[0].streamSettings.network' 'tcp'
run "vless reality: security"            "$VLESS_REALITY" '.outbounds[0].streamSettings.security' 'reality'
run "vless reality: publicKey"           "$VLESS_REALITY" '.outbounds[0].streamSettings.realitySettings.publicKey' 'aKE_ydb7jwvrKhmkZ2ROHj6r1QDQPduCNkRtmXETWAk'
run "vless reality: shortId"             "$VLESS_REALITY" '.outbounds[0].streamSettings.realitySettings.shortId' '27'
run "vless reality: serverName"          "$VLESS_REALITY" '.outbounds[0].streamSettings.realitySettings.serverName' 'www.microsoft.com'
run "vless reality: fingerprint"         "$VLESS_REALITY" '.outbounds[0].streamSettings.realitySettings.fingerprint' 'safari'
run "vless reality: flow vision"         "$VLESS_REALITY" '.outbounds[0].settings.flow' 'xtls-rprx-vision'
run "vless reality: имя из фрагмента"    "$VLESS_REALITY" '.servers[0].name' 'FI2-Reality-MS'
run "vless reality: порт"                "$VLESS_REALITY" '.outbounds[0].settings.port' '24443'
run "vless reality: id"                  "$VLESS_REALITY" '.outbounds[0].settings.id' 'a62f9d5d-cb21-42dd-99c1-6670c1227723'

# --- vmess (base64-json) ---
VMESS='vmess://eyJ2IjoiMiIsInBzIjoiVGVzdCIsImFkZCI6ImV4YW1wbGUuY29tIiwicG9ydCI6NDQzLCJpZCI6InV1aWQtaGVyZSJ9'
run "vmess: protocol"  "$VMESS" '.outbounds[0].protocol' 'vmess'
run "vmess: address"   "$VMESS" '.outbounds[0].settings.address' 'example.com'
run "vmess: port"      "$VMESS" '.outbounds[0].settings.port' '443'
run "vmess: id"        "$VMESS" '.outbounds[0].settings.id' 'uuid-here'
run "vmess: имя"       "$VMESS" '.servers[0].name' 'Test'

# --- trojan + ws + tls ---
TROJAN='trojan://pass@example.com:443?security=tls&sni=example.com&type=ws&path=%2Fws#Trojan-WS'
run "trojan: protocol"          "$TROJAN" '.outbounds[0].protocol' 'trojan'
run "trojan: network ws"        "$TROJAN" '.outbounds[0].streamSettings.network' 'ws'
run "trojan: tls serverName"    "$TROJAN" '.outbounds[0].streamSettings.tlsSettings.serverName' 'example.com'
run "trojan: ws path"           "$TROJAN" '.outbounds[0].streamSettings.wsSettings.path' '/ws'

# --- shadowsocks ---
SS='ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpQQHNzdzByZA@example.com:8388#SS%20Test'
run "ss: protocol"      "$SS" '.outbounds[0].protocol' 'shadowsocks'
run "ss: protocol"      "$SS" '.outbounds[0].protocol' 'shadowsocks'
run "ss: security"      "$SS" '.servers[0].security' 'ss'
run "ss: метод шифрования" "$SS" '.outbounds[0].settings.method' 'chacha20-ietf-poly1305'
run "ss: имя с %20"     "$SS" '.servers[0].name' 'SS Test'

# --- hysteria2 ---
HY2='hy2://pass@example.com:8443?security=tls&sni=example.com#Hy2-Test'
run "hy2: protocol (xray)" "$HY2" '.outbounds[0].protocol' 'hysteria'
run "hy2: protocol" "$HY2" '.servers[0].protocol' 'hysteria2'
run "hy2: имя"      "$HY2" '.servers[0].name' 'Hy2-Test'

# --- xhttp (splithttp) ---
XHTTP='vless://uuid@example.com:443?type=splithttp&security=tls&sni=example.com&host=example.com&path=%2Fxhttp#XHTTP-Test'
run "xhttp: network" "$XHTTP" '.outbounds[0].streamSettings.network' 'xhttp'
run "xhttp: имя"     "$XHTTP" '.servers[0].name' 'XHTTP-Test'

# --- несколько ссылок, пустые строки и комментарии ---
MULTI=$(printf '%s\n' \
  '# комментарий пропускается' \
  '' \
  "$VLESS_REALITY" \
  '   ' \
  "$VMESS" \
  "$SS")
run "мульти: количество серверов" "$MULTI" '.servers | length' '3'
run "мульти: теги по порядку"     "$MULTI" '.outbounds | map(.tag) | join(",")' 'proxy-1,proxy-2,proxy-3'
run "мульти: протоколы"           "$MULTI" '.outbounds | map(.protocol) | join(",")' 'vless,vmess,shadowsocks'

echo
echo "Итог: $((TOTAL - FAIL))/$TOTAL тестов пройдено."
[ "$FAIL" -eq 0 ] || { echo "Провалов: $FAIL"; exit 1; }
