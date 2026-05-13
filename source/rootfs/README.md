You make changes to the filesystem and then repack it.

Create a compressed archive of the current directory and save it as "openwrt_chroot_rootfs.tar.gz" in the parent directory by using the following command: 
From the current directory

```bash
tar -cpzf ../openwrt_chroot_rootfs.tar.gz .
```