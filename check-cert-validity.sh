#!/usr/bin/env bash
# Report the validity period of a TLS server certificate and flag anything
# Apple's TLS stack will reject (limit: 398 days).
#
#   ./check-cert-validity.sh example.com
#   ./check-cert-validity.sh example.com:8443
#   ./check-cert-validity.sh app.internal 10.0.0.5     # connect by IP, send SNI for the name

set -euo pipefail

APPLE_LIMIT_DAYS=398

usage() {
    echo "usage: $0 <host[:port]> [connect-ip]" >&2
    exit 2
}

[ $# -ge 1 ] || usage

target=$1
host=${target%%:*}
port=${target##*:}
[ "$port" = "$host" ] && port=443
connect=${2:-$host}

# s_client exits non-zero whenever chain verification fails — including the
# self-signed case this script exists to diagnose — so its exit code says
# nothing about whether we reached the server. Check for a certificate instead.
cert=$(openssl s_client -connect "${connect}:${port}" -servername "$host" </dev/null 2>/dev/null || true)

if ! printf '%s' "$cert" | grep -q "BEGIN CERTIFICATE"; then
    echo "$host:$port — cannot connect, or no certificate returned" >&2
    exit 1
fi

not_before=$(printf '%s' "$cert" | openssl x509 -noout -startdate 2>/dev/null | cut -d= -f2)
not_after=$(printf '%s' "$cert" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)

# BSD date (macOS) and GNU date parse differently; try both.
to_epoch() {
    date -j -f "%b %d %T %Y %Z" "$1" "+%s" 2>/dev/null \
        || date -d "$1" "+%s" 2>/dev/null
}

start_epoch=$(to_epoch "$not_before")
end_epoch=$(to_epoch "$not_after")

echo "$host:$port"

if [ -z "$start_epoch" ] || [ -z "$end_epoch" ]; then
    echo "  not before : $not_before"
    echo "  not after  : $not_after"
    echo "  could not parse dates on this platform" >&2
    exit 1
fi

days=$(( (end_epoch - start_epoch) / 86400 ))
remaining=$(( (end_epoch - $(date +%s)) / 86400 ))

echo "  not before : $not_before"
echo "  not after  : $not_after"
echo "  validity   : ${days} days"
echo "  remaining  : ${remaining} days"

if [ "$days" -gt "$APPLE_LIMIT_DAYS" ]; then
    echo "  FAIL — exceeds Apple's ${APPLE_LIMIT_DAYS}-day limit; Safari and iOS will reject this certificate"
    exit 1
fi

echo "  OK — within Apple's ${APPLE_LIMIT_DAYS}-day limit"
