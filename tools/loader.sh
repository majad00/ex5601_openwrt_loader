#!/bin/sh
# written by majad.qureshi@lut.fi
# Zyxel EX5601-T0 OpenWrt Matrix Loader

MATRIX="/tmp/openwrt_matrix"
ARCHIVE_NAME="openwrt_chroot_rootfs.tar.gz"
ARCHIVE_PATH="/tmp/$ARCHIVE_NAME"
FLASH_DIR="/tmp/matrix-flash"

fail() {
	echo "ERROR: $*" >&2
	exit 1
}


# Function to check firmware version and warn about 3.x
check_firmware_version() {
	# Get firmware version using sys atsh
	FW_VERSION="$(sys atsh 2>/dev/null | grep -i "Firmware Version" | awk -F':' '{print $2}' | sed 's/^[ \t]*//;s/[ \t]*$//')"
	
	if [ -n "$FW_VERSION" ]; then
		# Extract major version (3, 4, 5, etc.)
		MAJOR="$(echo "$FW_VERSION" | sed -n 's/.*ACDZ\.\([0-9]\)\.[0-9].*/\1/p')"
		
		if [ "$MAJOR" = "3" ]; then
			echo ""
			echo "=============================================="
			echo "⚠️  WARNING: FIRMWARE VERSION 3.x DETECTED!"
			echo "=============================================="
			echo "Detected: $FW_VERSION"
			echo ""
			echo "The boot partition switching mechanism on firmware 3.x"
			echo "is different from 4.x and 5.x versions."
			echo ""
			echo " THE TOOL CAN NOT WORK ON THIS DEVICE "
			echo " you need to switch the boot partition manually at the end"
			echo ""
			echo "     fw_setenv bootpart 0   # or 1"
			echo "     fw_setenv bootcount 0"
			echo "     sys atsw OR zyxel sys atsh"
			echo ""
			echo "  Recommended way: flash router with firmware 4.x or 5.x"
			echo "=============================================="
			echo ""
			echo "Press Enter to continue (tool may not work), or Ctrl+C to abort and flash router with right firmware..."
			read -r
		elif [ "$MAJOR" = "4" ]; then
			echo "✅ Firmware 4.x detected - boot switching works automatically"
		elif [ "$MAJOR" -ge 5 ] 2>/dev/null; then
			echo "✅ Firmware 5.x or higher detected - boot switching works automatically"
		else
			echo "⚠️  Unknown firmware version: $FW_VERSION"
		fi
	else
		echo "⚠️  Could not detect firmware version (sys atsh not available)"
	fi
}


is_mounted() {
	grep -q " $1 " /proc/mounts
}


echo -n "Starting > > " > /dev/console
for i in 1 2; do
	echo -n " > " > /dev/console
	sleep 1
done

[ -f "$ARCHIVE_PATH" ] || fail "$ARCHIVE_NAME not found in /tmp"

FREE_TMP="$(df -m /tmp | awk 'NR==2 {print $4}')"
[ "$FREE_TMP" -ge 100 ] || fail "insufficient RAM in /tmp (${FREE_TMP}MB). Need 100MB+"

echo " Extracting RootFS..."

rm -rf "$MATRIX"
mkdir -p "$MATRIX"

tar -xzf "$ARCHIVE_PATH" -C "$MATRIX" || fail "extraction failed"

rm -f "$ARCHIVE_PATH"

echo "[OK] Extraction complete. Archive removed to save RAM."

echo " Installing Matrix files..."

cp "$MATRIX/etc/openwrt_ubi.bin" /tmp/ 2>/dev/null || true
cp "$MATRIX/etc/openwrt_ubi2.bin" /tmp/ 2>/dev/null || true
cp "$MATRIX/etc/matrix_flash_inactive.sh" /tmp/ || fail "matrix_flash_inactive.sh missing"
cp "$MATRIX/etc/matrix_flash_runner.sh" /tmp/ || fail "matrix_flash_runner.sh missing"
cp "$MATRIX/etc/matrix_boot_initramfs.sh" /tmp/ || fail "matrix_boot_initramfs.sh missing"
cp "$MATRIX/etc/matrix_ubootmod_runner.sh" /tmp/ || fail "matrix_ubootmod_runner.sh missing"
cp "$MATRIX/etc/initramfs.bin" /tmp/ || fail "initramfs.bin missing"
cp "$MATRIX/etc/zl34.bin" /tmp/ || fail "zloader is missing"
cp "$MATRIX/etc/fip.bin" /tmp/ || fail "FIP is missing"

chmod +x /tmp/matrix_flash_inactive.sh
chmod +x /tmp/matrix_flash_runner.sh

mkdir -p "$FLASH_DIR"

cp "$MATRIX/etc/matrix_flash_runner.sh" /tmp/ || fail "matrix_flash_runner.sh missing"

echo "[OK] Matrix files installed."

#check_firmware_version

echo " Preparing Environment..."


iptables -F 2>/dev/null || true
iptables -P INPUT ACCEPT 2>/dev/null || true
iptables -P FORWARD ACCEPT 2>/dev/null || true
iptables -P OUTPUT ACCEPT 2>/dev/null || true

mkdir -p "$MATRIX/dev" "$MATRIX/proc" "$MATRIX/sys" "$MATRIX/tmp"

is_mounted "$MATRIX/dev"  || mount --rbind /dev "$MATRIX/dev"
is_mounted "$MATRIX/proc" || mount --bind /proc "$MATRIX/proc"
is_mounted "$MATRIX/sys"  || mount --bind /sys "$MATRIX/sys"
is_mounted "$MATRIX/tmp"  || mount -t tmpfs tmpfs "$MATRIX/tmp"

mkdir -p /tmp/matrix-flash ; mkdir -p /tmp/matrix-ubootmod
mkdir -p "$MATRIX/tmp/matrix-flash" ; mkdir -p "$MATRIX/tmp/matrix-ubootmod"
mount --bind /tmp/matrix-flash "$MATRIX/tmp/matrix-flash" ; mount --bind /tmp/matrix-ubootmod "$MATRIX/tmp/matrix-ubootmod"

# OpenWrt expects /var -> /tmp
rm -rf "$MATRIX/var"
ln -s /tmp "$MATRIX/var"

mkdir -p \
	"$MATRIX/tmp/run" \
	"$MATRIX/tmp/run/ubus" \
	"$MATRIX/tmp/log" \
	"$MATRIX/tmp/lock" \
	"$MATRIX/tmp/state" \
	"$MATRIX/tmp/etc" \
	"$MATRIX/tmp/sysinfo" \
	"$MATRIX/tmp/lib/luci-bwc"

mkdir -p "$MATRIX/etc/config"

touch "$MATRIX/etc/config/network"
touch "$MATRIX/etc/config/system"

echo "zyxel,ex5601-t0-stock" > "$MATRIX/tmp/sysinfo/board_name"
echo "Zyxel EX5601-T0 (Stock Layout)" > "$MATRIX/tmp/sysinfo/model"

cp /etc/resolv.conf "$MATRIX/etc/resolv.conf" 2>/dev/null || true

echo "[OK] Environment prepared with real device nodes."

echo " Starting Matrix flash runner..."

if [ -f "$FLASH_DIR/runner.pid" ]; then
	OLDPID="$(cat "$FLASH_DIR/runner.pid" 2>/dev/null || true)"
	if [ -n "$OLDPID" ] && kill -0 "$OLDPID" 2>/dev/null; then
		echo "[OK] Matrix flash runner already running."
	else
		rm -f "$FLASH_DIR/runner.pid"
	fi
fi

if [ ! -f "$FLASH_DIR/runner.pid" ]; then
	/tmp/matrix_flash_runner.sh > "$FLASH_DIR/runner.log" 2>&1 &
	echo $! > "$FLASH_DIR/runner.pid"
	echo "[OK] Matrix flash runner started."
fi

/tmp/matrix_ubootmod_runner.sh > /tmp/matrix-ubootmod/runner.log 2>&1 &
echo $! > /tmp/matrix-ubootmod/runner.pid
echo " Launching OpenWrt LuCI services..."

chroot "$MATRIX" /bin/sh <<'EOF'
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LD_LIBRARY_PATH=/usr/lib:/lib

# Create necessary directories
mkdir -p /var/run /var/log /var/lock /var/state /tmp/etc /tmp/sysinfo /var/lib/luci-bwc /tmp/run /tmp/lock /tmp/state

# Create symlinks for /var
rm -f /var
ln -s /tmp /var
# Create board info
echo "zyxel,ex5601-t0-stock" > /tmp/sysinfo/board_name
echo "Zyxel EX5601-T0 (Stock Layout)" > /tmp/sysinfo/model
# Ensure config directories exist
mkdir -p /etc/config
touch /etc/config/network /etc/config/system
echo "Matrix Loader" > /etc/config/system
# Start services in background
/sbin/ubusd &
sleep 2
/sbin/rpcd &
sleep 2
/usr/sbin/uhttpd -f -p 8080 -h /www -r Matrix-OpenWrt &
/sbin/procd &
echo "================================================"
echo "      EX5601-T0 OpenWrt Installer V3"
echo "================================================"
echo "------------------------------------------------"
echo " SUCCESS: Access LUCI at PORT 8080"
echo " Example URL:     http://192.168.1.1:8080"
echo " Username:	 root / no password"
echo "------------------------------------------------"
EOF

#chroot "$MATRIX" /sbin/ubusd > "$MATRIX/tmp/ubusd.log" 2>&1 & UBUSD_PID=$!

#chroot "$MATRIX" /sbin/rpcd > "$MATRIX/tmp/rpcd.log" 2>&1 & RPCD_PID=$!

chroot "$MATRIX" /usr/sbin/uhttpd -f -p 0.0.0.0:8080 -h /www -r Matrix-OpenWrt > "$MATRIX/tmp/uhttpd.log" 2>&1 & UHTTPD_PID=$!

sleep 2


exit 0
