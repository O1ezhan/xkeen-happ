#!/bin/sh
# ==============================================================================
# api.cgi — JSON API веб-панели XKeen Happ UI (lighttpd / BusyBox httpd, CGI)
#
# Защита:
#   - вход по паролю (задаётся при первом открытии панели), сессия в cookie
#     HttpOnly + SameSite=Strict;
#   - POST принимаются только с заголовком X-Requested-With: xkeen-happ
#     (чужой сайт не может его поставить без CORS, а CORS не разрешён);
#   - Host должен быть IP-адресом или известным именем роутера — защита
#     от DNS rebinding, пока пароль ещё не задан.
# ==============================================================================

export PATH="/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin"

OPT_DIR="${XKEEN_OPT_DIR:-/opt}"
HAPP_CONF_DIR="${XKEEN_HAPP_CONF_DIR:-$OPT_DIR/etc/xkeen-happ}"
XRAY_CONF_DIR="${XKEEN_XRAY_CONF_DIR:-$OPT_DIR/etc/xray/configs}"
LOG_DIR="${XKEEN_LOG_DIR:-$OPT_DIR/var/log}"
RUN_DIR="${XKEEN_RUN_DIR:-$OPT_DIR/var/run/xkeen-happ}"
HAPP_LOG="$LOG_DIR/xkeen-happ.log"

CONFIG_FILE="$HAPP_CONF_DIR/config.json"
STATE_FILE="$HAPP_CONF_DIR/state.json"
AUTH_FILE="$HAPP_CONF_DIR/auth.json"
SESS_DIR="$RUN_DIR/sessions"
OUTBOUNDS_FILE="$XRAY_CONF_DIR/04_outbounds.json"
ROUTING_FILE="$XRAY_CONF_DIR/05_routing.json"
XKEEN_SUB="${XKEEN_SUB_BIN:-$OPT_DIR/bin/xkeen-sub}"
CTL="${XKEEN_CTL_BIN:-$OPT_DIR/bin/xkeen-happ-ctl}"
SESSION_DAYS=7
SETUP_WINDOW_HOURS=24

mkdir -p "$SESS_DIR" 2>/dev/null
chmod 700 "$RUN_DIR" "$SESS_DIR" 2>/dev/null

extra_headers=""

send() {
    # send <http-статус> <json>
    printf 'Status: %s\r\n' "$1"
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Cache-Control: no-store\r\n'
    printf 'X-Content-Type-Options: nosniff\r\n'
    [ -n "$extra_headers" ] && printf '%s\r\n' "$extra_headers"
    printf '\r\n%s\n' "$2"
    exit 0
}

fail() {
    # fail <http-статус> <сообщение>
    send "$1" "$(jq -n --arg m "$2" '{ok: false, message: $m}')"
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum; else busybox sha256sum; fi | cut -d' ' -f1
}

# Случайная hex-строка длиной 2*$1 символов (od в прошивке может не быть, sha256sum есть)
rand_hex() {
    head -c 64 /dev/urandom | sha256 | cut -c1-$(($1 * 2))
}

# --- Проверка Host (DNS rebinding) ------------------------------------------
host="${HTTP_HOST%:*}"
case "$HTTP_HOST" in \[*) host="${HTTP_HOST%%]*}]" ;; esac
host_ok="false"
if printf '%s' "$host" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^\[[0-9a-fA-F:.]+\]$|^localhost$|^my\.keenetic\.net$|^[A-Za-z0-9-]+\.local$'; then
    host_ok="true"
elif [ -f "$CONFIG_FILE" ] && jq -e --arg h "$host" '(.allowed_hosts // []) | index($h)' "$CONFIG_FILE" >/dev/null 2>&1; then
    host_ok="true"
fi
[ "$host_ok" = "true" ] || fail "403 Forbidden" "Откройте панель по IP-адресу роутера, например http://192.168.1.1:8099"

# --- Разбор запроса -----------------------------------------------------------
action=$(printf '%s' "${QUERY_STRING:-}" | sed -n 's/^\(.*&\)\{0,1\}action=\([a-z-]*\).*/\2/p')
[ -z "$action" ] && action="status"

method="${REQUEST_METHOD:-GET}"
body=""
if [ "$method" = "POST" ]; then
    [ "${HTTP_X_REQUESTED_WITH:-}" = "xkeen-happ" ] || fail "403 Forbidden" "Запрос отклонён (нет заголовка X-Requested-With)"
    len="${CONTENT_LENGTH:-0}"
    case "$len" in ''|*[!0-9]*) len=0 ;; esac
    [ "$len" -le 262144 ] || fail "413 Payload Too Large" "Слишком большой запрос"
    [ "$len" -gt 0 ] && body=$(head -c "$len")
    printf '%s' "$body" | jq -e 'type == "object"' >/dev/null 2>&1 || body="{}"
fi

field() { printf '%s' "$body" | jq -r --arg k "$1" '.[$k] // "" | tostring'; }

# --- Сессии -------------------------------------------------------------------
cookie_token=$(printf '%s' "${HTTP_COOKIE:-}" | tr ';' '\n' | sed -n 's/^[[:space:]]*xh_session=\([0-9a-f]\{64\}\)[[:space:]]*$/\1/p' | head -n 1)

auth_configured() { [ -s "$AUTH_FILE" ] && jq -e '.hash and .salt' "$AUTH_FILE" >/dev/null 2>&1; }

session_valid() {
    [ -n "$cookie_token" ] && [ -f "$SESS_DIR/$cookie_token" ] || return 1
    # просроченные сессии удаляем
    find "$SESS_DIR" -type f -mtime +"$SESSION_DAYS" -exec rm -f {} \; 2>/dev/null
    [ -f "$SESS_DIR/$cookie_token" ]
}

new_session() {
    tok=$(rand_hex 32)
    : > "$SESS_DIR/$tok"
    extra_headers="Set-Cookie: xh_session=$tok; Path=/; HttpOnly; SameSite=Strict; Max-Age=$((SESSION_DAYS * 86400))"
}

check_password() {
    salt=$(jq -r '.salt' "$AUTH_FILE")
    want=$(jq -r '.hash' "$AUTH_FILE")
    got=$(printf '%s%s' "$salt" "$1" | sha256)
    [ "$got" = "$want" ]
}

store_password() {
    salt=$(rand_hex 16)
    hash=$(printf '%s%s' "$salt" "$1" | sha256)
    umask 077
    jq -n --arg s "$salt" --arg h "$hash" '{salt: $s, hash: $h}' > "$AUTH_FILE.tmp" && mv "$AUTH_FILE.tmp" "$AUTH_FILE"
}

# --- Ответ со статусом панели ---------------------------------------------------
emit_status() {
    msg="${1:-}"
    ok="${2:-true}"
    base_json=$("$XKEEN_SUB" status 2>/dev/null)
    printf '%s' "$base_json" | jq -e . >/dev/null 2>&1 || base_json='{}'
    ob_str=""; rt_str=""; logs_str=""
    [ -f "$OUTBOUNDS_FILE" ] && ob_str=$(cat "$OUTBOUNDS_FILE" 2>/dev/null)
    [ -f "$ROUTING_FILE" ] && rt_str=$(cat "$ROUTING_FILE" 2>/dev/null)
    [ -f "$HAPP_LOG" ] && logs_str=$(tail -n 30 "$HAPP_LOG" 2>/dev/null)
    code="200 OK"
    [ "$ok" = "true" ] || code="422 Unprocessable Entity"
    send "$code" "$(printf '%s' "$base_json" | jq -c \
        --arg ok "$ok" --arg msg "$msg" --arg ob "$ob_str" --arg rt "$rt_str" --arg lg "$logs_str" \
        '. + {ok: ($ok == "true"), message: $msg, outbounds_preview: $ob, routing_preview: $rt, logs: $lg}')"
}

last_error() {
    jq -r '.last_error // empty' "$STATE_FILE" 2>/dev/null
}

# --- Действия без входа ----------------------------------------------------------
case "$action" in
    auth-state)
        configured="false"; authed="false"
        auth_configured && configured="true"
        session_valid && authed="true"
        send "200 OK" "{\"ok\":true,\"configured\":$configured,\"authed\":$authed}"
        ;;
    setup)
        [ "$method" = "POST" ] || fail "405 Method Not Allowed" "Нужен POST"
        auth_configured && fail "409 Conflict" "Пароль уже задан"
        # Первый пароль можно задать только в течение суток после установки (или после
        # «touch /opt/etc/xkeen-happ/allow-setup» по SSH) — иначе его мог бы занять любой в сети
        mark="$HAPP_CONF_DIR/allow-setup"
        [ -f "$mark" ] || mark="$HAPP_CONF_DIR/.installed"
        if [ ! -f "$mark" ] || [ -n "$(find "$mark" -mmin +$((SETUP_WINDOW_HOURS * 60)) 2>/dev/null)" ]; then
            fail "403 Forbidden" "Срок первичной настройки истёк. По SSH выполните: touch /opt/etc/xkeen-happ/allow-setup — и обновите страницу"
        fi
        pw=$(field password)
        [ "${#pw}" -ge 8 ] || fail "422 Unprocessable Entity" "Пароль должен быть не короче 8 символов"
        store_password "$pw"
        rm -f "$HAPP_CONF_DIR/allow-setup"
        new_session
        send "200 OK" '{"ok":true,"message":"Пароль задан"}'
        ;;
    login)
        [ "$method" = "POST" ] || fail "405 Method Not Allowed" "Нужен POST"
        auth_configured || fail "409 Conflict" "Сначала задайте пароль"
        if check_password "$(field password)"; then
            new_session
            send "200 OK" '{"ok":true}'
        fi
        sleep 2
        fail "401 Unauthorized" "Неверный пароль"
        ;;
esac

# --- Всё остальное — только после входа ---------------------------------------------
auth_configured || fail "401 Unauthorized" "Задайте пароль панели"
session_valid || fail "401 Unauthorized" "Нужно войти"
touch "$SESS_DIR/$cookie_token"

if [ "$method" != "POST" ] && [ "$action" != "status" ]; then
    fail "405 Method Not Allowed" "Нужен POST"
fi

case "$action" in
    status)
        emit_status "" "true"
        ;;

    logout)
        rm -f "$SESS_DIR/$cookie_token"
        extra_headers="Set-Cookie: xh_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"
        send "200 OK" '{"ok":true}'
        ;;

    change-password)
        check_password "$(field old_password)" || { sleep 2; fail "401 Unauthorized" "Текущий пароль неверен"; }
        pw=$(field new_password)
        [ "${#pw}" -ge 8 ] || fail "422 Unprocessable Entity" "Пароль должен быть не короче 8 символов"
        store_password "$pw"
        # все прочие сессии завершаются
        find "$SESS_DIR" -type f ! -name "$cookie_token" -exec rm -f {} \; 2>/dev/null
        send "200 OK" '{"ok":true,"message":"Пароль изменён"}'
        ;;

    save)
        err=$(printf '%s' "$body" | "$XKEEN_SUB" save-config 2>&1 >/dev/null)
        rc=$?
        # Только настройки уведомлений — Xray перезапускать незачем
        if [ "$rc" = 1 ] && printf '%s' "$body" | jq -e 'keys - ["tg_token", "tg_chat", "notify"] | length == 0' >/dev/null 2>&1; then
            emit_status "Сохранено" "true"
        fi
        case "$rc" in
            0)
                if "$XKEEN_SUB" update >/dev/null 2>&1; then
                    emit_status "Подписка обновлена и настройки применены" "true"
                else
                    emit_status "$(last_error)" "false"
                fi
                ;;
            1)
                "$XKEEN_SUB" apply >/dev/null 2>&1
                emit_status "Настройки маршрутизации сохранены и применены" "true"
                ;;
            *)
                emit_status "${err:-Ошибка в настройках}" "false"
                ;;
        esac
        ;;

    update)
        if "$XKEEN_SUB" update >/dev/null 2>&1; then
            emit_status "Подписка обновлена" "true"
        else
            emit_status "$(last_error)" "false"
        fi
        ;;

    select)
        sel=$(printf '%s' "$body" | jq -c '{selection_mode: (.selection_mode // "manual"), selected_tag: (.selected_tag // "proxy-1")}')
        err=$(printf '%s' "$sel" | "$XKEEN_SUB" save-config 2>&1 >/dev/null)
        if [ $? -le 1 ]; then
            "$XKEEN_SUB" apply >/dev/null 2>&1
            emit_status "Активный сервер переключён" "true"
        else
            emit_status "${err:-Ошибка выбора сервера}" "false"
        fi
        ;;

    ping)
        "$XKEEN_SUB" ping >/dev/null 2>&1
        emit_status "Пинг серверов обновлён" "true"
        ;;

    rci)
        if [ -x "$OPT_DIR/bin/xkeen-rci-setup" ] && "$OPT_DIR/bin/xkeen-rci-setup" setup >/dev/null 2>&1; then
            emit_status "Политика XKeen проверена и настроена" "true"
        else
            emit_status "Не удалось настроить роутер через RCI — см. журнал установки" "false"
        fi
        ;;

    service)
        cmd=$(field command)
        case "$cmd" in start|stop|restart) ;; *) fail "422 Unprocessable Entity" "Неизвестная команда" ;; esac
        [ -x "$OPT_DIR/sbin/xkeen" ] || fail "503 Service Unavailable" "XKeen не установлен"
        # остановка из панели — сторож не должен сразу поднимать Xray обратно
        if [ "$cmd" = "stop" ]; then touch "$HAPP_CONF_DIR/.paused"; else rm -f "$HAPP_CONF_DIR/.paused"; fi
        "$OPT_DIR/sbin/xkeen" "-$cmd" >/dev/null 2>&1 &
        emit_status "Команда xkeen -$cmd отправлена" "true"
        ;;

    health)
        if "$CTL" health >/dev/null 2>&1; then
            send "200 OK" '{"ok":true,"vpn":"ok"}'
        fi
        send "200 OK" '{"ok":true,"vpn":"fail"}'
        ;;

    devices)
        out=$("$OPT_DIR/bin/xkeen-rci-setup" devices 2>/dev/null)
        printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || fail "503 Service Unavailable" "Не удалось получить список устройств от роутера"
        send "200 OK" "$(jq -nc --argjson d "$out" '{ok: true, devices: $d}')"
        ;;

    device-set)
        mac=$(field mac); mode=$(field mode)
        if err=$("$OPT_DIR/bin/xkeen-rci-setup" device-set "$mac" "$mode" 2>&1 >/dev/null); then
            send "200 OK" '{"ok":true,"message":"Сохранено"}'
        fi
        fail "422 Unprocessable Entity" "$(printf '%s' "$err" | sed 's/\x1b\[[0-9;]*m//g; s/^ *\[.\] //' | tail -n 1)"
        ;;

    notify-test)
        err=$("$CTL" notify-test 2>&1) && send "200 OK" '{"ok":true,"message":"Сообщение отправлено — проверьте Telegram"}'
        fail "422 Unprocessable Entity" "${err:-Не удалось отправить}"
        ;;

    find-chat)
        if chat=$("$CTL" find-chat 2>/tmp/xh-findchat.err); then
            printf '%s' "{\"tg_chat\":\"$chat\"}" | "$XKEEN_SUB" save-config >/dev/null 2>&1
            send "200 OK" "$(jq -nc --arg c "$chat" '{ok: true, tg_chat: $c, message: "Чат найден"}')"
        fi
        fail "422 Unprocessable Entity" "$(cat /tmp/xh-findchat.err 2>/dev/null)"
        ;;

    versions)
        send "200 OK" "$("$CTL" versions | jq -c '. + {ok: true}')"
        ;;

    analytics)
        days=$(printf '%s' "${QUERY_STRING:-}" | sed -n 's/^\(.*&\)\{0,1\}days=\([0-9]*\).*/\2/p')
        case "$days" in 1|7|30) ;; *) days=1 ;; esac
        out=$("$CTL" analytics "$days" 2>/dev/null)
        printf '%s' "$out" | jq -e 'type == "object"' >/dev/null 2>&1 || fail "503 Service Unavailable" "Не удалось прочитать данные аналитики"
        send "200 OK" "$(printf '%s' "$out" | jq -c '. + {ok: true}')"
        ;;

    killswitch)
        st=$(field state)
        err=$("$CTL" killswitch "$st" 2>&1) && send "200 OK" "$(jq -nc --arg s "$st" '{ok: true, message: ("Kill switch: " + (if $s == "on" then "включён" else "выключен" end))}')"
        fail "422 Unprocessable Entity" "${err:-Не удалось}"
        ;;

    task)
        err=$("$CTL" task "$(field name)" 2>&1) && send "200 OK" '{"ok":true,"message":"Запущено"}'
        fail "409 Conflict" "${err:-Не удалось запустить}"
        ;;

    task-status)
        send "200 OK" "$("$CTL" task-status | jq -c '. + {ok: true}')"
        ;;

    rollback)
        if err=$("$CTL" rollback 2>&1); then
            emit_status "Возвращён последний рабочий конфиг" "true"
        fi
        emit_status "${err:-Откат не удался}" "false"
        ;;

    export)
        send "200 OK" "$("$CTL" export)"
        ;;

    import)
        if err=$(printf '%s' "$body" | "$CTL" import 2>&1); then
            "$XKEEN_SUB" update >/dev/null 2>&1
            emit_status "Настройки импортированы" "true"
        fi
        emit_status "${err:-Не удалось импортировать}" "false"
        ;;

    doctor)
        out=$("$OPT_DIR/bin/xkeen-happ-doctor" --json 2>/dev/null)
        printf '%s' "$out" | jq -e . >/dev/null 2>&1 || fail "500 Internal Server Error" "Диагностика не запустилась"
        send "200 OK" "$(printf '%s' "$out" | jq -c '. + {ok: true}')"
        ;;

    *)
        fail "404 Not Found" "Неизвестное действие: $action"
        ;;
esac
