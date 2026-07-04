#!/bin/sh
# Matrix EX5601-T0 ubootmod initramfs stager - UNIVERSAL VERSION 3
# Works on firmware 3.x / 4.x / 5.x stock layout.
# written by majad qureshi at lut .fi
# Modified for universal boot switching and no-UART diagnosis.
#
# Normal staging:
#   /tmp/matrix_boot_initramfs.sh
#
# Stage without reboot:
#   NO_REBOOT=1 /tmp/matrix_boot_initramfs.sh
#
# Read-only no-UART diagnosis:
#   /tmp/matrix_boot_initramfs.sh --diagnose
#
# Optional custom initramfs path:
#   INITRAMFS=/tmp/initramfs.bin /tmp/matrix_boot_initramfs.sh

set -u

ACTION="${1:-stage}"

case "$ACTION" in
	stage|--stage|"")
		ACTION="stage"
		;;
	diagnose|--diagnose|check|--check)
		ACTION="diagnose"
		;;
	*)
		echo "Usage: $0 [stage|--stage|diagnose|--diagnose]" >&2
		exit 1
		;;
esac

INITRAMFS="${INITRAMFS:-/tmp/initramfs.bin}"

if [ "$ACTION" = "diagnose" ]; then
	LOG="${LOG:-/tmp/matrix_boot_initramfs_diagnose.log}"
else
	LOG="${LOG:-/tmp/matrix_boot_initramfs.log}"
fi

WORK="/tmp/matrix-initramfs-stage"
LOCK="/tmp/matrix-initramfs-stage.lock"
NO_REBOOT="${NO_REBOOT:-0}"


ZYFWINFO_MODE="${ZYFWINFO_MODE:-rich}"


ZLOADER_FIX="${ZLOADER_FIX:-1}"
OLD_ZLOADER_PATH="${OLD_ZLOADER_PATH:-/tmp/zl34.bin}"
OLD_ZLOADER_MATCH="${OLD_ZLOADER_MATCH:-zld-2.4}"
ZLOADER_ACTION="unknown"
ZLOADER_CURRENT_STRING=""
ZLOADER_CURRENT_HASH=""
ZLOADER_TARGET_HASH=""

FIP_FIX="${FIP_FIX:-1}"
FIP_PATH="${FIP_PATH:-/tmp/fip.bin}"
FIP_ACTION="unknown"
FIP_CURRENT_STRING=""
FIP_CURRENT_HASH=""
FIP_TARGET_STRING=""
FIP_TARGET_HASH=""

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

file_sha256() {
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

		if [ "$n" = "$want" ]; then
			echo "/dev/$(basename "$u")"
			return 0
		fi
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

write_byte() {
	local file="$1"
	local off="$2"
	local val="$3"
	local oct

	[ "$val" -ge 0 ] && [ "$val" -le 255 ] || fail "byte out of range: $val"

	oct="$(printf '%03o' "$val")"
	printf "\\$oct" | dd of="$file" bs=1 seek="$off" conv=notrunc 2>/dev/null
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

	write_byte "$file" "$offset" "$b0"
	write_byte "$file" $((offset + 1)) "$b1"
	write_byte "$file" $((offset + 2)) "$b2"
	write_byte "$file" $((offset + 3)) "$b3"
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

calc_rootfs_load_size_for_zyfwinfo() {
	local rootfs="$1"
	local magic bytes_used load_size data_bytes sysname

	magic="$(dd if="$rootfs" bs=4 count=1 2>/dev/null | hexdump -v -e '1/1 "%02x"')"

	case "$magic" in
		68737173)
			# Squashfs magic "hsqs". ACEA zloader uses bytes_used rounded to 4 KiB.
			bytes_used="$(read_le32_dec "$rootfs" 40)"
			load_size="$(round_up_4k_size "$bytes_used")"
			printf "Target rootfs squashfs bytes_used=0x%08x load_size=0x%08x\n" "$bytes_used" "$load_size" >&2
			echo "$load_size"
			;;
		00000000)

			#  the old zloader workaround this field is not used .
			printf "Target rootfs placeholder detected; rich zyfwinfo rootfs load size set to 0x00000000\n" >&2
			echo 0
			;;
		*)
			# Fallback for unusual images: use UBI data_bytes if available, rounded to 4 KiB.
			sysname="${rootfs#/dev/}"
			data_bytes=""
			[ -f "/sys/class/ubi/$sysname/data_bytes" ] && data_bytes="$(cat "/sys/class/ubi/$sysname/data_bytes" 2>/dev/null || true)"
			[ -n "$data_bytes" ] || fail "target rootfs is not squashfs/empty and data_bytes is unavailable; magic=$magic"
			load_size="$(round_up_4k_size "$data_bytes")"
			printf "WARNING: target rootfs magic=%s; using UBI data_bytes load_size=0x%08x\n" "$magic" "$load_size" >&2
			echo "$load_size"
			;;
	esac
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

	write_byte "$file" 254 "$lo"
	write_byte "$file" 255 "$hi"

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

	say "$label first 1 KiB:"
	dd if="$file" bs=1024 count=1 2>/dev/null | hexdump -C
	say "$label sequence: $seq"
	say "$label format byte04: $byte04"
	say "$label format byte09: $byte09"
	say "$label rootfs load size field 0x78: 0x$(printf '%08x' "$rootfs_load_size")"
	say "$label checksum calculated: 0x$(printf '%04x' "$calc")"
	say "$label checksum stored:     0x$(printf '%04x' "$stored")"

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
	write_byte "$file" 0 69
	write_byte "$file" 1 88
	write_byte "$file" 2 89
	write_byte "$file" 3 90

	# Minimal OpenWrt-compatible fields.
	write_byte "$file" 4 2
	write_byte "$file" 6 "$seq"
	write_byte "$file" 9 1

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


	write_byte "$file" 4 3
	write_byte "$file" 9 4
	say "Forced zyfwinfo rich markers: byte04=3 byte09=4"

	# Sequence controls which bank zloader selects.
	write_byte "$file" 6 "$seq"


	rootfs_load_size="$(calc_rootfs_load_size_for_zyfwinfo "$target_rootfs")"
	write_le32_dec "$file" 120 "$rootfs_load_size"

	printf "Target rootfs load size for rich zyfwinfo: 0x%08x\n" "$rootfs_load_size" >&2

	# Recalculate first-0x100 zyfwinfo checksum.
	write_byte "$file" 254 0
	write_byte "$file" 255 0
	checksum="$(write_zyfwinfo_checksum "$file")"
	echo "$checksum"
}

inspect_zloader_for_switch() {
	local zld_mtd="$1"
	local current_file="$WORK/zloader.current.bin"
	local target_file="$OLD_ZLOADER_PATH"
	local target_size target_string

	ZLOADER_ACTION="keep"
	ZLOADER_CURRENT_STRING="unknown"
	ZLOADER_CURRENT_HASH=""
	ZLOADER_TARGET_HASH=""

	[ "$ZLOADER_FIX" = "1" ] || {
		ZLOADER_ACTION="disabled"
		say "ZLOADER_FIX=0; zloader replacement disabled."
		return 0
	}

	[ -f "$target_file" ] || fail "zloader replacement missing: $target_file"

	target_size="$(wc -c < "$target_file" | awk '{print $1}')"
	[ "$target_size" -gt 4096 ] || fail "zloader replacement looks too small: $target_file"
	[ "$target_size" -le 262144 ] || fail "zloader replacement is larger than 256 KiB partition: $target_size"

	dd if="/dev/mtd$zld_mtd" of="$current_file" bs="$target_size" count=1 >/dev/null 2>&1 || \
		fail "could not read current zloader from /dev/mtd$zld_mtd"

	ZLOADER_CURRENT_HASH="$(file_sha256 "$current_file")"
	ZLOADER_TARGET_HASH="$(file_sha256 "$target_file")"

	ZLOADER_CURRENT_STRING="$(strings "$current_file" | grep -E 'zld-[0-9]' | head -n1 || true)"
	[ -n "$ZLOADER_CURRENT_STRING" ] || ZLOADER_CURRENT_STRING="unknown"

	target_string="$(strings "$target_file" | grep -E 'zld-[0-9]' | head -n1 || true)"
	[ -n "$target_string" ] || fail "could not identify zloader string in $target_file"

	say "Current zloader:     $ZLOADER_CURRENT_STRING"
	say "Current zloader sha: $ZLOADER_CURRENT_HASH"
	say "Target zloader:      $target_string"
	say "Target zloader sha:  $ZLOADER_TARGET_HASH"

	# Keep this string sanity check because writing a bad zloader is fatal on no-UART devices.
	echo "$target_string" | grep -q "$OLD_ZLOADER_MATCH" || \
		fail "$target_file does not look like expected old zloader ($OLD_ZLOADER_MATCH)"

	if [ "$ZLOADER_CURRENT_HASH" = "$ZLOADER_TARGET_HASH" ]; then
		ZLOADER_ACTION="keep"
		say "Current zloader already matches $target_file; no zloader replacement needed."
	else
		ZLOADER_ACTION="replace"
		say "Current zloader hash differs from $target_file; will replace zloader before reboot."
	fi
}

apply_zloader_switch_if_needed() {
	local zld_mtd="$1"
	local zld_size check_file ro

	[ "$ZLOADER_FIX" = "1" ] || {
		say "ZLOADER_FIX=0; not replacing zloader."
		return 0
	}

	[ "$ZLOADER_ACTION" = "replace" ] || {
		say "Zloader replacement not needed."
		return 0
	}

	say "Backing up current zloader to $WORK/zloader.before_replace.bin"
	dd if="/dev/mtd$zld_mtd" of="$WORK/zloader.before_replace.bin" bs=256K count=1 >/dev/null 2>&1 || \
		fail "could not backup current zloader"

	if [ -f "/sys/class/mtd/mtd$zld_mtd/ro" ]; then
		ro="$(cat "/sys/class/mtd/mtd$zld_mtd/ro" 2>/dev/null || echo 0)"
		if [ "$ro" != "0" ]; then
			say "zloader MTD is read-only; trying /tmp/mtd-rw.ko"
			insmod /tmp/mtd-rw.ko i_want_a_brick=1 2>/dev/null || true
			ro="$(cat "/sys/class/mtd/mtd$zld_mtd/ro" 2>/dev/null || echo 1)"
			[ "$ro" = "0" ] || fail "zloader MTD is still read-only"
		fi
	fi

	say "Writing old zloader from $OLD_ZLOADER_PATH to /dev/mtd$zld_mtd"
	mtd write "$OLD_ZLOADER_PATH" "/dev/mtd$zld_mtd" >/dev/null || \
		fail "could not write old zloader"
	sync

	zld_size="$(wc -c < "$OLD_ZLOADER_PATH" | awk '{print $1}')"
	check_file="$WORK/zloader.after_replace.bin"
	dd if="/dev/mtd$zld_mtd" of="$check_file" bs="$zld_size" count=1 >/dev/null 2>&1 || \
		fail "could not read back replaced zloader"

	cmp "$OLD_ZLOADER_PATH" "$check_file" >/dev/null || fail "old zloader readback mismatch"
	say "OLD_ZLOADER_WRITE_OK"
	strings "$check_file" | grep -E 'zld-[0-9]' | head -n1 || true
}

inspect_fip_for_switch() {
	local fip_mtd="$1"
	local current_file="$WORK/fip.current.bin"
	local target_file="$FIP_PATH"
	local target_size

	FIP_ACTION="keep"
	FIP_CURRENT_STRING="unknown"
	FIP_TARGET_STRING="unknown"
	FIP_CURRENT_HASH=""
	FIP_TARGET_HASH=""

	[ "$FIP_FIX" = "1" ] || {
		FIP_ACTION="disabled"
		say "FIP_FIX=0; FIP replacement disabled."
		return 0
	}

	if [ ! -f "$target_file" ]; then
		FIP_ACTION="missing"
		say "WARNING: FIP replacement missing: $target_file"
		say "WARNING: continuing without FIP replacement."
		return 0
	fi

	target_size="$(wc -c < "$target_file" | awk '{print $1}')"
	if [ "$target_size" -le 1048576 ]; then
		FIP_ACTION="invalid"
		say "WARNING: FIP replacement looks too small: $target_file ($target_size bytes)"
		say "WARNING: continuing without FIP replacement."
		return 0
	fi
	if [ "$target_size" -gt 2097152 ]; then
		FIP_ACTION="invalid"
		say "WARNING: FIP replacement is larger than expected 2 MiB partition: $target_size"
		say "WARNING: continuing without FIP replacement."
		return 0
	fi

	dd if="/dev/mtd$fip_mtd" of="$current_file" bs="$target_size" count=1 >/dev/null 2>&1 || {
		FIP_ACTION="read_failed"
		say "WARNING: could not read current FIP from /dev/mtd$fip_mtd"
		say "WARNING: continuing without FIP replacement."
		return 0
	}

	FIP_CURRENT_HASH="$(file_sha256 "$current_file")"
	FIP_TARGET_HASH="$(file_sha256 "$target_file")"

	FIP_CURRENT_STRING="$(strings "$current_file" | grep -Ei 'U-Boot 20|v2\\.6\\(release\\)|Built :' | head -n1 || true)"
	[ -n "$FIP_CURRENT_STRING" ] || FIP_CURRENT_STRING="unknown"
	FIP_TARGET_STRING="$(strings "$target_file" | grep -Ei 'U-Boot 20|v2\\.6\\(release\\)|Built :' | head -n1 || true)"
	[ -n "$FIP_TARGET_STRING" ] || FIP_TARGET_STRING="unknown"

	say "Current FIP hint:     $FIP_CURRENT_STRING"
	say "Current FIP sha:      $FIP_CURRENT_HASH"
	say "Target FIP hint:      $FIP_TARGET_STRING"
	say "Target FIP sha:       $FIP_TARGET_HASH"

	if [ "$FIP_CURRENT_HASH" = "$FIP_TARGET_HASH" ]; then
		FIP_ACTION="keep"
		say "Current FIP already matches $target_file; no FIP replacement needed."
	else
		FIP_ACTION="replace"
		say "Current FIP hash differs from $target_file; will try to replace FIP before reboot."
		say "If FIP replacement fails cleanly, the script will continue."
	fi
}

apply_fip_switch_if_needed() {
	local fip_mtd="$1"
	local target_size check_file before_file after_fail_file ro

	[ "$FIP_FIX" = "1" ] || {
		say "FIP_FIX=0; not replacing FIP."
		return 0
	}

	[ "$FIP_ACTION" = "replace" ] || {
		say "FIP replacement not needed. action=$FIP_ACTION"
		return 0
	}

	target_size="$(wc -c < "$FIP_PATH" | awk '{print $1}')"
	before_file="$WORK/fip.before_replace.bin"
	check_file="$WORK/fip.after_replace.bin"
	after_fail_file="$WORK/fip.after_failed_replace.bin"

	say "Backing up current FIP exact replacement-size region to $before_file"
	dd if="/dev/mtd$fip_mtd" of="$before_file" bs="$target_size" count=1 >/dev/null 2>&1 || {
		say "WARNING: could not backup current FIP; skipping FIP replacement."
		FIP_ACTION="backup_failed"
		return 0
	}

	if [ -f "/sys/class/mtd/mtd$fip_mtd/ro" ]; then
		ro="$(cat "/sys/class/mtd/mtd$fip_mtd/ro" 2>/dev/null || echo 0)"
		if [ "$ro" != "0" ]; then
			say "FIP MTD is read-only; trying /tmp/mtd-rw.ko"
			insmod /tmp/mtd-rw.ko i_want_a_brick=1 2>/dev/null || true
		fi
	fi

	say "Trying to write FIP from $FIP_PATH to /dev/mtd$fip_mtd"
	if ! mtd write "$FIP_PATH" "/dev/mtd$fip_mtd" >/dev/null 2>&1; then
		say "WARNING: FIP write command failed. Checking whether current FIP stayed unchanged."
		dd if="/dev/mtd$fip_mtd" of="$after_fail_file" bs="$target_size" count=1 >/dev/null 2>&1 || \
			fail "FIP write failed and FIP readback also failed; refusing to continue"
		if cmp "$before_file" "$after_fail_file" >/dev/null; then
			say "FIP unchanged after failed write; continuing without FIP replacement."
			FIP_ACTION="write_failed_unchanged"
			return 0
		fi
		fail "FIP changed during failed write; refusing to continue"
	fi

	sync

	dd if="/dev/mtd$fip_mtd" of="$check_file" bs="$target_size" count=1 >/dev/null 2>&1 || \
		fail "FIP write reported success but readback failed"

	if cmp "$FIP_PATH" "$check_file" >/dev/null; then
		say "FIP_WRITE_OK"
		FIP_ACTION="replaced"
		return 0
	fi

	fail "FIP write reported success but readback mismatch; refusing to reboot"
}

inspect_initramfs_strings() {
	say "[2b] Inspecting initramfs strings"

	if command -v strings >/dev/null 2>&1; then
		say "Interesting initramfs strings:"
		strings "$INITRAMFS" | grep -Ei 'ubootmod|stock|labelswap|bootargs|rootubi|ubi_oem|EX5601|OpenWrt|Linux' | head -n 80 || true

		if strings "$INITRAMFS" | grep -qi 'ubootmod'; then
			say "WARNING: initramfs contains 'ubootmod'."
			say "WARNING: stock Zyxel zloader may fail with: bootargs in fdt not found"
		fi

		if strings "$INITRAMFS" | grep -qiE 'stock|labelswap|ubi_oem'; then
			say "INITRAMFS_LAYOUT_HINT=stock_or_labelswap"
		else
			say "WARNING: initramfs does not show stock/labelswap/ubi_oem strings."
			say "WARNING: this may still boot, but without UART it is harder to confirm."
		fi
	else
		say "WARNING: strings command not found; skipping initramfs string diagnosis"
	fi
}

diagnose_dump_zyfwinfo() {
	local label="$1"
	local dev="$2"
	local out="$WORK/diagnose_${label}_zyfwinfo.bin"
	local seq calc stored

	say ""
	say "===== $label zyfwinfo ====="
	say "device=$dev"

	dd if="$dev" of="$out" bs=256 count=1 >/dev/null 2>&1 || {
		say "ERROR: could not read $label zyfwinfo from $dev"
		return 1
	}

	hexdump -C "$out"

	seq="$(read_byte_dec "$out" 6)"
	calc="$(calc_zyfwinfo_checksum "$out")"
	stored="$(read_zyfwinfo_stored_checksum "$out")"

	say "${label}_SEQ=$seq"
	say "${label}_CHECKSUM_CALC=0x$(printf '%04x' "$calc")"
	say "${label}_CHECKSUM_STORED=0x$(printf '%04x' "$stored")"

	if [ "$calc" = "$stored" ]; then
		say "${label}_CHECKSUM=OK"
	else
		say "${label}_CHECKSUM=BAD"
	fi

	echo "$seq" > "$WORK/diagnose_${label}_seq.txt"
	echo "$calc" > "$WORK/diagnose_${label}_calc.txt"
	echo "$stored" > "$WORK/diagnose_${label}_stored.txt"
}

diagnose_kernel_volume() {
	local dev="$1"
	local target_name="$2"
	local sample="$WORK/diagnose_target_kernel_sample.bin"
	local magic

	say ""
	say "===== target kernel/FIT diagnosis ====="
	say "device=$dev"

	# Read up to 16 MiB, enough for typical initramfs FITs and DTB strings.
	dd if="$dev" of="$sample" bs=512K count=32 >/dev/null 2>&1 || {
		say "ERROR: could not read target kernel volume"
		return 1
	}

	magic="$(dd if="$sample" bs=4 count=1 2>/dev/null | hexdump -v -e '4/1 "%02x"')"
	say "FIT_MAGIC=$magic"

	if [ "$magic" = "d00dfeed" ]; then
		say "FIT_MAGIC_CHECK=OK"
	else
		say "FIT_MAGIC_CHECK=BAD"
	fi

	if command -v strings >/dev/null 2>&1; then
		say ""
		say "Interesting strings from target kernel:"
		strings "$sample" | grep -Ei 'ubootmod|stock|labelswap|bootargs|rootubi|ubi_oem|EX5601|OpenWrt|Linux' | head -n 100 || true
	else
		say "WARNING: strings command not found; skipping target kernel string diagnosis"
	fi

	if grep -aq 'ubootmod' "$sample"; then
		say "WARNING: target image contains 'ubootmod'."
		say "WARNING: stock Zyxel zloader may fail with: bootargs in fdt not found"
	fi

	if [ "$target_name" = "ubi2" ]; then
		if grep -aqE 'labelswap|ubi_oem' "$sample"; then
			say "LABELSWAP_CHECK=probably OK for physical ubi2 target"
		else
			say "WARNING: target is physical ubi2, but image does not show labelswap/ubi_oem string"
		fi
	fi
}

diagnose_no_uart() {
	local CMDLINE ROOTUBI
	local MTD_PARENT MTD_UBI MTD_UBI2 MTD_ZYUBI
	local ACTIVE_MTD TARGET_MTD TARGET_NAME
	local ACTIVE_UBI TARGET_UBI
	local ACTIVE_ZYFW TARGET_ZYFW TARGET_KERNEL TARGET_ROOTFS TARGET_ZYDEFAULT
	local ACTIVE_SEQ TARGET_SEQ TARGET_CALC TARGET_STORED MAGIC

	say "=== Matrix EX5601-T0 no-UART diagnosis ==="
	say "READ-ONLY MODE"
	say "No formatting, no writing, no sys atsw, no sys seqnum, no sys atsh."
	say "LOG=$LOG"
	say ""

	need_cmd awk
	need_cmd cat
	need_cmd dd
	need_cmd grep
	need_cmd hexdump
	need_cmd mkdir
	need_cmd sleep
	need_cmd ubiattach
	need_cmd ubinfo

	rm -rf "$WORK/diagnose"
	mkdir -p "$WORK"

	say "===== date ====="
	date 2>/dev/null || true

	say ""
	say "===== /proc/cmdline ====="
	[ -r /proc/cmdline ] || fail "/proc/cmdline missing"
	cat /proc/cmdline

	say ""
	say "===== /proc/mtd ====="
	[ -r /proc/mtd ] || fail "/proc/mtd missing"
	cat /proc/mtd

	CMDLINE="$(cat /proc/cmdline)"
	ROOTUBI="$(awk '{
		for (i = 1; i <= NF; i++) {
			if ($i ~ /^rootubi=/) {
				sub(/^rootubi=/, "", $i)
				print $i
				exit
			}
		}
	}' /proc/cmdline)"

	MTD_PARENT="$(mtd_num_by_name spi0.1 || true)"
	MTD_UBI="$(mtd_num_by_name ubi || true)"
	MTD_UBI2="$(mtd_num_by_name ubi2 || true)"
	MTD_ZYUBI="$(mtd_num_by_name zyubi || true)"

	[ -n "$MTD_PARENT" ] || fail "parent mtd named spi0.1 missing"
	[ -n "$MTD_UBI" ] || fail "mtd named ubi missing"
	[ -n "$MTD_UBI2" ] || fail "mtd named ubi2 missing"
	[ -n "$MTD_ZYUBI" ] || fail "mtd named zyubi missing"

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

	say ""
	say "===== bank decision ====="
	say "ROOTUBI=$ROOTUBI"
	say "MTD_PARENT=mtd$MTD_PARENT"
	say "MTD_UBI=mtd$MTD_UBI"
	say "MTD_UBI2=mtd$MTD_UBI2"
	say "MTD_ZYUBI=mtd$MTD_ZYUBI"
	say "ACTIVE_MTD=mtd$ACTIVE_MTD"
	say "TARGET_MTD=mtd$TARGET_MTD"
	say "TARGET_NAME=$TARGET_NAME"

	ACTIVE_UBI="$(attach_mtd "$ACTIVE_MTD")"
	TARGET_UBI="$(attach_mtd "$TARGET_MTD")"

	say "ACTIVE_UBI=$ACTIVE_UBI"
	say "TARGET_UBI=$TARGET_UBI"

	say ""
	say "===== ubinfo -a ====="
	ubinfo -a 2>&1 || true

	ACTIVE_ZYFW="$(ubi_vol_dev_by_name "$ACTIVE_UBI" zyfwinfo || true)"
	TARGET_ZYFW="$(ubi_vol_dev_by_name "$TARGET_UBI" zyfwinfo || true)"
	TARGET_KERNEL="$(ubi_vol_dev_by_name "$TARGET_UBI" kernel || true)"
	TARGET_ROOTFS="$(ubi_vol_dev_by_name "$TARGET_UBI" rootfs || true)"
	TARGET_ZYDEFAULT="$(ubi_vol_dev_by_name "$TARGET_UBI" zydefault || true)"

	[ -n "$ACTIVE_ZYFW" ] || fail "active zyfwinfo not found"
	[ -n "$TARGET_ZYFW" ] || fail "target zyfwinfo not found"
	[ -n "$TARGET_KERNEL" ] || fail "target kernel not found"
	[ -n "$TARGET_ROOTFS" ] || fail "target rootfs not found"

	say ""
	say "===== target volume devices ====="
	say "TARGET_KERNEL=$TARGET_KERNEL"
	say "TARGET_ROOTFS=$TARGET_ROOTFS"
	say "TARGET_ZYFW=$TARGET_ZYFW"
	say "TARGET_ZYDEFAULT=${TARGET_ZYDEFAULT:-missing}"

	diagnose_dump_zyfwinfo active "$ACTIVE_ZYFW"
	diagnose_dump_zyfwinfo target "$TARGET_ZYFW"

	ACTIVE_SEQ="$(cat "$WORK/diagnose_active_seq.txt")"
	TARGET_SEQ="$(cat "$WORK/diagnose_target_seq.txt")"
	TARGET_CALC="$(cat "$WORK/diagnose_target_calc.txt")"
	TARGET_STORED="$(cat "$WORK/diagnose_target_stored.txt")"

	say ""
	say "===== boot switch condition ====="

	if [ "$TARGET_CALC" = "$TARGET_STORED" ]; then
		say "TARGET_ZYFWINFO_CHECKSUM=OK"
	else
		say "TARGET_ZYFWINFO_CHECKSUM=BAD"
	fi

	if [ "$TARGET_SEQ" -gt "$ACTIVE_SEQ" ] 2>/dev/null; then
		say "TARGET_SEQUENCE_HIGHER=OK"
	else
		say "TARGET_SEQUENCE_HIGHER=BAD"
	fi

	say "ACTIVE_SEQ=$ACTIVE_SEQ"
	say "TARGET_SEQ=$TARGET_SEQ"

	diagnose_kernel_volume "$TARGET_KERNEL" "$TARGET_NAME"

	say ""
	say "===== optional current initramfs file diagnosis ====="

	if [ -f "$INITRAMFS" ]; then
		say "INITRAMFS=$INITRAMFS exists"
		MAGIC="$(dd if="$INITRAMFS" bs=4 count=1 2>/dev/null | hexdump -v -e '4/1 "%02x"')"
		say "INITRAMFS_FIT_MAGIC=$MAGIC"
		inspect_initramfs_strings
	else
		say "INITRAMFS=$INITRAMFS does not exist; skipping file diagnosis"
	fi

	say ""
	say "===== diagnosis summary ====="

	if [ "$TARGET_CALC" = "$TARGET_STORED" ] && [ "$TARGET_SEQ" -gt "$ACTIVE_SEQ" ] 2>/dev/null; then
		say "ZYFWINFO_SWITCH_CONDITION=OK"
	else
		say "ZYFWINFO_SWITCH_CONDITION=BAD"
	fi

	say "If ZYFWINFO_SWITCH_CONDITION=OK but router still boots OEM, suspect wrong FIT/DTB image."
	say "If target image contains 'ubootmod', stock zloader may stop with: bootargs in fdt not found"
	say "Log saved to: $LOG"
}

cleanup() {
	rm -rf "$LOCK"
}
trap cleanup EXIT

if [ "$ACTION" = "diagnose" ]; then
	diagnose_no_uart
	exit 0
fi

mkdir "$LOCK" 2>/dev/null || fail "another initramfs staging process is running"

say "=== Matrix EX5601-T0 initramfs stager ==="
say "Boot switch method: rich zyfwinfo sequence + optional old zloader workaround"
say "No sys atsw / no sys seqnum / no sys atsh"
say "ZYFWINFO_MODE=$ZYFWINFO_MODE"
say "ZLOADER_FIX=$ZLOADER_FIX"
say "OLD_ZLOADER_PATH=$OLD_ZLOADER_PATH"
say "FIP_FIX=$FIP_FIX"
say "FIP_PATH=$FIP_PATH"
say "NO_REBOOT=$NO_REBOOT"
say "INITRAMFS=$INITRAMFS"
say "LOG=$LOG"

say "[1] Checking commands"

need_cmd awk
need_cmd cat
need_cmd cp
need_cmd dd
need_cmd grep
need_cmd hexdump
need_cmd strings
need_cmd sha256sum
need_cmd mtd
need_cmd cmp
need_cmd sed
need_cmd head
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
inspect_initramfs_strings

say "[3] Checking OEM stock layout"

[ -r /proc/mtd ] || fail "/proc/mtd missing"
[ -r /proc/cmdline ] || fail "/proc/cmdline missing"

MTD_PARENT="$(mtd_num_by_name spi0.1 || true)"
MTD_UBI="$(mtd_num_by_name ubi || true)"
MTD_UBI2="$(mtd_num_by_name ubi2 || true)"
MTD_ZYUBI="$(mtd_num_by_name zyubi || true)"
MTD_ZLOADER="$(mtd_num_by_name zloader || true)"
MTD_FIP="$(mtd_num_by_name FIP || true)"

[ -n "$MTD_PARENT" ] || fail "not OEM stock layout: parent mtd named spi0.1 missing"
[ -n "$MTD_UBI" ] || fail "not OEM stock layout: mtd named ubi missing"
[ -n "$MTD_UBI2" ] || fail "not OEM stock layout: mtd named ubi2 missing"
[ -n "$MTD_ZYUBI" ] || fail "not OEM stock layout: mtd named zyubi missing"
[ -n "$MTD_ZLOADER" ] || fail "not OEM stock layout: mtd named zloader missing"
[ -n "$MTD_FIP" ] || fail "not OEM stock layout: mtd named FIP/fip missing"

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

say "MTD_PARENT=mtd$MTD_PARENT"
say "MTD_UBI=mtd$MTD_UBI"
say "MTD_UBI2=mtd$MTD_UBI2"
say "MTD_ZYUBI=mtd$MTD_ZYUBI"
say "MTD_FIP=mtd$MTD_FIP"
say "MTD_ZLOADER=mtd$MTD_ZLOADER"
say "ACTIVE_MTD=mtd$ACTIVE_MTD"
say "TARGET_MTD=mtd$TARGET_MTD"
say "TARGET_NAME=$TARGET_NAME"

say "[4] Reading active metadata"

ACTIVE_UBI="$(attach_mtd "$ACTIVE_MTD")"
say "ACTIVE_UBI=$ACTIVE_UBI"

ACTIVE_ZYFW="$(ubi_vol_dev_by_name "$ACTIVE_UBI" zyfwinfo || true)"
ACTIVE_ZYDEFAULT="$(ubi_vol_dev_by_name "$ACTIVE_UBI" zydefault || true)"

[ -n "$ACTIVE_ZYFW" ] || fail "active zyfwinfo volume missing"
say "ACTIVE_ZYFW=$ACTIVE_ZYFW"

rm -rf "$WORK"
mkdir -p "$WORK"

inspect_fip_for_switch "$MTD_FIP"
inspect_zloader_for_switch "$MTD_ZLOADER"

dd if="$ACTIVE_ZYFW" of="$WORK/zyfwinfo.active.bin" bs=256 count=1 >/dev/null 2>&1 || \
	fail "could not read active zyfwinfo"

ACTIVE_SEQ="$(read_byte_dec "$WORK/zyfwinfo.active.bin" 6)"
[ -n "$ACTIVE_SEQ" ] || fail "could not read active zyfwinfo sequence"

NEW_SEQ=$((ACTIVE_SEQ + 1))
[ "$NEW_SEQ" -le 255 ] || fail "zyfwinfo sequence overflow"

say "ACTIVE_SEQ=$ACTIVE_SEQ"
say "NEW_SEQ=$NEW_SEQ"

ACTIVE_LEB_SIZE="$(get_leb_size "$ACTIVE_UBI")"
[ -n "$ACTIVE_LEB_SIZE" ] || fail "could not determine active LEB size"

if [ -n "$ACTIVE_ZYDEFAULT" ]; then
	say "ACTIVE_ZYDEFAULT=$ACTIVE_ZYDEFAULT"
	dd if="$ACTIVE_ZYDEFAULT" of="$WORK/zydefault.active.bin" bs="$ACTIVE_LEB_SIZE" count=1 >/dev/null 2>&1 || \
		fail "could not read active zydefault"
else
	say "WARNING: active zydefault volume not found; will write empty zydefault"
fi

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
ZYDEFAULT_VOL_SIZE="$LEB_SIZE"

say "LEB_SIZE=$LEB_SIZE"
say "KERNEL_VOL_SIZE=$KERNEL_VOL_SIZE"

say "[6] Creating temporary boot volumes"

ubimkvol "$TARGET_UBI" -n 0 -N kernel -s "$KERNEL_VOL_SIZE" >/dev/null || \
	fail "could not create kernel volume"

ubimkvol "$TARGET_UBI" -n 1 -N rootfs -s "$ROOTFS_VOL_SIZE" >/dev/null || \
	fail "could not create rootfs volume"

# Rich zyfwinfo needs a full LEB because ACEA zloader reads at least 0x400 bytes.
ubimkvol "$TARGET_UBI" -n 2 -N zyfwinfo -s "$LEB_SIZE" >/dev/null || \
	fail "could not create zyfwinfo volume"

ubimkvol "$TARGET_UBI" -n 3 -N zydefault -s "$ZYDEFAULT_VOL_SIZE" >/dev/null || \
	fail "could not create zydefault volume"

ubimkvol "$TARGET_UBI" -n 4 -N rootfs_data -m >/dev/null || \
	fail "could not create rootfs_data volume"

TARGET_KERNEL="$(ubi_vol_dev_by_name "$TARGET_UBI" kernel || true)"
TARGET_ROOTFS="$(ubi_vol_dev_by_name "$TARGET_UBI" rootfs || true)"
TARGET_ZYFW="$(ubi_vol_dev_by_name "$TARGET_UBI" zyfwinfo || true)"
TARGET_ZYDEFAULT="$(ubi_vol_dev_by_name "$TARGET_UBI" zydefault || true)"

[ -n "$TARGET_KERNEL" ] || fail "target kernel volume not found"
[ -n "$TARGET_ROOTFS" ] || fail "target rootfs volume not found"
[ -n "$TARGET_ZYFW" ] || fail "target zyfwinfo volume not found"
[ -n "$TARGET_ZYDEFAULT" ] || fail "target zydefault volume not found"

say "TARGET_KERNEL=$TARGET_KERNEL"
say "TARGET_ROOTFS=$TARGET_ROOTFS"
say "TARGET_ZYFW=$TARGET_ZYFW"
say "TARGET_ZYDEFAULT=$TARGET_ZYDEFAULT"

say "[7] Writing initramfs FIT"

ubiupdatevol "$TARGET_KERNEL" "$INITRAMFS" >/dev/null || \
	fail "could not write initramfs kernel volume"

dd if=/dev/zero of="$WORK/empty-rootfs.bin" bs="$LEB_SIZE" count=1 >/dev/null 2>&1 || \
	fail "could not create empty rootfs placeholder"

ubiupdatevol "$TARGET_ROOTFS" "$WORK/empty-rootfs.bin" >/dev/null || \
	fail "could not write empty rootfs placeholder"

say "[8] Creating target zyfwinfo"

case "$ZYFWINFO_MODE" in
	minimal)
		CHECKSUM="$(make_minimal_zyfwinfo "$WORK/zyfwinfo.target.bin" "$NEW_SEQ")"
		;;
	rich|copy_oem|copy_oem_rich)
		CHECKSUM="$(make_rich_zyfwinfo "$ACTIVE_ZYFW" "$WORK/zyfwinfo.target.bin" "$NEW_SEQ" "$TARGET_ROOTFS" "$LEB_SIZE")"
		;;
	*)
		fail "unsupported ZYFWINFO_MODE=$ZYFWINFO_MODE; use rich or minimal"
		;;
esac

say "Generated zyfwinfo checksum: 0x$(printf '%04x' "$CHECKSUM")"

verify_zyfwinfo_file "$WORK/zyfwinfo.target.bin" "$NEW_SEQ" "Generated target zyfwinfo"

say "[9] Writing zyfwinfo"

ubiupdatevol "$TARGET_ZYFW" "$WORK/zyfwinfo.target.bin" >/dev/null || \
	fail "could not write target zyfwinfo"

sync
sleep 1

dd if="$TARGET_ZYFW" of="$WORK/zyfwinfo.readback.bin" bs=1024 count=1 >/dev/null 2>&1 || \
	fail "could not read target zyfwinfo"

verify_zyfwinfo_file "$WORK/zyfwinfo.readback.bin" "$NEW_SEQ" "Target zyfwinfo readback"

say "[10] Writing zydefault"

if [ -f "$WORK/zydefault.active.bin" ]; then
	ubiupdatevol "$TARGET_ZYDEFAULT" "$WORK/zydefault.active.bin" >/dev/null || \
		fail "could not write zydefault"
else
	dd if=/dev/zero of="$WORK/zydefault.empty.bin" bs="$LEB_SIZE" count=1 >/dev/null 2>&1
	ubiupdatevol "$TARGET_ZYDEFAULT" "$WORK/zydefault.empty.bin" >/dev/null || \
		fail "could not write empty zydefault"
fi

sync
sleep 1

say "[11] Final zyfwinfo verification after zydefault write"

dd if="$TARGET_ZYFW" of="$WORK/zyfwinfo.final.bin" bs=1024 count=1 >/dev/null 2>&1 || \
	fail "could not read final target zyfwinfo"

verify_zyfwinfo_file "$WORK/zyfwinfo.final.bin" "$NEW_SEQ" "Final target zyfwinfo"

say "[12] Final sync"

sync
sync

say "=============================================="
say "SUCCESS: initramfs staging complete"
say "Temporary initramfs FIT has been written."
say "Boot switch method: rich zyfwinfo sequence + zloader compatibility."
say "No sys atsw was used."
say "No sys seqnum was used."
say "No sys atsh was used."
say "Target bank: mtd$TARGET_MTD / $TARGET_NAME"
say "New zyfwinfo sequence: $ACTIVE_SEQ -> $NEW_SEQ"
say "New zyfwinfo mode: $ZYFWINFO_MODE"
say "New zyfwinfo checksum: 0x$(printf '%04x' "$CHECKSUM")"
say "fip action: $FIP_ACTION"
say "fip current sha: ${FIP_CURRENT_HASH:-unknown}"
say "fip target sha:  ${FIP_TARGET_HASH:-unknown}"
say "zloader action: $ZLOADER_ACTION"
say "zloader before: $ZLOADER_CURRENT_STRING"
say "zloader current sha: ${ZLOADER_CURRENT_HASH:-unknown}"
say "zloader target sha:  ${ZLOADER_TARGET_HASH:-unknown}"
say "No ubootmod NAND conversion was done."
say "Log: $LOG"
say "Please wait for two minutes before accessing router at 192.168.1.1"
say "=============================================="

if [ "$NO_REBOOT" = "1" ]; then
	say "NO_REBOOT=1 set. Not rebooting."
	say "Do not run sys atsh/sys seqnum before reboot."
	say "FIP planned action was: $FIP_ACTION"
	say "Zloader planned action was: $ZLOADER_ACTION"
	say "FIP/zloader replacement is NOT applied when NO_REBOOT=1."
	say "Manual raw check:"
	say "dd if=$TARGET_ZYFW of=/tmp/initramfs_final_zyfwinfo_check.bin bs=1024 count=1 2>/dev/null; hexdump -C /tmp/initramfs_final_zyfwinfo_check.bin"
	say "You can also run read-only diagnosis:"
	say "$0 --diagnose"
	exit 0
fi

apply_fip_switch_if_needed "$MTD_FIP"
apply_zloader_switch_if_needed "$MTD_ZLOADER"
sync

say "Rebooting in 5 seconds..."
sleep 5
reboot -f

exit 0
