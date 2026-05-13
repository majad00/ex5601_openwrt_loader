#!/bin/sh
echo "=== Starting OpenWrt Chroot ==="
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
/sbin/init &
