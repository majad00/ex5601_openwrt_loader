## Openwrt loader for Zyxel EX5601-T0 

This repositoryThis repository includes tools and a guide on how to install OpenWrt on the Zyxel EX5601-T0 router. These tools and scripts are designed to make installation possible without disassembly or requiring a UART connection, making it as user-friendly as possible.


Copy "openwrt_chroot_rootfs.tar.gz" (https://github.com/majad00/ex5601_openwrt_loader/raw/main/tools/openwrt_chroot_rootfs.tar.gz) to the router's /tmp folder (using WinSCP or SCP). 
Copy "loader.sh" from /tools

Move these files to router under /tmp
chmod +x /tmp/loader.sh
Execute: /tmp/loader.sh