#!/usr/bin/env bash
#written by majad.qureshi at lut.fi
set -euo pipefail

SRC_FW="${1:-openwrt.bin}"

OUT_UBI="openwrt_ubi.bin"
OUT_UBI2="openwrt_ubi2.bin"

WORK=".matrix_ex5601_build"

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "ERROR: missing command: $1" >&2
		exit 1
	}
}

need_cmd tar
need_cmd dumpimage
need_cmd mkimage
need_cmd dtc
need_cmd python3
need_cmd sha256sum

[ -f "$SRC_FW" ] || {
	echo "ERROR: missing $SRC_FW" >&2
	exit 1
}

rm -rf "$WORK" "$OUT_UBI" "$OUT_UBI2"
mkdir -p "$WORK/src" "$WORK/parts" "$WORK/out_ubi" "$WORK/out_ubi2" "$WORK/verify"

echo "[1] Extract source sysupgrade image"

tar -xf "$SRC_FW" -C "$WORK/src"

SRC_DIR="$(find "$WORK/src" -mindepth 1 -maxdepth 1 -type d -name 'sysupgrade-*' | head -n1)"
[ -n "$SRC_DIR" ] || {
	echo "ERROR: sysupgrade directory not found inside $SRC_FW" >&2
	exit 1
}

BOARD_DIR="$(basename "$SRC_DIR")"

[ -f "$SRC_DIR/CONTROL" ] || {
	echo "ERROR: CONTROL missing" >&2
	exit 1
}

[ -f "$SRC_DIR/kernel" ] || {
	echo "ERROR: kernel missing" >&2
	exit 1
}

[ -f "$SRC_DIR/root" ] || {
	echo "ERROR: root missing" >&2
	exit 1
}

echo "BOARD_DIR=$BOARD_DIR"

echo "[2] Extract original FIT pieces"

cp "$SRC_DIR/kernel" "$WORK/parts/kernel.original"

dumpimage -l "$WORK/parts/kernel.original"
dumpimage -l "$WORK/parts/kernel.original" | grep -q 'Image 0 (kernel' || {
	echo "ERROR: FIT image 0 is not kernel" >&2
	exit 1
}

dumpimage -l "$WORK/parts/kernel.original" | grep -q 'Image 1 (fdt' || {
	echo "ERROR: FIT image 1 is not fdt/dtb" >&2
	exit 1
}

dumpimage -T flat_dt -p 0 -o "$WORK/parts/kernel.lzma" "$WORK/parts/kernel.original"
dumpimage -T flat_dt -p 1 -o "$WORK/parts/original.dtb" "$WORK/parts/kernel.original"

dtc -I dtb -O dts -o "$WORK/parts/original.dts" "$WORK/parts/original.dtb" >/dev/null 2>&1 || true

echo "[3] Validate source image is normal stock layout"

python3 - <<'PY'
from pathlib import Path
import re
import sys

s = Path(".matrix_ex5601_build/parts/original.dts").read_text()

def block(addr):
    m = re.search(r'(partition@' + re.escape(addr) + r'\s*\{.*?\n\s*\};)', s, re.S)
    if not m:
        sys.exit(f"ERROR: partition@{addr} not found")
    return m.group(1)

b1 = block("580000")
b2 = block("4580000")

if 'label = "ubi";' not in b1:
    sys.exit('ERROR: source image first slot is not label "ubi"')

if 'label = "ubi2";' not in b2:
    sys.exit('ERROR: source image second slot is not label "ubi2"')

if 'read-only;' not in b2:
    sys.exit('ERROR: source image second slot is not read-only as expected')

print("Source DTB layout OK:")
print('  physical ubi  -> label "ubi"')
print('  physical ubi2 -> label "ubi2", read-only')
PY

echo "[4] Create openwrt_ubi.bin for physical first bank"

mkdir -p "$WORK/out_ubi/$BOARD_DIR"

cp "$SRC_DIR/CONTROL" "$WORK/out_ubi/$BOARD_DIR/CONTROL"
cp "$SRC_DIR/kernel"  "$WORK/out_ubi/$BOARD_DIR/kernel"
cp "$SRC_DIR/root"    "$WORK/out_ubi/$BOARD_DIR/root"

tar -cf "$OUT_UBI" -C "$WORK/out_ubi" "$BOARD_DIR"

echo "[5] Create label-swap DTB for physical second bank"

cp "$WORK/parts/original.dts" "$WORK/parts/patched-labelswap.dts"

python3 - <<'PY'
from pathlib import Path
import re
import sys

p = Path(".matrix_ex5601_build/parts/patched-labelswap.dts")
s = p.read_text()

def replace_block(addr, transform):
    global s
    pattern = r'(partition@' + re.escape(addr) + r'\s*\{.*?\n\s*\};)'
    m = re.search(pattern, s, re.S)
    if not m:
        sys.exit(f"ERROR: partition@{addr} not found")
    old = m.group(1)
    new = transform(old)
    s = s[:m.start(1)] + new + s[m.end(1):]

def ensure_read_only(block):
    block = re.sub(r'\n\s*read-only;\s*', '\n', block)
    block = re.sub(
        r'(reg\s*=\s*<0x580000\s+0x4000000>;\s*)',
        r'\1\n\t\t\t\t\t\t\tread-only;',
        block,
        count=1
    )
    return block

def remove_read_only(block):
    return re.sub(r'\n\s*read-only;\s*', '\n', block)

def patch_first(block):
    block = block.replace('label = "ubi";', 'label = "ubi_oem";')
    block = ensure_read_only(block)
    return block

def patch_second(block):
    block = block.replace('label = "ubi2";', 'label = "ubi";')
    block = remove_read_only(block)
    return block

replace_block("580000", patch_first)
replace_block("4580000", patch_second)

p.write_text(s)
PY

dtc -I dts -O dtb -o "$WORK/parts/patched-labelswap.dtb" "$WORK/parts/patched-labelswap.dts" >/dev/null 2>&1 || true

echo "[6] Validate label-swap DTS"

python3 - <<'PY'
from pathlib import Path
import re
import sys

s = Path(".matrix_ex5601_build/parts/patched-labelswap.dts").read_text()

def block(addr):
    m = re.search(r'(partition@' + re.escape(addr) + r'\s*\{.*?\n\s*\};)', s, re.S)
    if not m:
        sys.exit(f"ERROR: partition@{addr} not found")
    return m.group(1)

b1 = block("580000")
b2 = block("4580000")

if 'label = "ubi_oem";' not in b1:
    sys.exit('ERROR: first slot was not renamed to ubi_oem')

if 'read-only;' not in b1:
    sys.exit('ERROR: first slot is not read-only')

if 'label = "ubi";' not in b2:
    sys.exit('ERROR: second slot was not renamed to ubi')

if 'read-only;' in b2:
    sys.exit('ERROR: second slot is still read-only')

print("Label-swap DTB layout OK:")
print('  physical ubi  -> label "ubi_oem", read-only')
print('  physical ubi2 -> label "ubi"')
PY

echo "[7] Build label-swap FIT kernel"
# compression can change in future  loadaddr and entry point too
cat > "$WORK/parts/openwrt-labelswap.its" <<'EOF'
/dts-v1/;

/ {
	description = "ARM64 OpenWrt FIT labelswap";
	#address-cells = <1>;

	images {
		kernel-1 {
			description = "ARM64 OpenWrt Linux";
			data = /incbin/("kernel.lzma");
			type = "kernel";
			arch = "arm64";
			os = "linux";
			compression = "lzma";
			load = <0x48000000>;
			entry = <0x48000000>;

			hash-1 {
				algo = "crc32";
			};

			hash-2 {
				algo = "sha1";
			};
		};

		fdt-1 {
			description = "EX5601-T0 labelswap DTB";
			data = /incbin/("patched-labelswap.dtb");
			type = "flat_dt";
			arch = "arm64";
			compression = "none";

			hash-1 {
				algo = "crc32";
			};

			hash-2 {
				algo = "sha1";
			};
		};
	};

	configurations {
		default = "config-1";

		config-1 {
			description = "OpenWrt labelswap";
			kernel = "kernel-1";
			fdt = "fdt-1";
		};
	};
};
EOF

(
	cd "$WORK/parts"
	mkimage -f openwrt-labelswap.its kernel.labelswap >/dev/null
	dumpimage -l kernel.labelswap
)

echo "[8] Create openwrt_ubi2.bin for physical second bank"

mkdir -p "$WORK/out_ubi2/$BOARD_DIR"

cp "$SRC_DIR/CONTROL" "$WORK/out_ubi2/$BOARD_DIR/CONTROL"
cp "$WORK/parts/kernel.labelswap" "$WORK/out_ubi2/$BOARD_DIR/kernel"
cp "$SRC_DIR/root" "$WORK/out_ubi2/$BOARD_DIR/root"

tar -cf "$OUT_UBI2" -C "$WORK/out_ubi2" "$BOARD_DIR"

echo "[9] Final validation"

mkdir -p "$WORK/verify/ubi" "$WORK/verify/ubi2"

tar -xf "$OUT_UBI" -C "$WORK/verify/ubi"
tar -xf "$OUT_UBI2" -C "$WORK/verify/ubi2"

UBI_DIR="$(find "$WORK/verify/ubi" -mindepth 1 -maxdepth 1 -type d -name 'sysupgrade-*' | head -n1)"
UBI2_DIR="$(find "$WORK/verify/ubi2" -mindepth 1 -maxdepth 1 -type d -name 'sysupgrade-*' | head -n1)"

dumpimage -T flat_dt -p 1 -o "$WORK/verify/ubi/final.dtb" "$UBI_DIR/kernel" >/dev/null
dumpimage -T flat_dt -p 1 -o "$WORK/verify/ubi2/final.dtb" "$UBI2_DIR/kernel" >/dev/null

dtc -I dtb -O dts -o "$WORK/verify/ubi/final.dts" "$WORK/verify/ubi/final.dtb" >/dev/null 2>&1 || true
dtc -I dtb -O dts -o "$WORK/verify/ubi2/final.dts" "$WORK/verify/ubi2/final.dtb" >/dev/null 2>&1 || true

python3 - <<'PY'
from pathlib import Path
import re
import sys

def block(s, addr):
    m = re.search(r'(partition@' + re.escape(addr) + r'\s*\{.*?\n\s*\};)', s, re.S)
    if not m:
        sys.exit(f"ERROR: partition@{addr} not found")
    return m.group(1)

ubi = Path(".matrix_ex5601_build/verify/ubi/final.dts").read_text()
ubi2 = Path(".matrix_ex5601_build/verify/ubi2/final.dts").read_text()

ubi_b1 = block(ubi, "580000")
ubi_b2 = block(ubi, "4580000")

ubi2_b1 = block(ubi2, "580000")
ubi2_b2 = block(ubi2, "4580000")

if 'label = "ubi";' not in ubi_b1:
    sys.exit("ERROR: openwrt_ubi.bin first slot is not label ubi")

if 'label = "ubi2";' not in ubi_b2:
    sys.exit("ERROR: openwrt_ubi.bin second slot is not label ubi2")

if 'label = "ubi_oem";' not in ubi2_b1 or 'read-only;' not in ubi2_b1:
    sys.exit("ERROR: openwrt_ubi2.bin first slot is not ubi_oem read-only")

if 'label = "ubi";' not in ubi2_b2 or 'read-only;' in ubi2_b2:
    sys.exit("ERROR: openwrt_ubi2.bin second slot is not writable label ubi")

print("Final validation OK")
PY

echo
echo "Created:"
ls -lh "$OUT_UBI" "$OUT_UBI2"

echo
sha256sum "$OUT_UBI" "$OUT_UBI2"

echo
echo "Use:"
echo "  openwrt_ubi.bin  -> flash when target physical slot is ubi / mtd6"
echo "  openwrt_ubi2.bin -> flash when target physical slot is ubi2 / mtd7"
