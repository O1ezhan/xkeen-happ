#!/bin/sh
# ==============================================================================
# deploy-unix.sh — установка XKeen Happ с компьютера (macOS / Linux) по SSH.
# Роутер сам скачивает установщик с GitHub, файлы с компьютера не копируются.
#   sh deploy-unix.sh
# ==============================================================================

set -e
URL="https://github.com/@REPO@/releases/latest/download/install.sh"

printf '\033[1;32mXKeen Happ — установка на роутер\033[0m\n'
printf "IP роутера [192.168.1.1]: "
read -r ROUTER_IP
[ -z "$ROUTER_IP" ] && ROUTER_IP=192.168.1.1
printf "Ссылка на подписку (Enter — вставить позже в панели): "
read -r SUB_URL

# SSH Entware: 222, если в прошивке включён свой SSH-сервер, иначе 22
PORT=222
if command -v nc >/dev/null 2>&1 && ! nc -z -w 3 "$ROUTER_IP" 222 2>/dev/null; then
    PORT=22
fi
echo "SSH на порту $PORT. Пароль root по умолчанию: keenetic"

# Ссылка передаётся через stdin, а не в командной строке: в ней бывают &, ? и кавычки
printf '%s\n' "$SUB_URL" | ssh -p "$PORT" -o StrictHostKeyChecking=accept-new "root@$ROUTER_IP" \
    "read -r u; curl -fsSL '$URL' -o /opt/tmp/install.sh && if [ -n \"\$u\" ]; then sh /opt/tmp/install.sh --sub \"\$u\"; else sh /opt/tmp/install.sh; fi"

echo "Панель: http://$ROUTER_IP:8099 — при первом входе задайте пароль."
if command -v open >/dev/null 2>&1; then open "http://$ROUTER_IP:8099" || true
elif command -v xdg-open >/dev/null 2>&1; then xdg-open "http://$ROUTER_IP:8099" || true
fi
