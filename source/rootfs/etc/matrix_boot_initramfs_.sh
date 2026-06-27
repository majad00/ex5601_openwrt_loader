#!/bin/sh
# Matrix EX5601-T0 ubootmod initramfs stager
# written by majad qureshi at lut .fi

set -u

INITRAMFS="/tmp/initramfs.bin"
LOG="/tmp/matrix_boot_initramfs.log"
WORK="/tmp/matrix-initramfs-stage"
LOCK="/tmp/matrix-initramfs-stage.lock"

exec > "$LOG" 2>&1

fail() {
	echo "ERROR: $*" >&2
	exit 1
}

say() {
	echo "$*"
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

		if [ "$n" = "$want" ]; then
			echo "/dev/$(basename "$u")"
			return 0
		fi
	done

	return 1
}

attach_mtd() {
	local mtdnum="$1"
	local ubidev

	ubidev="$(find_ubi_by_mtdnum "$mtdnum" || true)"

	if [ -n "$ubidev" ]; then
		echo "$ubidev"
		return 0
	fi

	ubiattach -p "/dev/mtd$mtdnum" >/dev/null 2>&1 || \
		ubiattach /dev/ubi_ctrl -m "$mtdnum" >/dev/null 2>&1 || \
		fail "could not attach /dev/mtd$mtdnum"

	sleep 1

	ubidev="$(find_ubi_by_mtdnum "$mtdnum" || true)"
	[ -n "$ubidev" ] || fail "attached mtd$mtdnum but could not find UBI device"

	echo "$ubidev"
}

detach_mtd_if_attached() {
	local mtdnum="$1"
	local ubidev

	ubidev="$(find_ubi_by_mtdnum "$mtdnum" || true)"
	[ -n "$ubidev" ] || return 0

	ubidetach -p "/dev/mtd$mtdnum" >/dev/null 2>&1 || \
		ubidetach /dev/ubi_ctrl -m "$mtdnum" >/dev/null 2>&1 || \
		fail "could not detach /dev/mtd$mtdnum"
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

read_u16_le() {
	local file="$1"
	local off="$2"
	local lo hi

	lo="$(dd if="$file" bs=1 skip="$off" count=1 2>/dev/null | hexdump -v -e '1/1 "%u"')"
	hi="$(dd if="$file" bs=1 skip="$((off + 1))" count=1 2>/dev/null | hexdump -v -e '1/1 "%u"')"

	[ -n "$lo" ] || lo=0
	[ -n "$hi" ] || hi=0

	echo $((lo + (hi * 256)))
}

write_byte() {
	local file="$1"
	local off="$2"
	local val="$3"
	local oct

	[ "$val" -ge 0 ] && [ "$val" -le 255 ] || fail "byte out of range: $val"

	oct="$(printf '%03o' "$val")"
	printf "\\$oct" | dd of="$file" bs=1 seek="$off" conv=notrunc 2>/dev/null
}

write_u16_le() {
	local file="$1"
	local off="$2"
	local val="$3"
	local lo hi

	lo=$((val & 255))
	hi=$(((val >> 8) & 255))

	write_byte "$file" "$off" "$lo"
	write_byte "$file" "$((off + 1))" "$hi"
}

cleanup() {
	rm -rf "$LOCK"
}
trap cleanup EXIT

mkdir "$LOCK" 2>/dev/null || fail "another initramfs staging process is running"

say "=== Matrix EX5601-T0 initramfs stager ==="

say "[1] Checking commands"

need_cmd awk
need_cmd cat
need_cmd cp
need_cmd dd
need_cmd grep
need_cmd hexdump
need_cmd mkdir
need_cmd rm
need_cmd sleep
need_cmd sync
need_cmd ubidetach
need_cmd ubiformat
need_cmd ubiattach
need_cmd ubimkvol
need_cmd ubinfo
need_cmd ubiupdatevol
need_cmd wc

say "[2] Checking image"

[ -f "$INITRAMFS" ] || fail "missing $INITRAMFS"

INITRAMFS_SIZE="$(wc -c < "$INITRAMFS" | awk '{print $1}')"
[ "$INITRAMFS_SIZE" -gt 1048576 ] || fail "initramfs image too small"

MAGIC="$(dd if="$INITRAMFS" bs=4 count=1 2>/dev/null | hexdump -v -e '4/1 "%02x"')"

case "$MAGIC" in
	d00dfeed)
		say "FIT image detected"
		;;
	*)
		fail "initramfs.bin does not look like a FIT/ITB image, magic=$MAGIC"
		;;
esac

say "INITRAMFS_SIZE=$INITRAMFS_SIZE"

say "[3] Checking OEM stock layout"

[ -r /proc/mtd ] || fail "/proc/mtd missing"
[ -r /proc/cmdline ] || fail "/proc/cmdline missing"

MTD_PARENT="$(mtd_num_by_name spi0.1 || true)"
MTD_UBI="$(mtd_num_by_name ubi || true)"
MTD_UBI2="$(mtd_num_by_name ubi2 || true)"
MTD_ZYUBI="$(mtd_num_by_name zyubi || true)"

[ "$MTD_PARENT" = "0" ] || fail "not OEM stock layout: expected mtd0 named spi0.1"
[ "$MTD_UBI" = "6" ] || fail "not OEM stock layout: expected mtd6 named ubi"
[ "$MTD_UBI2" = "7" ] || fail "not OEM stock layout: expected mtd7 named ubi2"
[ "$MTD_ZYUBI" = "8" ] || fail "not OEM stock layout: expected mtd8 named zyubi"

CMDLINE="$(cat /proc/cmdline)"
say "$CMDLINE"

case "$CMDLINE" in
	*rootubi=ubi2*)
		ACTIVE_MTD="$MTD_UBI2"
		TARGET_MTD="$MTD_UBI"
		TARGET_NAME="ubi"
		;;
	*rootubi=ubi*)
		ACTIVE_MTD="$MTD_UBI"
		TARGET_MTD="$MTD_UBI2"
		TARGET_NAME="ubi2"
		;;
	*)
		fail "could not determine active bank from rootubi= in /proc/cmdline"
		;;
esac

[ "$TARGET_MTD" != "$MTD_ZYUBI" ] || fail "refusing to target zyubi"
[ "$TARGET_MTD" != "$ACTIVE_MTD" ] || fail "target equals active bank"

say "ACTIVE_MTD=mtd$ACTIVE_MTD"
say "TARGET_MTD=mtd$TARGET_MTD"
say "TARGET_NAME=$TARGET_NAME"

say "[4] Reading active metadata"

ACTIVE_UBI="$(attach_mtd "$ACTIVE_MTD")"
say "ACTIVE_UBI=$ACTIVE_UBI"

[ -e "${ACTIVE_UBI}_2" ] || fail "active zyfwinfo volume missing: ${ACTIVE_UBI}_2"

rm -rf "$WORK"
mkdir -p "$WORK"

dd if="${ACTIVE_UBI}_2" of="$WORK/zyfwinfo.active.bin" bs=256 count=1 >/dev/null 2>&1 || \
	fail "could not read active zyfwinfo"

if [ -e "${ACTIVE_UBI}_3" ]; then
	ACTIVE_LEB_SIZE="$(get_leb_size "$ACTIVE_UBI")"
	dd if="${ACTIVE_UBI}_3" of="$WORK/zydefault.active.bin" bs="$ACTIVE_LEB_SIZE" count=1 >/dev/null 2>&1 || \
		fail "could not read active zydefault"
else
	ACTIVE_LEB_SIZE=""
fi

ACTIVE_SEQ="$(read_u16_le "$WORK/zyfwinfo.active.bin" 6)"
NEW_SEQ=$((ACTIVE_SEQ + 1))
[ "$NEW_SEQ" -le 65535 ] || fail "zyfwinfo sequence overflow"

CHECKSUM=$((0x0e71 + NEW_SEQ))
CHECKSUM_LO=$((CHECKSUM & 255))
CHECKSUM_HI=$(((CHECKSUM >> 8) & 255))

say "ACTIVE_SEQ=$ACTIVE_SEQ"
say "NEW_SEQ=$NEW_SEQ"

say "[5] Formatting inactive stock bank"

detach_mtd_if_attached "$TARGET_MTD"

ubiformat "/dev/mtd$TARGET_MTD" -y >/dev/null || \
	fail "ubiformat failed on /dev/mtd$TARGET_MTD"

TARGET_UBI="$(attach_mtd "$TARGET_MTD")"
say "TARGET_UBI=$TARGET_UBI"

LEB_SIZE="$(get_leb_size "$TARGET_UBI")"
[ -n "$LEB_SIZE" ] || fail "could not determine target LEB size"

KERNEL_VOL_SIZE="$(round_up_leb_size "$INITRAMFS_SIZE" "$LEB_SIZE")"
ROOTFS_VOL_SIZE="$LEB_SIZE"
ZYFWINFO_VOL_SIZE="$LEB_SIZE"
ZYDEFAULT_VOL_SIZE="$LEB_SIZE"

say "LEB_SIZE=$LEB_SIZE"
say "KERNEL_VOL_SIZE=$KERNEL_VOL_SIZE"

say "[6] Creating temporary boot volumes"

ubimkvol "$TARGET_UBI" -n 0 -N kernel -s "$KERNEL_VOL_SIZE" >/dev/null || \
	fail "could not create kernel volume"

ubimkvol "$TARGET_UBI" -n 1 -N rootfs -s "$ROOTFS_VOL_SIZE" >/dev/null || \
	fail "could not create rootfs volume"

ubimkvol "$TARGET_UBI" -n 2 -N zyfwinfo -s "$ZYFWINFO_VOL_SIZE" >/dev/null || \
	fail "could not create zyfwinfo volume"

ubimkvol "$TARGET_UBI" -n 3 -N zydefault -s "$ZYDEFAULT_VOL_SIZE" >/dev/null || \
	fail "could not create zydefault volume"

ubimkvol "$TARGET_UBI" -n 4 -N rootfs_data -m >/dev/null || \
	fail "could not create rootfs_data volume"

say "[7] Writing initramfs FIT"

ubiupdatevol "${TARGET_UBI}_0" "$INITRAMFS" >/dev/null || \
	fail "could not write initramfs kernel volume"

dd if=/dev/zero of="$WORK/empty-rootfs.bin" bs="$LEB_SIZE" count=1 >/dev/null 2>&1 || \
	fail "could not create empty rootfs placeholder"

ubiupdatevol "${TARGET_UBI}_1" "$WORK/empty-rootfs.bin" >/dev/null || \
	fail "could not write empty rootfs placeholder"

say "[8] Updating zyfwinfo"

cp "$WORK/zyfwinfo.active.bin" "$WORK/zyfwinfo.target.bin" || \
	fail "could not copy zyfwinfo"

write_u16_le "$WORK/zyfwinfo.target.bin" 6 "$NEW_SEQ"
write_byte "$WORK/zyfwinfo.target.bin" 254 "$CHECKSUM_LO"
write_byte "$WORK/zyfwinfo.target.bin" 255 "$CHECKSUM_HI"

ubiupdatevol "${TARGET_UBI}_2" "$WORK/zyfwinfo.target.bin" >/dev/null || \
	fail "could not write target zyfwinfo"

say "[9] Writing zydefault"

if [ -f "$WORK/zydefault.active.bin" ]; then
	ubiupdatevol "${TARGET_UBI}_3" "$WORK/zydefault.active.bin" >/dev/null || \
		fail "could not write zydefault"
else
	dd if=/dev/zero of="$WORK/zydefault.empty.bin" bs="$LEB_SIZE" count=1 >/dev/null 2>&1
	ubiupdatevol "${TARGET_UBI}_3" "$WORK/zydefault.empty.bin" >/dev/null || \
		fail "could not write empty zydefault"
fi

say "[10] Final sync"

sync
sync

say "=============================================="
say "STAGE COMPLETE"
say "Temporary initramfs FIT has been written."
say "Target bank: mtd$TARGET_MTD / $TARGET_NAME"
say "No ubootmod NAND conversion was done."
say "No FIP was written."
say "Log: $LOG"
say "=============================================="

say "Rebooting in 5 seconds..."
sleep 5
reboot -f

exit 0

