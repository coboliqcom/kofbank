#!/usr/bin/env bash
set -uo pipefail

COBC=${COBC:-cobc}
CFLAGS="-free -I copybooks"
BUILD_DIR="build/test_blim"
DATA_DIR="var/data"

mkdir -p "$BUILD_DIR"
mkdir -p "$DATA_DIR"

# Clean any existing limit usage index for repeatable test run
rm -f "$DATA_DIR/limuse.idx" "$DATA_DIR/limuse.idx"*

echo "Compiling BLIM regression suite..."
$COBC $CFLAGS -x -o "$BUILD_DIR/test_blim" tests/test_blim_driver.cbl cobol/limits/BLIM.cbl cobol/foundation/BCFG.cbl || exit 1

echo "Running BLIM regression tests..."
export BANK_HOME="${BANK_HOME:-$PWD}"
out=$("$BUILD_DIR/test_blim")

PASS=0
FAIL=0

check() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        echo "ok   $name"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL $name expected=[$expected] actual=[$actual]"
    fi
}

# 1. First valid consumption: rc=00, used=200000.00, avail=800000.00
check "consume_valid_1_rc" "00" "$(grep 'test=consume_valid_1' <<<"$out" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')"
check "consume_valid_1_used" "200000.00" "$(grep 'test=consume_valid_1' <<<"$out" | sed -n 's/.*used=\([0-9.]*\).*/\1/p')"
check "consume_valid_1_avail" "800000.00" "$(grep 'test=consume_valid_1' <<<"$out" | sed -n 's/.*avail=\([0-9.]*\).*/\1/p')"

# 2. Second valid consumption: rc=00, used=500000.00, avail=500000.00
check "consume_valid_2_rc" "00" "$(grep 'test=consume_valid_2' <<<"$out" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')"
check "consume_valid_2_used" "500000.00" "$(grep 'test=consume_valid_2' <<<"$out" | sed -n 's/.*used=\([0-9.]*\).*/\1/p')"
check "consume_valid_2_avail" "500000.00" "$(grep 'test=consume_valid_2' <<<"$out" | sed -n 's/.*avail=\([0-9.]*\).*/\1/p')"

# 3. Over-limit rejection: rc=20, msg=LIMIT EXCEEDED
check "consume_over_limit_rc" "20" "$(grep 'test=consume_over_limit' <<<"$out" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')"
check "consume_over_limit_msg" "LIMIT EXCEEDED" "$(grep 'test=consume_over_limit' <<<"$out" | sed -n 's/.*msg=\([^ ]* [^ ]*\).*/\1/p')"

# 4. Headroom preserved: valid 400,000 must succeed (total used=900,000.00, avail=100000.00)
# (In unpatched code, over-limit was persisted, causing this valid request to fail)
check "headroom_preserved_rc" "00" "$(grep 'test=headroom_preserved' <<<"$out" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')"
check "headroom_preserved_used" "900000.00" "$(grep 'test=headroom_preserved' <<<"$out" | sed -n 's/.*used=\([0-9.]*\).*/\1/p')"
check "headroom_preserved_avail" "100000.00" "$(grep 'test=headroom_preserved' <<<"$out" | sed -n 's/.*avail=\([0-9.]*\).*/\1/p')"

# 5. Release usage: release 400k -> used back to 500,000.00, avail=500,000.00
check "release_usage_rc" "00" "$(grep 'test=release_usage' <<<"$out" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')"
check "release_usage_used" "500000.00" "$(grep 'test=release_usage' <<<"$out" | sed -n 's/.*used=\([0-9.]*\).*/\1/p')"

# 6. Check within limit
check "check_within_limit_rc" "00" "$(grep 'test=check_within_limit' <<<"$out" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')"

# Cleanup test index
rm -f "$DATA_DIR/limuse.idx" "$DATA_DIR/limuse.idx"*

echo "----------------------------------------"
echo "BLIM tests finished: $PASS passed, $FAIL failed."
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
