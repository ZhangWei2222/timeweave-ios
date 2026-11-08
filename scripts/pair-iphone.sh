#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 3 ]]; then
  printf '用法：bash scripts/pair-iphone.sh <地域> <ECS 实例 ID> <HTTPS 服务地址>\n' >&2
  exit 2
fi

encoded_origin=$(jq -nr --arg address "$3" '$address | @uri')
qr_directory=$(mktemp -d "${TMPDIR:-/tmp}/timeweave-pairing-qr.XXXXXX")
qr_path="$qr_directory/TimeWeave-Pairing.png"

if ! workbench exec -r "$1" -i "$2" -u root --timeout 20 -o json -c 'set -e
token=$(cat /etc/selfweave/credentials/access_token)
test -n "$token"
printf "Authorization: Bearer %s\n" "$token" |
  curl --disable --noproxy "*" --silent --show-error --fail --max-time 8 --header @- -X POST \
    "http://127.0.0.1:8787/v1/device-pairings?origin='"$encoded_origin"'"' |
  jq -er 'select(.exit_code == 0) | .stdout | (try fromjson catch empty) | select(.schema_version == 1) | .qr_png_base64 | strings' 2>/dev/null |
  base64 -D -o "$qr_path" 2>/dev/null || ! test -s "$qr_path"; then
  printf '未生成配对二维码。请确认 Workbench 已连接且 ECS 上已启用设备配对。\n' >&2
  exit 1
fi

open -a Preview "$qr_path"
printf '请在五分钟内用 iPhone 的「远端 → 扫码配对」扫描二维码。\n'
