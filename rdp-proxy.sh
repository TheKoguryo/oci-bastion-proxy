#!/usr/bin/env bash
# Forward a local RDP port through the SOCKS5 proxy started by oci-bastion-proxy.sh.
set -euo pipefail

usage() {
    printf 'Usage: bash rdp-proxy.sh TARGET_IP LOCAL_PORT\n'
    printf 'Example: bash rdp-proxy.sh 10.0.1.100 13389\n'
}
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    usage
    exit 0
fi
if (($# != 2)); then
    usage >&2
    exit 1
fi

target_ip=$1
local_port=$2
[[ $target_ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] ||
    die 'Target must be an IPv4 address.'
IFS=. read -r a b c d <<< "$target_ip"
for octet in "$a" "$b" "$c" "$d"; do
    ((10#$octet <= 255)) || die 'Invalid IPv4 address.'
done
printf -v target_ip '%d.%d.%d.%d' "$((10#$a))" "$((10#$b))" "$((10#$c))" "$((10#$d))"
[[ $local_port =~ ^[0-9]{1,5}$ ]] || die 'Local port must be between 1 and 65535.'
local_port=$((10#$local_port))
((local_port >= 1 && local_port <= 65535)) || die 'Local port must be between 1 and 65535.'
((local_port != 1080)) || die 'Port 1080 is reserved for the SOCKS5 proxy. Choose another local port.'
command -v ncat >/dev/null 2>&1 || die 'Ncat is required. On macOS, install it with: brew install nmap'

printf 'RDP: 127.0.0.1:%s -> SOCKS5 127.0.0.1:1080 -> %s:3389\n' "$local_port" "$target_ip"
printf 'Keep the Bastion proxy running. Connect Windows App to 127.0.0.1:%s.\n' "$local_port"
printf 'Press Ctrl+C to stop this relay.\n'
exec ncat -l 127.0.0.1 "$local_port" --keep-open \
    --sh-exec "ncat --proxy 127.0.0.1:1080 --proxy-type socks5 $target_ip 3389"
