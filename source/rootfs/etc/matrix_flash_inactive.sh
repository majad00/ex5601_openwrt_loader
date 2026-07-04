#!/bin/sh
#written by majad.qureshi at lut.fi
# Modified universal boot-switch version for EX5601-T0 OEM V3.x / V4.x  and  ACEA ACQQ or ACID firmwares

set -eu

FW_ARG="${1:-}"
WORK="/tmp/matrix_fw"
LOCKDIR="/tmp/matrix_flash.lock"


ZYFWINFO_MODE="${ZYFWINFO_MODE:-rich}"



FIP_FIX="${FIP_FIX:-1}"
FIP_PATH="${FIP_PATH:-/tmp/fip.bin}"
FIP_ACTION="unknown"
FIP_CURRENT_SHA="unknown"
FIP_TARGET_SHA="unknown"
FIP_CURRENT_STRING="unknown"
FIP_TARGET_STRING="unknown"


ZLOADER_FIX="${ZLOADER_FIX:-1}"
OLD_ZLOADER_PATH="${OLD_ZLOADER_PATH:-/tmp/zl34.bin}"
ZLOADER_ACTION="unknown"
ZLOADER_CURRENT_STRING="unknown"
ZLOADER_TARGET_STRING="unknown"
ZLOADER_CURRENT_SHA="unknown"
ZLOADER_TARGET_SHA="unknown"

# NO_REBOOT=1 for testing.
NO_REBOOT="${NO_REBOOT:-0}"

fail() {
	echo "ERROR: $*" >&2
	exit 1
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

sha256_file() {
	sha256sum "$1" | awk '{print $1}'
}


mtd_num_by_name() {
	local name="$1"

	awk -v want="$name" '
		BEGIN {
			want = tolower(want)
		}

		/^mtd[0-9]+:/ {
			name = $4
			gsub(/"/, "", name)

			if (tolower(name) == want) {
				gsub(/^mtd/, "", $1)
				gsub(/:$/, "", $1)
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

get_leb_size() {
	local ubidev="$1"
	local base="${ubidev##*/}"
	local leb=""

	if [ -f "/sys/class/ubi/$base/usable_eb_size" ]; then
		leb="$(cat "/sys/class/ubi/$base/usable_eb_size" 2>/dev/null || true)"
		if [ -n "$leb" ]; then
			echo "$leb"
			return 0
		fi
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

write_le32_dec() {
	local file="$1"
	local offset="$2"
	local value="$3"
	local b0 b1 b2 b3

	[ "$value" -ge 0 ] || fail "le32 value out of range: $value"

	b0=$((value & 255))
	b1=$(((value >> 8) & 255))
	b2=$(((value >> 16) & 255))
	b3=$(((value >> 24) & 255))

	write_byte_dec "$file" "$offset" "$b0"
	write_byte_dec "$file" $((offset + 1)) "$b1"
	write_byte_dec "$file" $((offset + 2)) "$b2"
	write_byte_dec "$file" $((offset + 3)) "$b3"
}

read_le32_dec() {
	local file="$1"
	local offset="$2"
	local bytes b0 b1 b2 b3

	bytes="$(dd if="$file" bs=1 skip="$offset" count=4 2>/dev/null | hexdump -v -e '1/1 "%u\n"')"
	b0="$(echo "$bytes" | sed -n '1p')"
	b1="$(echo "$bytes" | sed -n '2p')"
	b2="$(echo "$bytes" | sed -n '3p')"
	b3="$(echo "$bytes" | sed -n '4p')"

	[ -n "$b0" ] && [ -n "$b1" ] && [ -n "$b2" ] && [ -n "$b3" ] || \
		fail "could not read le32 at offset $offset from $file"

	echo $((b0 + b1 * 256 + b2 * 65536 + b3 * 16777216))
}

round_up_4k_size() {
	local size="$1"
	echo $(( ((size + 4095) / 4096) * 4096 ))
}

calc_squashfs_load_size() {
	local rootfs="$1"
	local magic bytes_used load_size

	magic="$(dd if="$rootfs" bs=4 count=1 2>/dev/null | hexdump -v -e '1/1 "%02x"')"
	[ "$magic" = "68737173" ] || fail "target rootfs is not squashfs/hsqs; magic=$magic"

	bytes_used="$(read_le32_dec "$rootfs" 40)"
	load_size="$(round_up_4k_size "$bytes_used")"

	echo "$load_size"
}

calc_zyfwinfo_checksum() {
	local file="$1"

	dd if="$file" bs=1 count=254 2>/dev/null | \
		hexdump -v -e '1/1 "%u\n"' | \
		awk '{s += $1} END {print s % 65536}'
}

read_zyfwinfo_stored_checksum() {
	local file="$1"
	local lo hi

	lo="$(read_byte_dec "$file" 254)"
	hi="$(read_byte_dec "$file" 255)"

	echo $((lo + hi * 256))
}

write_zyfwinfo_checksum() {
	local file="$1"
	local checksum lo hi

	checksum="$(calc_zyfwinfo_checksum "$file")"
	lo=$((checksum & 255))
	hi=$(((checksum >> 8) & 255))

	write_byte_dec "$file" 254 "$lo"
	write_byte_dec "$file" 255 "$hi"

	echo "$checksum"
}

verify_zyfwinfo_file() {
	local file="$1"
	local expected_seq="$2"
	local label="$3"
	local seq calc stored byte04 byte09 rootfs_load_size

	[ -f "$file" ] || fail "$label missing: $file"

	seq="$(read_byte_dec "$file" 6)"
	byte04="$(read_byte_dec "$file" 4)"
	byte09="$(read_byte_dec "$file" 9)"
	rootfs_load_size="$(read_le32_dec "$file" 120)"
	calc="$(calc_zyfwinfo_checksum "$file")"
	stored="$(read_zyfwinfo_stored_checksum "$file")"

	echo "$label first 1 KiB:"
	dd if="$file" bs=1024 count=1 2>/dev/null | hexdump -C
	echo "$label sequence: $seq"
	echo "$label format byte04: $byte04"
	echo "$label format byte09: $byte09"
	printf "%s rootfs load size field 0x78: 0x%08x\n" "$label" "$rootfs_load_size"
	echo "$label checksum calculated: 0x$(printf '%04x' "$calc")"
	echo "$label checksum stored:     0x$(printf '%04x' "$stored")"

	[ "$seq" = "$expected_seq" ] || fail "$label sequence mismatch: expected $expected_seq got $seq"
	[ "$calc" = "$stored" ] || fail "$label checksum mismatch"
}

make_minimal_zyfwinfo() {
	local file="$1"
	local seq="$2"
	local checksum

	dd if=/dev/zero of="$file" bs=256 count=1 >/dev/null 2>&1 || \
		fail "could not create minimal zyfwinfo"

	# Magic: EXYZ
	write_byte_dec "$file" 0 69
	write_byte_dec "$file" 1 88
	write_byte_dec "$file" 2 89
	write_byte_dec "$file" 3 90

	# Minimal OpenWrt-compatible fields.
	write_byte_dec "$file" 4 2
	write_byte_dec "$file" 6 "$seq"
	write_byte_dec "$file" 9 1

	checksum="$(write_zyfwinfo_checksum "$file")"
	echo "$checksum"
}

make_copy_oem_zyfwinfo() {
	local active_zyfw="$1"
	local file="$2"
	local seq="$3"
	local checksum magic

	dd if="$active_zyfw" of="$file" bs=256 count=1 >/dev/null 2>&1 || \
		fail "could not read active zyfwinfo"

	magic="$(dd if="$file" bs=4 count=1 2>/dev/null || true)"
	[ "$magic" = "EXYZ" ] || fail "active zyfwinfo has bad magic"

	write_byte_dec "$file" 6 "$seq"

	# no hardcoded base like 0x0e71; always recalculate.
	checksum="$(write_zyfwinfo_checksum "$file")"
	echo "$checksum"
}

make_rich_zyfwinfo() {
	local active_zyfw="$1"
	local file="$2"
	local seq="$3"
	local target_rootfs="$4"
	local leb_size="$5"
	local checksum magic rootfs_load_size

	dd if="$active_zyfw" of="$file" bs="$leb_size" count=1 >/dev/null 2>&1 || \
		fail "could not read full active zyfwinfo"

	magic="$(dd if="$file" bs=4 count=1 2>/dev/null || true)"
	[ "$magic" = "EXYZ" ] || fail "active zyfwinfo has bad magic"


	write_byte_dec "$file" 4 3
	write_byte_dec "$file" 9 4
	echo "Forced zyfwinfo rich markers: byte04=3 byte09=4" >&2

	# Sequence controls which bank zloader selects.
	write_byte_dec "$file" 6 "$seq"

	rootfs_load_size="$(calc_squashfs_load_size "$target_rootfs")"
	write_le32_dec "$file" 120 "$rootfs_load_size"

	printf "Target rootfs load size for rich zyfwinfo: 0x%08x\n" "$rootfs_load_size" >&2

	# Recalculate first-0x100 zyfwinfo checksum.
	write_byte_dec "$file" 254 0
	write_byte_dec "$file" 255 0
	checksum="$(write_zyfwinfo_checksum "$file")"
	echo "$checksum"
}

inspect_fip_for_switch() {
	local fip_mtd="$1"
	local current_file="/tmp/matrix_fip_current.bin"
	local target_size mtd_size

	FIP_ACTION="keep"
	FIP_CURRENT_SHA="unknown"
	FIP_TARGET_SHA="unknown"
	FIP_CURRENT_STRING="unknown"
	FIP_TARGET_STRING="unknown"

	[ "$FIP_FIX" = "1" ] || {
		FIP_ACTION="disabled"
		echo "FIP_FIX=0; FIP replacement disabled."
		return 0
	}

	if [ ! -f "$FIP_PATH" ]; then
		FIP_ACTION="missing"
		echo "WARNING: FIP replacement missing: $FIP_PATH"
		echo "WARNING: continuing without FIP replacement."
		return 0
	fi

	target_size="$(wc -c < "$FIP_PATH" | awk '{print $1}')"
	mtd_size="$(cat "/sys/class/mtd/mtd$fip_mtd/size" 2>/dev/null || echo 0)"

	if [ "$mtd_size" -gt 0 ] && [ "$target_size" -gt "$mtd_size" ]; then
		FIP_ACTION="too_large"
		FIP_TARGET_SHA="$(sha256_file "$FIP_PATH")"
		echo "WARNING: target FIP is larger than /dev/mtd$fip_mtd: target=$target_size mtd=$mtd_size"
		echo "WARNING: continuing without FIP replacement."
		return 0
	fi

	dd if="/dev/mtd$fip_mtd" of="$current_file" bs="$target_size" count=1 >/dev/null 2>&1 || {
		FIP_ACTION="read_failed"
		echo "WARNING: could not read current FIP from /dev/mtd$fip_mtd"
		echo "WARNING: continuing without FIP replacement."
		return 0
	}

	FIP_CURRENT_SHA="$(sha256_file "$current_file")"
	FIP_TARGET_SHA="$(sha256_file "$FIP_PATH")"
	FIP_CURRENT_STRING="$(strings "$current_file" | grep -Ei 'U-Boot [0-9]|v[0-9][.][0-9].*release|BL31' | head -n1 || true)"
	FIP_TARGET_STRING="$(strings "$FIP_PATH" | grep -Ei 'U-Boot [0-9]|v[0-9][.][0-9].*release|BL31' | head -n1 || true)"
	[ -n "$FIP_CURRENT_STRING" ] || FIP_CURRENT_STRING="unknown"
	[ -n "$FIP_TARGET_STRING" ] || FIP_TARGET_STRING="unknown"

	echo "Current FIP:        $FIP_CURRENT_STRING"
	echo "Current FIP sha:    $FIP_CURRENT_SHA"
	echo "Target FIP:         $FIP_TARGET_STRING"
	echo "Target FIP sha:     $FIP_TARGET_SHA"

	if [ "$FIP_CURRENT_SHA" = "$FIP_TARGET_SHA" ]; then
		FIP_ACTION="keep"
		echo "Current FIP already matches $FIP_PATH; no FIP replacement needed."
	else
		FIP_ACTION="replace"
		echo "Current FIP differs from $FIP_PATH; will try to replace it before reboot."
		echo "If FIP replacement fails cleanly, the script will continue."
	fi
}

apply_fip_switch_if_needed() {
	local fip_mtd="$1"
	local target_size check_file before_file after_fail_file ro

	[ "$FIP_FIX" = "1" ] || {
		echo "FIP_FIX=0; not replacing FIP."
		return 0
	}

	[ "$FIP_ACTION" = "replace" ] || {
		echo "FIP replacement not needed. action=$FIP_ACTION"
		return 0
	}

	target_size="$(wc -c < "$FIP_PATH" | awk '{print $1}')"
	before_file="/tmp/matrix_fip_before_replace.bin"
	check_file="/tmp/matrix_fip_after_replace.bin"
	after_fail_file="/tmp/matrix_fip_after_failed_replace.bin"

	echo "Backing up current FIP to $before_file"
	dd if="/dev/mtd$fip_mtd" of="$before_file" bs="$target_size" count=1 >/dev/null 2>&1 || {
		echo "WARNING: could not backup current FIP; continuing without FIP replacement."
		FIP_ACTION="backup_failed"
		return 0
	}

	if [ -f "/sys/class/mtd/mtd$fip_mtd/ro" ]; then
		ro="$(cat "/sys/class/mtd/mtd$fip_mtd/ro" 2>/dev/null || echo 0)"
		if [ "$ro" != "0" ]; then
			echo "FIP MTD is read-only; trying /tmp/mtd-rw.ko"
			insmod /tmp/mtd-rw.ko i_want_a_brick=1 2>/dev/null || true
		fi
	fi

	echo "Writing replacement FIP from $FIP_PATH to /dev/mtd$fip_mtd"
	if ! mtd write "$FIP_PATH" "/dev/mtd$fip_mtd" >/dev/null 2>&1; then
		echo "WARNING: FIP write failed. Checking whether current FIP was left unchanged."
		dd if="/dev/mtd$fip_mtd" of="$after_fail_file" bs="$target_size" count=1 >/dev/null 2>&1 || \
			fail "FIP write failed and could not verify post-failure state"

		if cmp "$before_file" "$after_fail_file" >/dev/null; then
			echo "WARNING: FIP appears unchanged after failed write; continuing."
			FIP_ACTION="write_failed_unchanged"
			return 0
		fi

		fail "FIP write failed and FIP contents changed; refusing to reboot"
	fi

	sync

	dd if="/dev/mtd$fip_mtd" of="$check_file" bs="$target_size" count=1 >/dev/null 2>&1 || \
		fail "could not read back replaced FIP"

	if cmp "$FIP_PATH" "$check_file" >/dev/null; then
		echo "FIP_WRITE_OK"
		FIP_ACTION="replaced"
		FIP_CURRENT_SHA="$(sha256_file "$check_file")"
		strings "$check_file" | grep -Ei 'U-Boot [0-9]|v[0-9][.][0-9].*release|BL31' | head -n3 || true
	else
		fail "FIP readback mismatch after write; refusing to reboot"
	fi
}

inspect_zloader_for_switch() {
	local zld_mtd="$1"
	local current_file="/tmp/matrix_zloader_current.bin"
	local target_size mtd_size

	ZLOADER_ACTION="keep"
	ZLOADER_CURRENT_STRING="unknown"
	ZLOADER_TARGET_STRING="unknown"
	ZLOADER_CURRENT_SHA="unknown"
	ZLOADER_TARGET_SHA="unknown"

	[ "$ZLOADER_FIX" = "1" ] || {
		ZLOADER_ACTION="disabled"
		echo "ZLOADER_FIX=0; zloader replacement disabled."
		return 0
	}

	[ -f "$OLD_ZLOADER_PATH" ] || fail "zloader replacement missing: $OLD_ZLOADER_PATH"

	target_size="$(wc -c < "$OLD_ZLOADER_PATH" | awk '{print $1}')"
	mtd_size="$(cat "/sys/class/mtd/mtd$zld_mtd/size" 2>/dev/null || echo 0)"

	[ "$mtd_size" -eq 0 ] || [ "$target_size" -le "$mtd_size" ] || \
		fail "target zloader is larger than /dev/mtd$zld_mtd: target=$target_size mtd=$mtd_size"

	dd if="/dev/mtd$zld_mtd" of="$current_file" bs="$target_size" count=1 >/dev/null 2>&1 || \
		fail "could not read current zloader from /dev/mtd$zld_mtd"

	ZLOADER_CURRENT_SHA="$(sha256_file "$current_file")"
	ZLOADER_TARGET_SHA="$(sha256_file "$OLD_ZLOADER_PATH")"
	ZLOADER_CURRENT_STRING="$(strings "$current_file" | grep -E 'zld-[0-9]' | head -n1 || true)"
	ZLOADER_TARGET_STRING="$(strings "$OLD_ZLOADER_PATH" | grep -E 'zld-[0-9]' | head -n1 || true)"
	[ -n "$ZLOADER_CURRENT_STRING" ] || ZLOADER_CURRENT_STRING="unknown"
	[ -n "$ZLOADER_TARGET_STRING" ] || ZLOADER_TARGET_STRING="unknown"

	echo "Current zloader:     $ZLOADER_CURRENT_STRING"
	echo "Current zloader sha: $ZLOADER_CURRENT_SHA"
	echo "Target zloader:      $ZLOADER_TARGET_STRING"
	echo "Target zloader sha:  $ZLOADER_TARGET_SHA"

	if [ "$ZLOADER_CURRENT_SHA" = "$ZLOADER_TARGET_SHA" ]; then
		ZLOADER_ACTION="keep"
		echo "Current zloader already matches $OLD_ZLOADER_PATH; no zloader replacement needed."
	else
		ZLOADER_ACTION="replace"
		echo "Current zloader differs from $OLD_ZLOADER_PATH; will replace it before reboot."
	fi
}

apply_zloader_switch_if_needed() {
	local zld_mtd="$1"
	local zld_size check_file ro

	[ "$ZLOADER_FIX" = "1" ] || {
		echo "ZLOADER_FIX=0; not replacing zloader."
		return 0
	}

	[ "$ZLOADER_ACTION" = "replace" ] || {
		echo "Zloader replacement not needed."
		return 0
	}

	echo "Backing up current zloader to /tmp/matrix_zloader_before_replace.bin"
	dd if="/dev/mtd$zld_mtd" of=/tmp/matrix_zloader_before_replace.bin bs=256K count=1 >/dev/null 2>&1 || \
		fail "could not backup current zloader"

	if [ -f "/sys/class/mtd/mtd$zld_mtd/ro" ]; then
		ro="$(cat "/sys/class/mtd/mtd$zld_mtd/ro" 2>/dev/null || echo 0)"
		if [ "$ro" != "0" ]; then
			echo "zloader MTD is read-only; trying /tmp/mtd-rw.ko"
			insmod /tmp/mtd-rw.ko i_want_a_brick=1 2>/dev/null || true
			ro="$(cat "/sys/class/mtd/mtd$zld_mtd/ro" 2>/dev/null || echo 1)"
			[ "$ro" = "0" ] || fail "zloader MTD is still read-only"
		fi
	fi

	echo "Writing replacement zloader from $OLD_ZLOADER_PATH to /dev/mtd$zld_mtd"
	mtd write "$OLD_ZLOADER_PATH" "/dev/mtd$zld_mtd" >/dev/null || \
		fail "could not write replacement zloader"
	sync

	zld_size="$(wc -c < "$OLD_ZLOADER_PATH")"
	check_file="/tmp/matrix_zloader_after_replace.bin"
	dd if="/dev/mtd$zld_mtd" of="$check_file" bs="$zld_size" count=1 >/dev/null 2>&1 || \
		fail "could not read back replaced zloader"

	cmp "$OLD_ZLOADER_PATH" "$check_file" >/dev/null || fail "replacement zloader readback mismatch"
	ZLOADER_CURRENT_SHA="$(sha256_file "$check_file")"
	ZLOADER_ACTION="replaced"
	echo "ZLOADER_WRITE_OK"
	strings "$check_file" | grep -E 'zld-[0-9]' | head -n1 || true
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
need_cmd strings
need_cmd mtd
need_cmd cmp
need_cmd sed
need_cmd head
need_cmd tar
need_cmd ubinfo
need_cmd ubiattach
need_cmd ubimkvol
need_cmd ubirmvol
need_cmd ubiupdatevol
need_cmd wc
need_cmd sync
need_cmd sha256sum

echo "Matrix EX5601-T0 simple inactive-slot installer"
echo "Boot switch method: rich zyfwinfo sequence + optional old zloader workaround"
echo "No sys atsw / no sys seqnum / no sys atsh"
echo "ZYFWINFO_MODE=$ZYFWINFO_MODE"
echo "FIP_FIX=$FIP_FIX"
echo "FIP_PATH=$FIP_PATH"
echo "ZLOADER_FIX=$ZLOADER_FIX"
echo "OLD_ZLOADER_PATH=$OLD_ZLOADER_PATH"
echo "NO_REBOOT=$NO_REBOOT"

[ "$(id -u)" = "0" ] || fail "must run as root"

[ -r /proc/mtd ] || fail "/proc/mtd missing"
[ -r /proc/cmdline ] || fail "/proc/cmdline missing"

MTD_PARENT="$(mtd_num_by_name spi0.1 || true)"
MTD_UBI="$(mtd_num_by_name ubi || true)"
MTD_UBI2="$(mtd_num_by_name ubi2 || true)"
MTD_ZYUBI="$(mtd_num_by_name zyubi || true)"
MTD_FIP="$(mtd_num_by_name FIP || true)"
MTD_ZLOADER="$(mtd_num_by_name zloader || true)"

[ -n "$MTD_PARENT" ] || fail "not OEM layout: spi0.1 parent MTD missing"
[ -n "$MTD_UBI" ] || fail "not OEM layout: MTD named ubi missing"
[ -n "$MTD_UBI2" ] || fail "not OEM layout: MTD named ubi2 missing"
[ -n "$MTD_ZYUBI" ] || fail "not OEM layout: MTD named zyubi missing"
[ -n "$MTD_FIP" ] || fail "not OEM layout: MTD named FIP/fip missing"
[ -n "$MTD_ZLOADER" ] || fail "not OEM layout: MTD named zloader missing"

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

inspect_fip_for_switch "$MTD_FIP"

inspect_zloader_for_switch "$MTD_ZLOADER"

if [ "$TARGET_MTD" = "$MTD_ZYUBI" ]; then
	fail "refusing to touch zyubi"
fi

if [ "$TARGET_MTD" = "$ACTIVE_MTD" ]; then
	fail "target equals active slot"
fi

echo "Active root: $ROOTUBI"
echo "Active MTD: mtd$ACTIVE_MTD"
echo "Active UBI: $ACTIVE_UBI"
echo "Target slot: $TARGET_NAME"
echo "Target MTD: mtd$TARGET_MTD"
echo "FIP MTD: mtd$MTD_FIP"
echo "Zloader MTD: mtd$MTD_ZLOADER"
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
	grep -q "ubi_oem" "$KERNEL" 2>/dev/null || \
		fail "image is not label-swap patched for ubi2 target"
else
	if grep -q "ubi_oem" "$KERNEL" 2>/dev/null; then
		fail "label-swap image is not suitable for flashing physical ubi target"
	fi
fi

KERNEL_SIZE="$(wc -c < "$KERNEL")"
ROOT_SIZE="$(wc -c < "$ROOT")"

echo "Kernel size: $KERNEL_SIZE"
echo "Root size:   $ROOT_SIZE"

TARGET_UBI="$(find_ubi_by_mtdnum "$TARGET_MTD" || true)"

if [ -z "$TARGET_UBI" ]; then
	echo "Attaching target mtd$TARGET_MTD"
	ubiattach -p "/dev/mtd$TARGET_MTD" >/dev/null
	sleep 1
	TARGET_UBI="$(find_ubi_by_mtdnum "$TARGET_MTD" || true)"
fi

[ -n "$TARGET_UBI" ] || fail "could not attach target UBI"

echo "Target UBI: $TARGET_UBI"

LEB_SIZE="$(get_leb_size "$TARGET_UBI")"
[ -n "$LEB_SIZE" ] || fail "could not determine LEB size"

KERNEL_VOL_SIZE="$(round_up_leb_size "$KERNEL_SIZE" "$LEB_SIZE")"
ROOTFS_VOL_SIZE="$(round_up_leb_size "$ROOT_SIZE" "$LEB_SIZE")"

echo "LEB size:          $LEB_SIZE"
echo "Kernel vol size:   $KERNEL_VOL_SIZE"
echo "Rootfs vol size:   $ROOTFS_VOL_SIZE"

ACTIVE_ZYFW="$(ubi_vol_dev_by_name "$ACTIVE_UBI" zyfwinfo || true)"
ACTIVE_ZYDEFAULT="$(ubi_vol_dev_by_name "$ACTIVE_UBI" zydefault || true)"

[ -n "$ACTIVE_ZYFW" ] || fail "active zyfwinfo volume not found"
[ -n "$ACTIVE_ZYDEFAULT" ] || fail "active zydefault volume not found"

echo "Active zyfwinfo: $ACTIVE_ZYFW"
echo "Active zydefault: $ACTIVE_ZYDEFAULT"

ACTIVE_SEQ="$(dd if="$ACTIVE_ZYFW" bs=1 skip=6 count=1 2>/dev/null | hexdump -v -e '1/1 "%u"')"
[ -n "$ACTIVE_SEQ" ] || fail "could not read active zyfwinfo sequence"

NEWSEQ=$((ACTIVE_SEQ + 1))
[ "$NEWSEQ" -le 255 ] || fail "zyfwinfo sequence overflow"

echo "Active zyfwinfo sequence: $ACTIVE_SEQ"
echo "Target zyfwinfo sequence: $NEWSEQ"

echo "Preparing inactive slot"

if command -v ubiblock >/dev/null 2>&1; then
	for b in /dev/ubiblock*; do
		[ -e "$b" ] || continue
		ubiblock -r "$b" >/dev/null 2>&1 || true
	done
fi

for v in rootfs_data zydefault zyfwinfo rootfs kernel; do
	ubirmvol "$TARGET_UBI" -N "$v" >/dev/null 2>&1 || true
done

ubimkvol "$TARGET_UBI" -n 0 -N kernel -s "$KERNEL_VOL_SIZE" >/dev/null
ubimkvol "$TARGET_UBI" -n 1 -N rootfs -s "$ROOTFS_VOL_SIZE" >/dev/null
ubimkvol "$TARGET_UBI" -n 2 -N zyfwinfo -s "$LEB_SIZE" >/dev/null
ubimkvol "$TARGET_UBI" -n 3 -N zydefault -s "$LEB_SIZE" >/dev/null
ubimkvol "$TARGET_UBI" -n 4 -N rootfs_data -m >/dev/null

TARGET_KERNEL="$(ubi_vol_dev_by_name "$TARGET_UBI" kernel || true)"
TARGET_ROOTFS="$(ubi_vol_dev_by_name "$TARGET_UBI" rootfs || true)"
TARGET_ZYFW="$(ubi_vol_dev_by_name "$TARGET_UBI" zyfwinfo || true)"
TARGET_ZYDEFAULT="$(ubi_vol_dev_by_name "$TARGET_UBI" zydefault || true)"

[ -n "$TARGET_KERNEL" ] || fail "target kernel volume not found"
[ -n "$TARGET_ROOTFS" ] || fail "target rootfs volume not found"
[ -n "$TARGET_ZYFW" ] || fail "target zyfwinfo volume not found"
[ -n "$TARGET_ZYDEFAULT" ] || fail "target zydefault volume not found"

echo "Target kernel:    $TARGET_KERNEL"
echo "Target rootfs:    $TARGET_ROOTFS"
echo "Target zyfwinfo:  $TARGET_ZYFW"
echo "Target zydefault: $TARGET_ZYDEFAULT"

echo "Writing firmware"

ubiupdatevol "$TARGET_KERNEL" "$KERNEL" >/dev/null
ubiupdatevol "$TARGET_ROOTFS" "$ROOT" >/dev/null

echo "Creating target zyfwinfo"

case "$ZYFWINFO_MODE" in
	minimal)
		CHECKSUM="$(make_minimal_zyfwinfo /tmp/matrix_zyfwinfo.bin "$NEWSEQ")"
		;;
	copy_oem)
		CHECKSUM="$(make_copy_oem_zyfwinfo "$ACTIVE_ZYFW" /tmp/matrix_zyfwinfo.bin "$NEWSEQ")"
		;;
	rich|copy_oem_rich)
		CHECKSUM="$(make_rich_zyfwinfo "$ACTIVE_ZYFW" /tmp/matrix_zyfwinfo.bin "$NEWSEQ" "$TARGET_ROOTFS" "$LEB_SIZE")"
		;;
	*)
		fail "unsupported ZYFWINFO_MODE=$ZYFWINFO_MODE; use rich, minimal, or copy_oem"
		;;
esac

echo "Generated zyfwinfo checksum: 0x$(printf '%04x' "$CHECKSUM")"
verify_zyfwinfo_file /tmp/matrix_zyfwinfo.bin "$NEWSEQ" "Generated zyfwinfo"

echo "Writing target zyfwinfo"
ubiupdatevol "$TARGET_ZYFW" /tmp/matrix_zyfwinfo.bin >/dev/null || \
	fail "could not write target zyfwinfo"

sync
sleep 1

echo "Verifying target zyfwinfo readback"
dd if="$TARGET_ZYFW" of=/tmp/matrix_zyfwinfo_readback.bin bs=1024 count=1 >/dev/null 2>&1 || \
	fail "could not read target zyfwinfo"

verify_zyfwinfo_file /tmp/matrix_zyfwinfo_readback.bin "$NEWSEQ" "Target zyfwinfo readback"

echo "Copying active zydefault to target"
dd if="$ACTIVE_ZYDEFAULT" of=/tmp/matrix_zydefault.bin bs=128K 2>/dev/null || \
	fail "could not read active zydefault"

ubiupdatevol "$TARGET_ZYDEFAULT" /tmp/matrix_zydefault.bin >/dev/null || \
	fail "could not write target zydefault"

sync
sleep 1

echo "Final target zyfwinfo check after zydefault write"
dd if="$TARGET_ZYFW" of=/tmp/matrix_zyfwinfo_final.bin bs=1024 count=1 >/dev/null 2>&1 || \
	fail "could not read final target zyfwinfo"

verify_zyfwinfo_file /tmp/matrix_zyfwinfo_final.bin "$NEWSEQ" "Final target zyfwinfo"

sync
sync

echo ""
echo "=============================================="
echo "Flash complete."
echo "Boot switch method: rich zyfwinfo sequence + zloader compatibility"
echo "No sys atsw was used."
echo "Current root: $ROOTUBI"
echo "Next target slot: $TARGET_NAME"
echo "Target MTD: mtd$TARGET_MTD"
echo "zyfwinfo sequence: $ACTIVE_SEQ -> $NEWSEQ"
echo "zyfwinfo mode: $ZYFWINFO_MODE"
echo "zyfwinfo checksum: 0x$(printf '%04x' "$CHECKSUM")"
echo "fip action: $FIP_ACTION"
echo "fip current sha: $FIP_CURRENT_SHA"
echo "fip target sha:  $FIP_TARGET_SHA"
echo "zloader action: $ZLOADER_ACTION"
echo "zloader before: $ZLOADER_CURRENT_STRING"
echo "zloader current sha: $ZLOADER_CURRENT_SHA"
echo "zloader target sha:  $ZLOADER_TARGET_SHA"
echo "=============================================="

if [ "$NO_REBOOT" = "1" ]; then
	echo "NO_REBOOT=1 set. Not rebooting."
	echo "For V3 test, do not run sys atsh/sys seqnum before reboot."
	echo "FIP planned action was: $FIP_ACTION"
	echo "Zloader planned action was: $ZLOADER_ACTION"
	echo "FIP replacement is NOT applied when NO_REBOOT=1."
	echo "Zloader replacement is NOT applied when NO_REBOOT=1."
	echo "Raw check command:"
	echo "dd if=$TARGET_ZYFW of=/tmp/final_zyfwinfo_check.bin bs=1024 count=1 2>/dev/null; hexdump -C /tmp/final_zyfwinfo_check.bin"
	exit 0
fi

apply_fip_switch_if_needed "$MTD_FIP"
apply_zloader_switch_if_needed "$MTD_ZLOADER"
sync

echo "Rebooting in 3 seconds."
sleep 3
reboot