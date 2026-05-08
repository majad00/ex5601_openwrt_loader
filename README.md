### OpenWrt Loader for Zyxel EX5601-T0
This repository includes tools and a guide on how to install OpenWrt on the Zyxel EX5601-T0 router. These tools and scripts are designed to make installation possible without disassembly or requiring a UART connection, making the process as user-friendly as possible.

Quick Start Guide
Download the RootFS Archive
Download the openwrt_chroot_rootfs.tar.gz and the loader.sh script from the /tools folder.

Upload to Router
Copy both files to the router's /tmp folder using WinSCP or the SCP command:

```bash
scp openwrt_chroot_rootfs.tar.gz loader.sh root@192.168.1.1:/tmp/
```
Or copy files to USB and then Use USB
```bash
mount /dev/sda1 /mnt/usb
cp /mnt/usb/openwrt_chroot_rootfs.tar.gz /tmp

```
Run the Loader
Connect to your router via SSH and execute the following:
Assuming you have root access
```bash
chmod +x /tmp/loader.sh
/tmp/loader.sh
```

Once the script completes, OpenWrt will be running in your RAM. Access the web interface at:
[http://192.168.1.1:8080](http://192.168.1.1:8080)

## Note
Non-Persistent: This environment runs entirely in RAM. If you reboot the router without flashing, it will return to the stock Zyxel firmware.

Firewall: The script automatically disables the Zyxel firewall to allow access to the OpenWrt LuCI interface on port 8080.
