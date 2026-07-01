#!/bin/sh
set -u

TAG="${1:-check}"
OUT="/tmp/matrix_no_uart_${TAG}.log"

exec > "$OUT" 2>&1

fail() {
echo "ERROR: $*" >&2
exit 1
}

mtd_num_by_name() {
local name="$1"

awk -v want="$name" '
BEGIN { want = tolower(want) }
/^mtd[0-9]+:/ {
name=$4
gsub(/"/,"",name)
if (tolower(name) == want) {
gsub(/^mtd/,"",$1)
gsub(/:$/,"",$1)
print $1
exit
}
}
' /proc/mtd
}

find_ubi_by_mtdnum() {
local want="$1"
local u n

for u in /sys/class/ubi/ubi[0-9]*; do
[ -f "$u/mtd_num" ] || continue
n="$(cat "$u/mtd_num" 2>/dev/null || true)"
[ "$n" = "$want" ] && {
echo "/dev/$(basename "$u")"
return 0
}
done

return 1
}

attach_mtd() {
local mtd="$1"
local ubidev

ubidev="$(find_ubi_by_mtdnum "$mtd" || true)"
if [ -n "$ubidev" ]; then
echo "$ubidev"
return 0
fi

ubiattach -p "/dev/mtd$mtd" >/dev/null 2>&1 || \
ubiattach /dev/ubi_ctrl -m "$mtd" >/dev/null 2>&1 || \
fail "could not attach mtd$mtd"

sleep 1

ubidev="$(find_ubi_by_mtdnum "$mtd" || true)"
[ -n "$ubidev" ] || fail "attached mtd$mtd but cannot find UBI device"

echo "$ubidev"
}

ubi_vol_dev_by_name() {
local ubidev="$1"
local want="$2"
local base="${ubidev##*/}"
local p name

for p in /sys/class/ubi/"$base"_*; do
[ -f "$p/name" ] || continue
name="$(cat "$p/name" 2>/dev/null || true)"
if [ "$name" = "$want" ]; then
echo "/dev/$(basename "$p")"
return 0
fi
done

return 1
}

read_byte_dec() {
dd if="$1" bs=1 skip="$2" count=1 2>/dev/null | hexdump -v -e '1/1 "%u"'
}

calc_zyfwinfo_checksum() {
local file="$1"

dd if="$file" bs=1 count=254 2>/dev/null | \
hexdump -v -e '1/1 "%u\n"' | \
awk '{s += $1} END {print s % 65536}'
}

stored_zyfwinfo_checksum() {
local file="$1"
local lo hi

lo="$(read_byte_dec "$file" 254)"
hi="$(read_byte_dec "$file" 255)"
echo $((lo + hi * 256))
}

dump_zyfwinfo() {
local label="$1"
local dev="$2"
local out="/tmp/${label}_zyfwinfo.bin"
local seq calc stored

echo ""
echo "===== $label zyfwinfo ====="
echo "device=$dev"

dd if="$dev" of="$out" bs=256 count=1 >/dev/null 2>&1 || {
echo "FAILED to read $dev"
return 1
}

hexdump -C "$out"

seq="$(read_byte_dec "$out" 6)"
calc="$(calc_zyfwinfo_checksum "$out")"
stored="$(stored_zyfwinfo_checksum "$out")"

echo "${label}_SEQ=$seq"
echo "${label}_CALC=0x$(printf '%04x' "$calc")"
echo "${label}_STORED=0x$(printf '%04x' "$stored")"

if [ "$calc" = "$stored" ]; then
echo "${label}_CHECKSUM=OK"
else
echo "${label}_CHECKSUM=BAD"
fi

echo "$seq" > "/tmp/${label}_seq.txt"
echo "$calc" > "/tmp/${label}_calc.txt"
echo "$stored" > "/tmp/${label}_stored.txt"
}

dump_kernel_check() {
local dev="$1"
local target_name="$2"
local head="/tmp/target_kernel_head.bin"
local magic

echo ""
echo "===== target kernel/FIT check ====="
echo "device=$dev"

dd if="$dev" of="$head" bs=512K count=1 >/dev/null 2>&1 || {
echo "FAILED to read target kernel"
return 1
}

magic="$(dd if="$head" bs=4 count=1 2>/dev/null | hexdump -v -e '4/1 "%02x"')"
echo "FIT_MAGIC=$magic"

if [ "$magic" = "d00dfeed" ]; then
echo "FIT_MAGIC_CHECK=OK"
else
echo "FIT_MAGIC_CHECK=BAD"
fi

echo ""
echo "Interesting strings from target kernel:"
if command -v strings >/dev/null 2>&1; then
strings "$head" | grep -Ei 'ubootmod|stock|labelswap|bootargs|rootubi|ubi_oem|EX5601|OpenWrt|Linux' | head -n 80 || true
else
grep -aE 'ubootmod|stock|labelswap|bootargs|rootubi|ubi_oem|EX5601|OpenWrt|Linux' "$head" | head -n 80 || true
fi

echo ""
if grep -aq 'ubootmod' "$head"; then
echo "WARNING: target image contains ubootmod. Stock zloader may fail with: bootargs in fdt not found"
fi

if [ "$target_name" = "ubi2" ]; then
if grep -aqE 'labelswap|ubi_oem' "$head"; then
echo "LABELSWAP_CHECK=probably OK for physical ubi2 target"
else
echo "WARNING: target is physical ubi2 but image does not show labelswap/ubi_oem string"
fi
fi
}

echo "===== Matrix no-UART boot switch check ====="
date 2>/dev/null || true

echo ""
echo "===== /proc/cmdline ====="
cat /proc/cmdline

echo ""
echo "===== /proc/mtd ====="
cat /proc/mtd

ROOTUBI="$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^rootubi=//p' | head -n1)"
MTD_UBI="$(mtd_num_by_name ubi || true)"
MTD_UBI2="$(mtd_num_by_name ubi2 || true)"
MTD_ZYUBI="$(mtd_num_by_name zyubi || true)"

[ -n "$MTD_UBI" ] || fail "mtd named ubi not found"
[ -n "$MTD_UBI2" ] || fail "mtd named ubi2 not found"
[ -n "$MTD_ZYUBI" ] || fail "mtd named zyubi not found"

case "$ROOTUBI" in
ubi)
ACTIVE_MTD="$MTD_UBI"
TARGET_MTD="$MTD_UBI2"
TARGET_NAME="ubi2"
;;
ubi2)
ACTIVE_MTD="$MTD_UBI2"
TARGET_MTD="$MTD_UBI"
TARGET_NAME="ubi"
;;
*)
fail "unsupported or missing rootubi=$ROOTUBI"
;;
esac

echo ""
echo "ROOTUBI=$ROOTUBI"
echo "ACTIVE_MTD=mtd$ACTIVE_MTD"
echo "TARGET_MTD=mtd$TARGET_MTD"
echo "TARGET_NAME=$TARGET_NAME"

ACTIVE_UBI="$(attach_mtd "$ACTIVE_MTD")"
TARGET_UBI="$(attach_mtd "$TARGET_MTD")"

echo "ACTIVE_UBI=$ACTIVE_UBI"
echo "TARGET_UBI=$TARGET_UBI"

echo ""
echo "===== ubinfo -a ====="
ubinfo -a 2>&1 || true

ACTIVE_ZYFW="$(ubi_vol_dev_by_name "$ACTIVE_UBI" zyfwinfo || true)"
TARGET_ZYFW="$(ubi_vol_dev_by_name "$TARGET_UBI" zyfwinfo || true)"
TARGET_KERNEL="$(ubi_vol_dev_by_name "$TARGET_UBI" kernel || true)"
TARGET_ROOTFS="$(ubi_vol_dev_by_name "$TARGET_UBI" rootfs || true)"

[ -n "$ACTIVE_ZYFW" ] || fail "active zyfwinfo not found"
[ -n "$TARGET_ZYFW" ] || fail "target zyfwinfo not found"
[ -n "$TARGET_KERNEL" ] || fail "target kernel not found"
[ -n "$TARGET_ROOTFS" ] || fail "target rootfs not found"

dump_zyfwinfo active "$ACTIVE_ZYFW"
dump_zyfwinfo target "$TARGET_ZYFW"

ACTIVE_SEQ="$(cat /tmp/active_seq.txt)"
TARGET_SEQ="$(cat /tmp/target_seq.txt)"
TARGET_CALC="$(cat /tmp/target_calc.txt)"
TARGET_STORED="$(cat /tmp/target_stored.txt)"

echo ""
echo "===== boot switch decision check ====="

if [ "$TARGET_CALC" = "$TARGET_STORED" ]; then
echo "TARGET_ZYFWINFO_CHECKSUM=OK"
else
echo "TARGET_ZYFWINFO_CHECKSUM=BAD"
fi

if [ "$TARGET_SEQ" -gt "$ACTIVE_SEQ" ]; then
echo "TARGET_SEQUENCE_HIGHER=OK"
else
echo "TARGET_SEQUENCE_HIGHER=BAD"
fi

echo "active seq=$ACTIVE_SEQ"
echo "target seq=$TARGET_SEQ"

dump_kernel_check "$TARGET_KERNEL" "$TARGET_NAME"

echo ""
echo "===== summary ====="

if [ "$TARGET_CALC" = "$TARGET_STORED" ] && [ "$TARGET_SEQ" -gt "$ACTIVE_SEQ" ]; then
echo "ZYFWINFO_SWITCH_CONDITION=OK"
else
echo "ZYFWINFO_SWITCH_CONDITION=BAD"
fi

echo "Log saved to: $OUT"
