# OpenWrt Installer for Zyxel EX5601-T0

This repository offers a tool for installing OpenWrt on the Zyxel EX5601-T0 router that runs the OEM Zyxel firmware.
The installation process works directly from the OEM firmware, without the need for a UART connection. All you need is a single tar file and a script loaded into the /tmp directory.
## With the latest update, now it is possible to flash OpenWrt ubootmod Or stock layout safely.

> [!WARNING]
> Power loss during flash can brick the device.
> Keep backups of important MTD partitions before flash

## Quick install require Internet connection
On router
```bash
cd /tmp
wget \
https://raw.githubusercontent.com/majad00/ex5601_openwrt_loader/main/tools/openwrt_chroot_rootfs.tar.gz \
https://raw.githubusercontent.com/majad00/ex5601_openwrt_loader/main/tools/loader.sh
chmod +x loader.sh ; ./loader.sh
```

## Beginner's Guide  
Download the installation bundle from /tools ( two files)
1) Miniroot Archive (openwrt_chroot_rootfs.tar.gz)
2) Main script (loader.sh ) 

Copy both files to the router's /tmp dir using WinSCP or the SCP:

```bash
scp openwrt_chroot_rootfs.tar.gz loader.sh root@192.168.1.1:/tmp/
```
Alternatively, you can copy files to a USB drive and then use the USB drive, or use wget to download directly to /tmp

```bash
mount /dev/sda1 /mnt/usb
cp /mnt/usb/openwrt_chroot_rootfs.tar.gz /tmp

```
 Starting

(Assuming you have root access on SSH)
```bash
chmod +x /tmp/loader.sh
/tmp/loader.sh
```

Once the script completes, LUCI web server will be running in your RAM at port 8080. 
Flash Openwrt from LUCI menu ... System > Install matrix > and select to flash Openwrt-stock layout or U-boot layout.
### Router reboot at the end , usually it take 10 to 15 seconds for full installation.

## Expert's Guide
This bundle provides a safe way to install OpenWrt on the Zyxel EX5601-T0 router directly from the OEM firmware flashing inactive partition, how we do that.

- **`loader.sh`** - A script that creates a Matrix/OpenWrt chroot environment on your running OEM firmware, similar to the second phase of sysupgrade. Instead of immediately flashing, it sets up additional services and the LuCI web interface to help you activate OpenWrt from within the OEM firmware at port 8080.

- **`openwrt_chroot_rootfs.tar.gz`** - OpenWrt rootfs with minimal services enabled.

> **Update**: With the latest update, now it is also possible to flash OpenWrt U-Boot layout safely.

---

### How to create miniroot from source

To create `openwrt_chroot_rootfs.tar.gz` file, follow these steps:

   a) Clone the repository and navigate to `source/ubi_patch`.  
   b) Download the latest OpenWrt sysupgrade  firmware with the stock layout.  
   c) Rename it to `openwrt.bin`.  
   d) Run `patch_bin.sh` in the `ubi_patch` directory.  
   e) Copy the generated files (`openwrt_ubi.bin` and `openwrt_ubi2.bin`) to `source/rootfs/etc`.  
   f) go to the `source/rootfs`, and run:
```bash
tar -cpzf ../openwrt_chroot_rootfs.tar.gz .
```  

This will generate "openwrt_chroot_rootfs.tar.gz" inside source dir

### Steps

```bash
# 1. Clone the repository
git clone https://github.com/majad00/ex5601_openwrt_loader.git
cd ex5601_openwrt_loader

# 2. Download the latest OpenWrt sysupgrade image (stock layout) You may also use another compatible OpenWrt stock-layout sysupgrade image for the EX5601-T0.
cd source/ubi_patch
wget https://downloads.openwrt.org/releases/24.10.5/targets/mediatek/filogic/openwrt-24.10.5-mediatek-filogic-zyxel_ex5601-t0-stock-squashfs-sysupgrade.bin
mv openwrt-*.bin openwrt.bin

# 3. Apply the patch
chmod +x ./patch_bin.sh
./patch_bin.sh

# 4. Copy the generated files to the rootfs directory
cp openwrt_ubi.bin openwrt_ubi2.bin ../rootfs/etc/

# 5. Create the rootfs archive
cd ../rootfs
tar -cpzf ../openwrt_chroot_rootfs.tar.gz . ; cd ..
```  


Latest update: U-bootmod layout conversion from the Matrix LuCI interface is possible now


