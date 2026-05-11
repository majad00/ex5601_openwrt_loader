#!/bin/sh

#written by majad.qureshi@lut.fi
MATRIX="/tmp/openwrt_matrix"
ARCHIVE_NAME="openwrt_chroot_rootfs.tar.gz"
ARCHIVE_PATH="/tmp/$ARCHIVE_NAME"

echo "================================================"
echo "      Zyxel EX5601-T0 OpenWrt Matrix Loader      "
echo "================================================"

echo -n "Starting > > " > /dev/console
for i in $(seq 1 2); do
    echo -n " > " > /dev/console
    sleep 1
done

if [ ! -f "$ARCHIVE_PATH" ]; then
    echo "ERROR: $ARCHIVE_NAME not found in /tmp!"
    exit 1
fi

FREE_TMP=$(df -m /tmp | awk 'NR==2 {print $4}')
if [ "$FREE_TMP" -lt 100 ]; then
    echo "ERROR: Insufficient RAM in /tmp (${FREE_TMP}MB). Need 100MB+."
    exit 1
fi

echo " Extracting RootFS..."
mkdir -p "$MATRIX"
tar -xzf "$ARCHIVE_PATH" -C "$MATRIX"
if [ $? -ne 0 ]; then
    echo "ERROR: Extraction failed!"
    exit 1
fi
rm "$ARCHIVE_PATH"
echo "[OK] Extraction complete. Archive removed to save RAM."

echo " Preparing Environment..."
iptables -F
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# CRITICAL: Bind mount entire /dev recursively to get real device nodes
mkdir -p "$MATRIX/dev"
mount --rbind /dev "$MATRIX/dev"

# Also bind mount /proc and /sys
mkdir -p "$MATRIX/proc"
mount --bind /proc "$MATRIX/proc"
mkdir -p "$MATRIX/sys"
mount --bind /sys "$MATRIX/sys"

# Mount /tmp as tmpfs
mount -t tmpfs tmpfs "$MATRIX/tmp"

# Copy resolv.conf for networking
cp /etc/resolv.conf "$MATRIX/etc/resolv.conf" 2>/dev/null

echo "[OK] Environment prepared with real device nodes"

echo " Launching OpenWrt Services..."

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

# Start services in background
/sbin/ubusd &
sleep 2
/sbin/configd &
sleep 2
/sbin/rpcd &
sleep 2
/usr/sbin/uhttpd -f -p 8080 -h /www -r Matrix-OpenWrt &
/sbin/procd &

echo "------------------------------------------------"
echo " SUCCESS: Access LUCI at:"
echo " URL:     http://192.168.1.1:8080"
echo "------------------------------------------------"
echo " Ready"
echo ""
echo "NOTE: Flash commands will now work because /dev is properly bind-mounted"
echo "------------------------------------------------"

# Keep the shell alive
/bin/sh
EOF