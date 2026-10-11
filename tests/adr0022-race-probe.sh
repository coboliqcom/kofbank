#!/usr/bin/env bash
# ADR-0022 race probe: identical workload against two builds (baseline vs fixed).
# N independently launched bank processes create DISTINCT requestIds simultaneously
# (flag-file barrier). Asserts durable outcomes from the stores, not exit codes.
set -u
HOME_DIR="$1"; BIN="$2"; N="${3:-12}"; ROUNDS="${4:-3}"
export BANK_HOME="$HOME_DIR" COB_LIBRARY_PATH="$HOME_DIR/build"
cd "$HOME_DIR" || exit 1
bank() { printf '%s\n' "$1" | timeout 60 "$BIN" 2>/dev/null | tr -d '\r'; }

for r in $(seq 1 "$ROUNDS"); do
  rm -rf var/data var/journal var/run; mkdir -p var/data var/journal var/run
  bank 'ledger.init' >/dev/null
  bank 'customer.create|J|HA|CNPJ|61010101000101|20261007|S|c1' >/dev/null
  bank 'customer.create|J|HB|CNPJ|61010101000290|20261007|S|c2' >/dev/null
  bank 'account.open|C00000000001|DMND|BRL|10000000|S|o1|OA1' >/dev/null
  bank 'account.open|C00000000002|DMND|BRL|0|S|o2|OA2' >/dev/null
  D=/tmp/kfprobe.$$; rm -rf "$D"; mkdir -p "$D"
  B="$D/go"
  for i in $(seq 1 "$N"); do
    ( while [ ! -f "$B" ]; do :; done
      printf 'txn.create|TRANSFER|A00000000001|A00000000002|500|BRL|m|S|p|PROBE-%s-%s\n' "$r" "$i" > "$D/$i"
      timeout 60 "$BIN" < "$D/$i" > "$D/$i.res" 2>&1 ) &
  done
  sleep 0.1; : > "$B"; wait
  acc=$(grep -h '^rc=00' "$D"/*.res 2>/dev/null | wc -l)
  r22=$(grep -h '^rc=22' "$D"/*.res 2>/dev/null | wc -l)
  ids=$(grep -h '^id=' "$D"/*.res 2>/dev/null)
  uids=$(printf '%s\n' "$ids" | grep . | sort -u | wc -l)
  dups=$(printf '%s\n' "$ids" | grep . | sort | uniq -d | wc -l)
  store=$(bank 'txn.list|' | grep -oE 'id=T[0-9]+' | wc -l)
  echo "round $r: accepted00=$acc rejected22=$r22 uniqueIds=$uids dupIds=$dups durableRecords=$store"
  rm -rf "$D"
done
