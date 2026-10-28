#!/usr/bin/env python3
"""Локальное зеркало Entware для флешки: только нужные пакеты и их зависимости.

    entware-feed.py https://bin.entware.net/aarch64-k3.10 OUT_DIR pkg1 pkg2 ...

OUT_DIR повторяет структуру репозитория: Packages.gz и .ipk в корне, пакеты Keenetic
в keenetic/. Индексы берутся целиком (opkg выбирает пакеты так же, как из сети),
а скачиваются только пакеты из замыкания зависимостей. SHA256 каждого .ipk сверяется
с индексом.
"""
import gzip
import hashlib
import os
import re
import sys
import time
import urllib.request

FEEDS = ("", "keenetic")


def fetch(url, tries=4):
    for i in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                return r.read()
        except OSError:
            if i == tries - 1:
                raise
            time.sleep(5)


def parse(index):
    pkgs = []
    for block in index.decode("utf-8", "replace").split("\n\n"):
        fields, key = {}, None
        for line in block.splitlines():
            if line.startswith(" ") and key:
                continue
            if ":" in line:
                key, val = line.split(":", 1)
                fields[key] = val.strip()
        if "Package" in fields:
            pkgs.append(fields)
    return pkgs


def names(dep_field):
    """'libc, libcurl (>= 8), a | b' -> [['libc'], ['libcurl'], ['a', 'b']]"""
    out = []
    for part in filter(None, (p.strip() for p in dep_field.split(","))):
        out.append([re.sub(r"\s*\(.*\)", "", alt).strip() for alt in part.split("|")])
    return out


def main():
    base, out, wanted = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3:]
    by_name, providers = {}, {}
    for feed in FEEDS:
        sub = f"{base}/{feed}" if feed else base
        raw = fetch(f"{sub}/Packages.gz")
        os.makedirs(os.path.join(out, feed), exist_ok=True)
        with open(os.path.join(out, feed, "Packages.gz"), "wb") as f:
            f.write(raw)
        for p in parse(gzip.decompress(raw)):
            p["_feed"], p["_url"] = feed, f"{sub}/{p['Filename']}"
            by_name.setdefault(p["Package"], []).append(p)
            for prov in names(p.get("Provides", "")):
                providers.setdefault(prov[0], []).append(p["Package"])

    chosen, queue = {}, list(wanted)
    while queue:
        name = queue.pop()
        if name in chosen:
            continue
        if name not in by_name:
            alt = providers.get(name)
            if not alt:
                sys.exit(f"entware-feed: пакет {name} не найден")
            queue.append(alt[0])
            chosen[name] = []
            continue
        # Пакет может быть в обоих каталогах (например, iptables) — берём оба, opkg выберет сам
        chosen[name] = by_name[name]
        for p in by_name[name]:
            for group in names(p.get("Depends", "")) + names(p.get("Pre-Depends", "")):
                ok = [n for n in group if n in by_name or n in providers]
                if not ok:
                    sys.exit(f"entware-feed: зависимость {group} пакета {name} не найдена")
                queue.append(ok[0])

    total = 0
    for name in sorted(chosen):
        for p in chosen[name]:
            dest = os.path.join(out, p["_feed"], p["Filename"])
            data = fetch(p["_url"])
            if hashlib.sha256(data).hexdigest() != p.get("SHA256sum"):
                sys.exit(f"entware-feed: не совпала SHA256 у {p['Filename']}")
            with open(dest, "wb") as f:
                f.write(data)
            total += len(data)
    print(f"  {len([n for n in chosen if chosen[n]])} пакетов, {total // 1024} КБ")


if __name__ == "__main__":
    main()
