#!/bin/sh
#written by majad.qureshi at lut.fi
set -eu

FW_ARG="${1:-}"
WORK="/tmp/matrix_fw"
LOCKDIR="/tmp/matrix_flash.lock"

fail() {
	echo "ERROR: $*" >&2
	exit 1
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

mtd_num_by_name() {
	local name="$1"
	awk -v n="\"$name\"" '$4 == n {
		gsub(/^mtd/, "", $1);
		gsub(/:$/, "", $1);
		print $1;
		exit;
	}' /proc/mtd
}

find_ubi_by_mtdnum() {
	local want="$1"
	local u n

	for u in /sys/class/ubi/ubi[0-9]*; do
		[ -f "$u/mtd_num" ] || continue
		n="$(cat "$u/mtd_num")"
		[ "$n" = "$want" ] && {
			echo "/dev/$(basename "$u")"
			return 0
		}
	done

	return 1
}

get_leb_size() {
	local ubidev="$1"
	local base="${ubidev##*/}"

	if [ -f "/sys/class/ubi/$base/usable_eb_size" ]; then
		cat "/sys/class/ubi/$base/usable_eb_size"
		return
	fi

	ubinfo "$ubidev" | awk -F: '/Logical eraseblock size/ {
		gsub(/ bytes.*/, "", $2);
		gsub(/ /, "", $2);
		print $2;
		exit;
	}'
}

round_up_leb_size() {
	local size="$1"
	local leb="$2"
	echo $(( ((size + leb - 1) / leb) * leb ))
}

read_byte_dec() {
	dd if="$1" bs=1 skip="$2" count=1 2>/dev/null | hexdump -v -e '1/1 "%u"'
}

write_byte_dec() {
	local file="$1"
	local offset="$2"
	local value="$3"
	local oct

	[ "$value" -ge 0 ] && [ "$value" -le 255 ] || fail "byte value out of range: $value"

	oct="$(printf '%03o' "$value")"
	printf "\\$oct" | dd of="$file" bs=1 seek="$offset" conv=notrunc 2>/dev/null
}

cleanup() {
	rm -rf "$LOCKDIR"
}
trap cleanup EXIT

mkdir "$LOCKDIR" 2>/dev/null || fail "another flash process is already running"

need_cmd awk
need_cmd cat
need_cmd dd
need_cmd grep
need_cmd hexdump
need_cmd tar
need_cmd ubinfo
need_cmd ubiattach
need_cmd ubimkvol
need_cmd ubirmvol
need_cmd ubiupdatevol
need_cmd wc
need_cmd sync

echo "Matrix EX5601-T0 inactive-slot installer"

[ "$(id -u)" = "0" ] || fail "must run as root"

[ -r /proc/mtd ] || fail "/proc/mtd missing"
[ -r /proc/cmdline ] || fail "/proc/cmdline missing"

MTD_PARENT="$(mtd_num_by_name spi0.1 || true)"
MTD_UBI="$(mtd_num_by_name ubi || true)"
MTD_UBI2="$(mtd_num_by_name ubi2 || true)"
MTD_ZYUBI="$(mtd_num_by_name zyubi || true)"

[ "$MTD_PARENT" = "0" ] || fail "not OEM layout: spi0.1 parent mtd0 missing"
[ "$MTD_UBI" = "6" ] || fail "not OEM layout: expected mtd6 named ubi"
[ "$MTD_UBI2" = "7" ] || fail "not OEM layout: expected mtd7 named ubi2"
[ "$MTD_ZYUBI" = "8" ] || fail "not OEM layout: expected mtd8 named zyubi"

ROOTUBI="$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^rootubi=//p' | head -n1)"

case "$ROOTUBI" in
	ubi)
		ACTIVE_MTD="$MTD_UBI"
		TARGET_MTD="$MTD_UBI2"
		TARGET_NAME="ubi2"
		DEFAULT_FW="/tmp/openwrt_ubi2.bin"
		REQUIRE_LABELSWAP=1
		;;
	ubi2)
		ACTIVE_MTD="$MTD_UBI2"
		TARGET_MTD="$MTD_UBI"
		TARGET_NAME="ubi"
		DEFAULT_FW="/tmp/openwrt_ubi.bin"
		REQUIRE_LABELSWAP=0
		;;
	*)
		fail "unsupported or missing rootubi=$ROOTUBI"
		;;
esac

FW="${FW_ARG:-$DEFAULT_FW}"

[ -f "$FW" ] || fail "firmware not found: $FW"

ACTIVE_UBI="$(find_ubi_by_mtdnum "$ACTIVE_MTD" || true)"
[ -n "$ACTIVE_UBI" ] || fail "active UBI device not found"

if [ "$TARGET_MTD" = "$MTD_ZYUBI" ]; then
	fail "refusing to touch zyubi"
fi

if [ "$TARGET_MTD" = "$ACTIVE_MTD" ]; then
	fail "target equals active slot"
fi

echo "Active root: $ROOTUBI"
echo "Target slot: $TARGET_NAME"
echo "Firmware: $FW"

rm -rf "$WORK"
mkdir -p "$WORK"

tar -xf "$FW" -C "$WORK" || fail "firmware is not a valid sysupgrade tar"

FWDIR="$(find "$WORK" -mindepth 1 -maxdepth 1 -type d -name 'sysupgrade-*' | head -n1)"
[ -n "$FWDIR" ] || fail "sysupgrade directory not found"

KERNEL="$FWDIR/kernel"
ROOT="$FWDIR/root"

[ -f "$KERNEL" ] || fail "kernel file missing"
[ -f "$ROOT" ] || fail "root file missing"

if [ "$REQUIRE_LABELSWAP" = "1" ]; then
	grep -q "ubi_oem" "$KERNEL" 2>/dev/null || fail "image is not label-swap patched for ubi2 target"
else
	if grep -q "ubi_oem" "$KERNEL" 2>/dev/null; then
		fail "label-swap image is not suitable for flashing physical ubi target"
	fi
fi

KERNEL_SIZE="$(wc -c < "$KERNEL")"
ROOT_SIZE="$(wc -c < "$ROOT")"

TARGET_UBI="$(find_ubi_by_mtdnum "$TARGET_MTD" || true)"

if [ -z "$TARGET_UBI" ]; then
	ubiattach -p "/dev/mtd$TARGET_MTD" >/dev/null
	sleep 1
	TARGET_UBI="$(find_ubi_by_mtdnum "$TARGET_MTD" || true)"
fi

[ -n "$TARGET_UBI" ] || fail "could not attach target UBI"

LEB_SIZE="$(get_leb_size "$TARGET_UBI")"
[ -n "$LEB_SIZE" ] || fail "could not determine LEB size"

KERNEL_VOL_SIZE="$(round_up_leb_size "$KERNEL_SIZE" "$LEB_SIZE")"
ROOTFS_VOL_SIZE="$(round_up_leb_size "$ROOT_SIZE" "$LEB_SIZE")"

echo "Preparing inactive slot"

if command -v ubiblock >/dev/null 2>&1; then
	ubiblock -r "${TARGET_UBI}_1" >/dev/null 2>&1 || true
fi

for v in rootfs_data zydefault zyfwinfo rootfs kernel; do
	ubirmvol "$TARGET_UBI" -N "$v" >/dev/null 2>&1 || true
done

ubimkvol "$TARGET_UBI" -n 0 -N kernel -s "$KERNEL_VOL_SIZE" >/dev/null
ubimkvol "$TARGET_UBI" -n 1 -N rootfs -s "$ROOTFS_VOL_SIZE" >/dev/null
ubimkvol "$TARGET_UBI" -n 2 -N zyfwinfo -s "$LEB_SIZE" >/dev/null
ubimkvol "$TARGET_UBI" -n 3 -N zydefault -s "$LEB_SIZE" >/dev/null
ubimkvol "$TARGET_UBI" -n 4 -N rootfs_data -m >/dev/null

echo "Writing firmware"

ubiupdatevol "${TARGET_UBI}_0" "$KERNEL" >/dev/null
ubiupdatevol "${TARGET_UBI}_1" "$ROOT" >/dev/null

echo "Updating boot metadata"

dd if="${ACTIVE_UBI}_2" of=/tmp/matrix_zyfwinfo.bin bs=256 count=1 >/dev/null 2>&1 || fail "could not read active zyfwinfo"

ACTIVE_SEQ="$(read_byte_dec /tmp/matrix_zyfwinfo.bin 6)"
[ -n "$ACTIVE_SEQ" ] || fail "could not read zyfwinfo sequence"

NEWSEQ=$((ACTIVE_SEQ + 1))
[ "$NEWSEQ" -le 255 ] || fail "zyfwinfo sequence overflow"

CHECKSUM=$((0x0e71 + NEWSEQ))
CHECKSUM_LO=$((CHECKSUM & 255))
CHECKSUM_HI=$(((CHECKSUM >> 8) & 255))

write_byte_dec /tmp/matrix_zyfwinfo.bin 6 "$NEWSEQ"
write_byte_dec /tmp/matrix_zyfwinfo.bin 254 "$CHECKSUM_LO"
write_byte_dec /tmp/matrix_zyfwinfo.bin 255 "$CHECKSUM_HI"

ubiupdatevol "${TARGET_UBI}_2" /tmp/matrix_zyfwinfo.bin >/dev/null

dd if="${ACTIVE_UBI}_3" of=/tmp/matrix_zydefault.bin >/dev/null 2>&1 || fail "could not read active zydefault"
ubiupdatevol "${TARGET_UBI}_3" /tmp/matrix_zydefault.bin >/dev/null

sync
sync

echo "Flash complete. Rebooting."
sleep 3
reboot
