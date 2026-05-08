
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

# 2. Extraction
echo " Extracting RootFS..."
mkdir -p "$MATRIX"
tar -xzf "$ARCHIVE_PATH" -C "$MATRIX"
if [ $? -ne 0 ]; then
            echo "ERROR: Extraction failed!"
                exit 1
fi
rm "$ARCHIVE_PATH"
echo "[OK] Extraction complete. Archive removed to save RAM."

# 3. Network & Firewall Plumbing
echo " Preparing Environment..."
iptables -F
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

check_mount() { grep -q "$1" /proc/mounts; }
for dir in dev proc sys tmp; do
            if ! check_mount "$MATRIX/$dir"; then
                            mount --bind /$dir "$MATRIX/$dir"
                                fi
                        done
                        cp /etc/resolv.conf "$MATRIX/etc/resolv.conf"
                        echo "[OK] Firewall opened and filesystems bound."

                        # 4. Entering the Matrix & Starting Services
                        echo " Launching OpenWrt Services..."

                        chroot "$MATRIX" /bin/sh <<EOF
# 1. Setup internal folders
mkdir -p /var/run /var/log /var/lock /var/state /tmp/etc /tmp/sysinfo

# 2. Spoof system information to prevent LuCI null errors
# These files are what LuCI's ucode looks for to identify the router
echo "Openwrt Loader for EX5601-T0" > /tmp/sysinfo/model
echo "Openwrt firmware Loader" > /tmp/sysinfo/board_name

# 3. Initialize UCI (Crucial for LuCI logic)
# This creates the initial config cache so LuCI has something to read
mkdir -p /etc/config
[ ! -f /etc/config/network ] && touch /etc/config/network
[ ! -f /etc/config/system ] && touch /etc/config/system

# 4. Start Services
echo "Starting ubus..."
/sbin/ubusd &
sleep 5

# 1. Set up basic environment variables
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
export HOME=/root
export LOGNAME=root

# 2. Start the configuration manager (needed by LuCI to read settings)
/sbin/configd &
/sbin/rpcd &
sleep 2

# 3. Start the web server on port 8080 
# (Using 8080 to avoid the Zyxel port 80 conflict)
/usr/sbin/uhttpd -f -p 8080 -h /www -r Matrix-OpenWrt &
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
mkdir -p /var/run /var/log /var/lock /var/state /tmp/etc

# Start the UCI system (This replaces configd's role)
/sbin/procd & 
sleep 1

# Start rpcd (The 'brain' behind LuCI)
/sbin/rpcd &
sleep 1

echo "------------------------------------------------"
echo " SUCCESS: OpenWrt is now running in RAM!"
echo " URL:     http://192.168.1.1:8080"
echo "------------------------------------------------"
echo " Entering Openwrt shell..."
/bin/sh
EOF

