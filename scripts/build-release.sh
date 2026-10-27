#!/bin/sh
# ==============================================================================
# build-release.sh — сборка релиза XKeen Happ в dist/:
#   dist/install-xkeen-sub.sh                 — установщик по SSH (все архитектуры)
#   dist/usb/<arch>/install/<arch>-installer.tar.gz
#                                             — флешка: Entware + XKeen Happ + автонастройка
#   dist/xkeen-happ-<версия>.zip              — всё вместе для публикации
#
#   sh scripts/build-release.sh [--sub "https://..."]  (подписка вшивается в архивы флешки)
# Требуется: sh, curl, tar (GNU), gzip, base64, jq, python3.
# ==============================================================================

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
# owner/name репозитория на GitHub: из Actions или из файла REPO
REPO="${GITHUB_REPOSITORY:-$(cat "$ROOT/REPO" 2>/dev/null)}"
[ -n "$REPO" ] || { echo "Укажите репозиторий в файле REPO (owner/name)" >&2; exit 1; }
DIST="$ROOT/dist"
SUB_URL=""
[ "${1:-}" = "--sub" ] && SUB_URL="${2:-}"

rm -rf "$DIST"
mkdir -p "$DIST"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Файлы проекта в том виде, в каком они лежат в /opt
OVERLAY="$WORK/overlay"
mkdir -p "$OVERLAY"
cp -R "$ROOT/opt/." "$OVERLAY/"
mkdir -p "$OVERLAY/etc/xkeen-happ"
cp "$ROOT/VERSION" "$OVERLAY/etc/xkeen-happ/VERSION"
find "$OVERLAY" -name '.DS_Store' -delete
chmod 755 "$OVERLAY/bin/"* "$OVERLAY/etc/init.d/"* "$OVERLAY/share/xkeen-happ/www/cgi-bin/api.cgi"
sed -i "s#@REPO@#$REPO#g" "$OVERLAY/bin/xkeen-happ-ctl"

# --- 1. Установщик по SSH ---------------------------------------------------------
echo "[1/3] install-xkeen-sub.sh"
payload="$WORK/payload.b64"
(cd "$OVERLAY" && tar --owner=0 --group=0 -cf - .) | gzip -9 | base64 > "$payload"
awk -v ver="$VERSION" -v repo="$REPO" -v pf="$payload" '
    /^@PAYLOAD@$/ { while ((getline l < pf) > 0) print l; next }
    { gsub(/@VERSION@/, ver); gsub(/@REPO@/, repo); print }
' "$ROOT/scripts/install.sh.in" > "$DIST/install.sh"
chmod 755 "$DIST/install.sh"
# старое имя — для тех, у кого уже есть ссылка
cp "$DIST/install.sh" "$DIST/install-xkeen-sub.sh"

# --- 2. Архивы для флешки ---------------------------------------------------------------
echo "[2/3] Архивы Entware для флешки"
build_usb() {
    arch="$1"; rel="$2"; name="$3"
    base="$WORK/$arch-base.tar.gz"
    root="$WORK/$arch-root"
    curl -fsSL --retry 3 -m 180 "https://bin.entware.net/$rel/installer/$name" -o "$base"
    mkdir -p "$root"
    tar -xzf "$base" -C "$root"
    [ -f "$root/bin/install" ] || { echo "в $name нет bin/install — формат установщика Entware изменился" >&2; exit 1; }

    cp -R "$OVERLAY/." "$root/"
    # После установки Entware сразу запускаем автонастройку, а не ждём перезагрузки
    awk '
        /^rm \/opt\/etc\/init.d\/doinstall/ && !done {
            print "logger -t installer \"XKeen Happ: запуск автонастройки (журнал /opt/var/log/xkeen-happ-bootstrap.log)\""
            print "/opt/etc/init.d/S98xkeen-happ-bootstrap start"
            done = 1
        }
        { print }
        END { if (!done) exit 1 }
    ' "$root/bin/install" > "$root/bin/install.new" || { echo "не нашли место для запуска автонастройки в bin/install" >&2; exit 1; }
    mv "$root/bin/install.new" "$root/bin/install"

    if [ -n "$SUB_URL" ]; then
        mkdir -p "$root/etc/xkeen-happ"
        jq -n --arg u "$SUB_URL" '{sub_url: $u}' > "$root/etc/xkeen-happ/preset.json"
    fi

    mkdir -p "$DIST/usb/$arch/install"
    (cd "$root" && tar --owner=0 --group=0 -czf "$DIST/usb/$arch/install/$name" .)
    # «Универсальная» флешка: все три архива в одной папке (прошивка берёт файл своей архитектуры)
    mkdir -p "$DIST/usb/all/install"
    cp "$DIST/usb/$arch/install/$name" "$DIST/usb/all/install/"
    echo "  $arch: dist/usb/$arch/install/$name"
}
build_usb aarch64 aarch64-k3.10 aarch64-installer.tar.gz
build_usb mipsel  mipselsf-k3.4 mipsel-installer.tar.gz
build_usb mips    mipssf-k3.4   mips-installer.tar.gz

# --- 3. Архив релиза --------------------------------------------------------------------
echo "[3/3] dist/xkeen-happ-$VERSION.zip"
pkg="$WORK/xkeen-happ-$VERSION"
mkdir -p "$pkg"
cp "$DIST/install.sh" "$ROOT/README.md" "$ROOT/LICENSE" "$ROOT/CHANGELOG.md" "$pkg/"
for f in deploy-unix.sh deploy-windows.bat; do
    sed "s#@REPO@#$REPO#g" "$ROOT/$f" > "$pkg/$f"
    cp "$pkg/$f" "$DIST/$f"
done
cp -R "$DIST/usb" "$pkg/usb"
(cd "$WORK" && python3 -c 'import shutil, sys; shutil.make_archive(sys.argv[1], "zip", ".", sys.argv[2])' \
    "$DIST/xkeen-happ-$VERSION" "xkeen-happ-$VERSION")
# отдельные архивы флешки — чтобы их можно было скачать по прямой ссылке из релиза
for a in aarch64 mipsel mips; do cp "$DIST/usb/$a/install/$a-installer.tar.gz" "$DIST/"; done
(cd "$DIST" && sha256sum install.sh "xkeen-happ-$VERSION.zip" ./*-installer.tar.gz > SHA256SUMS)
# Текст релиза: раздел текущей версии из CHANGELOG.md
awk -v v="$VERSION" '/^## / { on = index($0, "## " v) == 1; next } on' "$ROOT/CHANGELOG.md" > "$DIST/RELEASE_NOTES.md"
echo "Готово: $DIST"
