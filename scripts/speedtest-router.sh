#!/bin/sh
# Замер скорости: напрямую и через каждый outbound подписки (временный xray с socks на 127.0.0.1)
URL="https://speed.cloudflare.com/__down?bytes=40000000"
D=/opt/tmp/xh-speed; rm -rf $D; mkdir -p $D
dl() { curl -s -o /dev/null -m 25 -w '%{speed_download} %{time_starttransfer}' "$@" "$URL" | awk '{printf "%6.1f Мбит/с  (первый байт %.2f с)", $1*8/1000000, $2}'; }
echo "напрямую:            $(dl)"
n=$(jq '.outbounds | length' /opt/etc/xray/configs/04_outbounds.json)
i=0
while [ $i -lt $n ]; do
  tag=$(jq -r ".outbounds[$i].tag" /opt/etc/xray/configs/04_outbounds.json)
  case "$tag" in proxy-*) ;; *) i=$((i+1)); continue ;; esac
  jq "{log:{loglevel:\"warning\"}, inbounds:[{port:10808, listen:\"127.0.0.1\", protocol:\"socks\", settings:{udp:false}}], outbounds:[.outbounds[$i]]}" /opt/etc/xray/configs/04_outbounds.json > $D/c.json
  /opt/sbin/xray run -c $D/c.json > $D/x.log 2>&1 &
  pid=$!; sleep 2
  name=$(jq -r ".servers[] | select(.tag==\"$tag\") | .name" /opt/etc/xkeen-happ/state.json)
  echo "$tag $name: $(dl -x socks5h://127.0.0.1:10808)"
  kill $pid; wait $pid 2>/dev/null
  i=$((i+1))
done
rm -rf $D
