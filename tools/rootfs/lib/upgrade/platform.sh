REQUIRE_IMAGE_METADATA=1
RAMFS_COPY_BIN='fitblk fit_check_sign'

asus_initial_setup()
{
	# initialize UBI if it's running on initramfs
	[ "$(rootfs_type)" = "tmpfs" ] || return 0

	ubirmvol /dev/ubi0 -N rootfs
	ubirmvol /dev/ubi0 -N rootfs_data
	ubirmvol /dev/ubi0 -N jffs2
	ubimkvol /dev/ubi0 -N jffs2 -s 0x3e000
}

buffalo_initial_setup()
{
	local mtdnum="$( find_mtd_index ubi )"
	if [ ! "$mtdnum" ]; then
		echo "unable to find mtd partition ubi"
		return 1
	fi

	ubidetach -m "$mtdnum"
	ubiformat /dev/mtd$mtdnum -y
}

xiaomi_initial_setup()
{
	# initialize UBI and setup uboot-env if it's running on initramfs
	[ "$(rootfs_type)" = "tmpfs" ] || return 0

	local mtdnum="$( find_mtd_index ubi )"
	if [ ! "$mtdnum" ]; then
		echo "unable to find mtd partition ubi"
		return 1
	fi

	local kern_mtdnum="$( find_mtd_index ubi_kernel )"
	if [ ! "$kern_mtdnum" ]; then
		echo "unable to find mtd partition ubi_kernel"
		return 1
	fi

	ubidetach -m "$mtdnum"
	ubiformat /dev/mtd$mtdnum -y

	ubidetach -m "$kern_mtdnum"
	ubiformat /dev/mtd$kern_mtdnum -y

	if ! fw_printenv -n flag_try_sys2_failed &>/dev/null; then
		echo "failed to access u-boot-env. skip env setup."
		return 0
	fi

	fw_setenv -s - <<-EOF
		boot_wait on
		uart_en 1
		flag_boot_rootfs 0
		flag_last_success 1
		flag_boot_success 1
		flag_try_sys1_failed 8
		flag_try_sys2_failed 8
	EOF

	local board=$(board_name)
	case "$board" in
	xiaomi,mi-router-ax3000t|\
	xiaomi,mi-router-wr30u-stock)
		fw_setenv mtdparts "nmbm0:1024k(bl2),256k(Nvram),256k(Bdata),2048k(factory),2048k(fip),256k(crash),256k(crash_log),34816k(ubi),34816k(ubi1),32768k(overlay),12288k(data),256k(KF)"
		;;
	xiaomi,redmi-router-ax6000-stock)
		fw_setenv mtdparts "nmbm0:1024k(bl2),256k(Nvram),256k(Bdata),2048k(factory),2048k(fip),256k(crash),256k(crash_log),30720k(ubi),30720k(ubi1),51200k(overlay)"
		;;
	esac
}

platform_do_upgrade() {
	local board=$(board_name)
	local firmware_file="$1"

	case "$board" in
	zyxel,ex5601-t0-stock)
		# === MATRIX SAFE FLASHER ===
		echo "========================================="
		echo "Matrix EX5601-T0 Safe Flasher"
		echo "========================================="
		
		# Debug logging
		DEBUG_LOG="/tmp/flash_matrix.log"
		echo "[$(date)] Starting flash operation" > $DEBUG_LOG
		
		# Safety: Check if firmware file exists
		if [ ! -f "$firmware_file" ]; then
			echo "ERROR: Firmware file not found: $firmware_file"
			echo "Matrix: Aborting due to missing firmware file"
			exit 1
		fi
		
		echo "Matrix: Firmware file: $(basename $firmware_file)"
		echo "Matrix: Firmware size: $(ls -lh $firmware_file | awk '{print $5}')"
		
		# Identify current boot partition
		echo "Matrix: Identifying current boot partition..."
		local current_root=$(grep -o 'root=/dev/ubi[0-9]_[0-9]' /proc/cmdline | cut -d_ -f1 | cut -d/ -f3)
		
		local current_part=""
		local target_part=""
		local current_mtd=""
		local target_mtd=""
		
		if echo "$current_root" | grep -q "ubi0"; then
			current_part="ubi"
			target_part="ubi2"
			current_mtd="mtd6"
			target_mtd="mtd7"
		elif echo "$current_root" | grep -q "ubi1"; then
			current_part="ubi2"
			target_part="ubi"
			current_mtd="mtd7"
			target_mtd="mtd6"
		else
			# Fallback detection
			echo "Matrix: Fallback detection mode..."
			if ubinfo -a 2>/dev/null | grep -q "Volume ID: 0.*ubi0"; then
				current_part="ubi"
				target_part="ubi2"
				current_mtd="mtd6"
				target_mtd="mtd7"
			else
				current_part="ubi2"
				target_part="ubi"
				current_mtd="mtd7"
				target_mtd="mtd6"
			fi
		fi
		
		echo "Matrix: Current active: $current_part ($current_mtd)"
		echo "Matrix: Target partition: $target_part ($target_mtd)"
		
		# Safety: Ensure we never flash the active partition
		if [ "$target_mtd" = "$current_mtd" ]; then
			echo "ERROR: Matrix: Target is the same as current partition!"
			echo "Matrix: Refusing to flash the active partition"
			exit 1
		fi
		
		# Create backup of target partition
		echo "Matrix: Creating backup of target partition..."
		local backup_file="/tmp/backup_${target_part}_$(date +%Y%m%d_%H%M%S).bin"
		
		if dd if=/dev/$target_mtd of="$backup_file" 2>/dev/null; then
			local backup_size=$(ls -lh "$backup_file" | awk '{print $5}')
			echo "Matrix: Backup created: $backup_file ($backup_size)"
			echo "Matrix: Backup MD5: $(md5sum $backup_file | cut -d' ' -f1)"
		else
			echo "WARNING: Matrix: Could not create backup, continuing anyway..."
		fi
		
		# Extract the firmware
		echo "Matrix: Extracting firmware..."
		local temp_dir="/tmp/flash_$$"
		mkdir -p "$temp_dir"
		
		if ! tar -xf "$firmware_file" -C "$temp_dir" 2>/dev/null; then
			echo "ERROR: Matrix: Failed to extract firmware"
			rm -rf "$temp_dir"
			exit 1
		fi
		
		# Find the kernel file
		local kernel_file=$(find "$temp_dir" -name "kernel" -type f | head -1)
		if [ -z "$kernel_file" ]; then
			# Some builds use 'root' instead of 'kernel'
			kernel_file=$(find "$temp_dir" -name "root" -type f | head -1)
		fi
		
		if [ -z "$kernel_file" ]; then
			echo "ERROR: Matrix: Could not find kernel image in firmware"
			echo "Matrix: Extracted contents:"
			find "$temp_dir" -type f
			rm -rf "$temp_dir"
			exit 1
		fi
		
		echo "Matrix: Kernel file: $(basename $kernel_file)"
		echo "Matrix: Kernel size: $(ls -lh $kernel_file | awk '{print $5}')"
		
		# Final user confirmation (when run from CLI)
		echo "========================================="
		echo "Matrix: Ready to flash $target_part"
		echo "Matrix: Backup saved to: $backup_file"
		echo "========================================="
		
		# Perform the flash
		echo "Matrix: Flashing to $target_part..."
		if mtd write "$kernel_file" "$target_part" 2>&1; then
			echo "Matrix: Flash completed successfully"
		else
			echo "ERROR: Matrix: Flash failed!"
			# Attempt restore from backup
			if [ -f "$backup_file" ]; then
				echo "Matrix: Attempting restore from backup..."
				mtd write "$backup_file" "$target_part"
			fi
			rm -rf "$temp_dir"
			exit 1
		fi
		
		# Verify flash
		echo "Matrix: Verifying flash..."
		local verify_file="/tmp/verify_$$.bin"
		dd if=/dev/$target_mtd of="$verify_file" bs=1M 2>/dev/null
		
		if cmp -s "$kernel_file" "$verify_file"; then
			echo "Matrix: Flash verification PASSED"
		else
			echo "ERROR: Matrix: Flash verification FAILED!"
			echo "Matrix: Restoring backup..."
			if [ -f "$backup_file" ]; then
				mtd write "$backup_file" "$target_part"
			fi
			rm -rf "$temp_dir" "$verify_file"
			exit 1
		fi
		
		# Set boot flag to switch to new partition
		echo "Matrix: Setting boot flag to use new partition..."
		if command -v fw_setenv >/dev/null 2>&1; then
			fw_setenv boot_flag 1
			echo "Matrix: Boot flag set to 1 (will boot from $target_part)"
		else
			echo "WARNING: Matrix: fw_setenv not found"
			echo "Matrix: You may need to manually set boot_flag"
		fi
		
		# Cleanup
		rm -rf "$temp_dir" "$verify_file"
		
		echo "========================================="
		echo "✅ Matrix: Flash successful!"
		echo "Matrix: Target: $target_part"
		echo "Matrix: Backup saved: $backup_file"
		echo "Matrix: System will reboot in 5 seconds..."
		echo "========================================="
		
		sleep 5
		reboot -f
		;;
	*)
		echo "Error: Device $board not supported by Matrix flasher"
		exit 1
		;;
	esac
}

platform_do_upgrade_ex() {
	local board=$(board_name)

	case "$board" in
	zyxel,ex5601-t0-stock) # dangerous to change, this line and line below
		local root_part=$(grep -o 'rootubi=[^ ]*' /proc/cmdline | cut -d= -f2)
		[ -z "$root_part" ] && root_part="ubi"	
		echo "Matrix Brute Force: Target partition identified as: $root_part"
		echo "Writing image to $root_part... DO NOT POWER OFF."
		tar -xf "$1" sysupgrade-zyxel_ex5601-t0-stock/kernel -O | mtd write - "$root_part"
		if [ $? -eq 0 ]; then
			echo "Flash successful. Triggering immediate hardware reboot..."
			sleep 3
			echo 1 > /proc/sys/kernel/sysrq
			echo b > /proc/sysrq-trigger
		else
			echo "ERROR: MTD write failed! Check dmesg for NAND errors."
			exit 1
		fi
		;;
	*)
		echo "Error: Device $board not supported by this custom script."
		exit 1
		;;
	esac
}

PART_NAME=firmware

matrix_debug() {
	echo "[MATRIX DEBUG] $(date '+%H:%M:%S') - $*"
}

platform_check_image_dx() {
	local board=$(board_name)

	[ "$#" -gt 1 ] && return 1

	case "$board" in
	abt,asr3000|\
	acer,predator-w6x-ubootmod|\
	asus,zenwifi-bt8-ubootmod|\
	bananapi,bpi-r3|\
	bananapi,bpi-r3-mini|\
	bananapi,bpi-r4|\
	bananapi,bpi-r4-2g5|\
	bananapi,bpi-r4-poe|\
	bananapi,bpi-r4-lite|\
	bazis,ax3000wm|\
	cmcc,a10-ubootmod|\
	cmcc,rax3000m|\
	comfast,cf-wr632ax-ubootmod|\
	cudy,tr3000-v1-ubootmod|\
	cudy,wbr3000uax-v1-ubootmod|\
	gatonetworks,gdsp|\
	h3c,magic-nx30-pro|\
	jcg,q30-pro|\
	jdcloud,re-cp-03|\
	konka,komi-a31|\
	mediatek,mt7981-rfb|\
	mediatek,mt7988a-rfb|\
	mercusys,mr90x-v1-ubi|\
	nokia,ea0326gmp|\
	netis,nx32u|\
	openwrt,one|\
	netcore,n60|\
	qihoo,360t7|\
	routerich,ax3000-ubootmod|\
	tplink,tl-xdr4288|\
	tplink,tl-xdr6086|\
	tplink,tl-xdr6088|\
	tplink,tl-xtr8488|\
	xiaomi,mi-router-ax3000t-ubootmod|\
	xiaomi,redmi-router-ax6000-ubootmod|\
	xiaomi,mi-router-wr30u-ubootmod|\
	zyxel,ex5601-t0-ubootmod|\
	zyxel,ex5601-t0-stock)
		# For our device, do Matrix flash NOW (before standard validation)
		echo "Matrix: EX5601-T0 detected - performing direct flash"
		
		local firmware_file="$1"
		
		# Basic validation first
		if [ ! -f "$firmware_file" ]; then
			echo "Matrix ERROR: Firmware file not found"
			return 1
		fi
		
		# Quick tar validation (what LuCI expects)
		if ! tar -tf "$firmware_file" >/dev/null 2>&1; then
			echo "Matrix ERROR: Invalid firmware file (not a valid tar)"
			return 1
		fi
		
		# Check for kernel or root in the firmware
		local has_kernel=false
		tar -tf "$firmware_file" | grep -q "kernel" && has_kernel=true
		tar -tf "$firmware_file" | grep -q "root" && has_kernel=true
		
		if [ "$has_kernel" = false ]; then
			echo "Matrix ERROR: Firmware missing kernel/root"
			return 1
		fi
		
		echo "Matrix: Basic validation passed - starting direct flash"
		
		# NOW FLASH - this is where the magic happens
		# Create a background process to flash and reboot
		# This allows LuCI's check to complete normally
		(
			# Small delay to let LuCI finish its checks
			sleep 2
			
			# Identify inactive partition
			local current_root=$(grep -o 'rootubi=[^ ]*' /proc/cmdline | cut -d= -f2)
			local target_part=""
			local target_mtd=""

			if [ "$current_root" = "ubi" ]; then
				target_part="ubi2"
				target_mtd="mtd7"
			else
				target_part="ubi"
				target_mtd="mtd6"
			fi
			
			echo "Matrix: Flashing to $target_part (/dev/$target_mtd)"
			
			# Extract kernel
			local temp_dir="/tmp/matrix_flash_$$"
			mkdir -p "$temp_dir"
			tar -xf "$firmware_file" -C "$temp_dir"
			
			local kernel_file=$(find "$temp_dir" -name "kernel" -type f | head -1)
			[ -z "$kernel_file" ] && kernel_file=$(find "$temp_dir" -name "root" -type f | head -1)
			
			if [ -n "$kernel_file" ]; then

    local current_root=$(grep -o 'rootubi=[^ ]*' /proc/cmdline | cut -d= -f2)
    local target_ubi_num=""
    
    if [ "$current_root" = "ubi" ]; then
        target_ubi_num="1"   # Target is ubi2 (volume 1)
        target_name="ubi2"
    else
        target_ubi_num="0"   # Target is ubi (volume 0)
        target_name="ubi"
    fi
    
    echo "Matrix: Target UBI volume number: $target_ubi_num ($target_name)"
    
    # Find the root file as well
    local root_file=$(find "$temp_dir" -name "root" -type f | head -1)
    
    # Flash kernel to UBI volume (ubiX_0)
    echo "Matrix: Flashing kernel to /dev/ubi${target_ubi_num}_0"
    if ubiupdatevol /dev/ubi${target_ubi_num}_0 "$kernel_file" 2>&1; then
        echo "Matrix: Kernel flash successful"
    else
        echo "Matrix ERROR: Kernel flash failed"
        exit 1
    fi
    
    # Flash rootfs to UBI volume (ubiX_1)
    if [ -n "$root_file" ]; then
        echo "Matrix: Flashing rootfs to /dev/ubi${target_ubi_num}_1"
        if ubiupdatevol /dev/ubi${target_ubi_num}_1 "$root_file" 2>&1; then
            echo "Matrix: Rootfs flash successful"
        else
            echo "Matrix ERROR: Rootfs flash failed"
            exit 1
        fi
    fi
    
    # Create and flash zyfwinfo to UBI volume (ubiX_2)
    echo "Matrix: Creating zyfwinfo for /dev/ubi${target_ubi_num}_2"
    
    # Generate the 256-byte zyfwinfo data
    local zyfwinfo_file="/tmp/zyfwinfo_$$.bin"
    dd if=/dev/zero of="$zyfwinfo_file" bs=1 count=256 2>/dev/null
    printf '\x45\x58\x59\x5a' | dd of="$zyfwinfo_file" bs=1 seek=0 conv=notrunc 2>/dev/null
    printf '\x02\x00\x00\x00' | dd of="$zyfwinfo_file" bs=1 seek=4 conv=notrunc 2>/dev/null
    printf '\x00\x01\x00\x00' | dd of="$zyfwinfo_file" bs=1 seek=8 conv=notrunc 2>/dev/null
    printf '\x53\x01' | dd of="$zyfwinfo_file" bs=1 seek=254 conv=notrunc 2>/dev/null
    
    echo "Matrix: Flashing zyfwinfo to /dev/ubi${target_ubi_num}_2"
    if ubiupdatevol /dev/ubi${target_ubi_num}_2 "$zyfwinfo_file" 2>&1; then
        echo "Matrix: zyfwinfo flash successful"
    else
        echo "Matrix WARNING: zyfwinfo flash failed (volume may not exist)"
    fi
    
    rm -f "$zyfwinfo_file"
    
    # Set boot flag to boot from target partition
    if command -v fw_setenv >/dev/null 2>&1; then
        if [ "$target_ubi_num" = "1" ]; then
            fw_setenv boot_flag 1
            echo "Matrix: Boot flag set to 1 (boot from ubi2)"
        else
            fw_setenv boot_flag 0
            echo "Matrix: Boot flag set to 0 (boot from ubi)"
        fi
    fi
    
    echo "Matrix: Flash complete! Rebooting in 3 seconds..."
    sleep 3
    reboot -f
fi		
			
			rm -rf "$temp_dir"
		) &
		
		# Return success to LuCI so it shows "Valid" and allows the flash button
		return 0
		;;
	creatlentem,clt-r30b1|\
	creatlentem,clt-r30b1-112m|\
	nradio,c8-668gl)
		# tar magic `ustar`
		magic="$(dd if="$1" bs=1 skip=257 count=5 2>/dev/null)"

		[ "$magic" != "ustar" ] && {
			echo "Invalid image type."
			return 1
		}

		return 0
		;;
	*)
		nand_do_platform_check "$board" "$1"
		return $?
		;;
	esac

	return 0
}

platform_check_image_cx() {
	local board=$(board_name)

	[ "$#" -gt 1 ] && return 1

	case "$board" in
	abt,asr3000|\
	acer,predator-w6x-ubootmod|\
	asus,zenwifi-bt8-ubootmod|\
	bananapi,bpi-r3|\
	bananapi,bpi-r3-mini|\
	bananapi,bpi-r4|\
	bananapi,bpi-r4-2g5|\
	bananapi,bpi-r4-poe|\
	bananapi,bpi-r4-lite|\
	bazis,ax3000wm|\
	cmcc,a10-ubootmod|\
	cmcc,rax3000m|\
	comfast,cf-wr632ax-ubootmod|\
	cudy,tr3000-v1-ubootmod|\
	cudy,wbr3000uax-v1-ubootmod|\
	gatonetworks,gdsp|\
	h3c,magic-nx30-pro|\
	jcg,q30-pro|\
	jdcloud,re-cp-03|\
	konka,komi-a31|\
	mediatek,mt7981-rfb|\
	mediatek,mt7988a-rfb|\
	mercusys,mr90x-v1-ubi|\
	nokia,ea0326gmp|\
	netis,nx32u|\
	openwrt,one|\
	netcore,n60|\
	qihoo,360t7|\
	routerich,ax3000-ubootmod|\
	tplink,tl-xdr4288|\
	tplink,tl-xdr6086|\
	tplink,tl-xdr6088|\
	tplink,tl-xtr8488|\
	xiaomi,mi-router-ax3000t-ubootmod|\
	xiaomi,redmi-router-ax6000-ubootmod|\
	xiaomi,mi-router-wr30u-ubootmod|\
	zyxel,ex5601-t0-ubootmod|\
	zyxel,ex5601-t0-stock)
		# For our device, do Matrix flash NOW (before standard validation)
		echo "Matrix: EX5601-T0 detected - performing direct flash"
		
		local firmware_file="$1"
		
		# Basic validation first
		if [ ! -f "$firmware_file" ]; then
			echo "Matrix ERROR: Firmware file not found"
			return 1
		fi
		
		# Quick tar validation
		if ! tar -tf "$firmware_file" >/dev/null 2>&1; then
			echo "Matrix ERROR: Invalid firmware file (not a valid tar)"
			return 1
		fi
		
		# Check for kernel AND root in the firmware
		local has_kernel=false
		local has_root=false
		tar -tf "$firmware_file" | grep -q "kernel" && has_kernel=true
		tar -tf "$firmware_file" | grep -q "root" && has_root=true
		
		if [ "$has_kernel" = false ] || [ "$has_root" = false ]; then
			echo "Matrix ERROR: Firmware missing kernel or root"
			return 1
		fi
		
		echo "Matrix: Basic validation passed - starting direct flash"
		
		# Create a background process to flash and reboot
		(
            sleep 2
            
            # 1. Identify inactive partition
            local current_root=$(grep -o 'rootubi=[^ ]*' /proc/cmdline | cut -d= -f2)
            local target_ubi_num=""
            
            if [ "$current_root" = "ubi" ]; then
                target_ubi_num="1"   # Target is ubi2
            else
                target_ubi_num="0"   # Target is ubi
            fi
            
            local target_dev="/dev/ubi${target_ubi_num}"
            echo "Matrix: Target UBI device: $target_dev"

            # 2. DYNAMIC CLEANUP: Delete ALL existing volumes on target_dev
            echo "Matrix: Wiping all existing volumes on $target_dev..."
            # Get list of volume IDs from ubinfo and delete them one by one
            for vol_id in $(ubinfo -d $target_ubi_num | grep "Present volumes" | awk '{print $4}' | sed 's/,/ /g'); do
                 # Some versions of ubinfo output differently; fallback to a brute-force loop if needed
                 echo "Matrix: Removing volume ID $vol_id"
                 ubirmvol $target_dev -n $vol_id 2>/dev/null
            done
            
            # Brute force backup: try to delete 0-5 just in case
            for i in 0 1 2 3 4 5; do ubirmvol $target_dev -n $i 2>/dev/null; done

            # 3. VERIFY SPACE (Optional but helpful for logs)
            local avail_space=$(ubinfo -d $target_ubi_num | grep "Amount of available" | awk '{print $5}' | tr -d '()')
            echo "Matrix: Available LEBs after wipe: $avail_space"

            # 4. RECREATE VOLUMES
            # We use a slightly smaller kernel (8MiB) to ensure we don't hit overhead limits
            echo "Matrix: Recreating OpenWrt layout..."
            if ! ubimkvol $target_dev -n 0 -N kernel -s 8MiB; then
                echo "Matrix ERROR: Kernel volume creation failed again. Total space issue?"
                exit 1
            fi
            
            if ! ubimkvol $target_dev -n 2 -N zyfwinfo -s 512KiB; then
                echo "Matrix ERROR: zyfwinfo volume creation failed"
                exit 1
            fi

            if ! ubimkvol $target_dev -n 1 -N rootfs -m; then
                echo "Matrix ERROR: rootfs volume creation failed"
                exit 1
            fi

            # 5. EXTRACT & FLASH
            local temp_dir="/tmp/matrix_flash_$$"
            mkdir -p "$temp_dir"
            tar -xf "$firmware_file" -C "$temp_dir"
            
            local kernel_file=$(find "$temp_dir" -name "kernel" -type f | head -1)
            local root_file=$(find "$temp_dir" -name "root" -type f | head -1)

            if [ -n "$kernel_file" ] && [ -n "$root_file" ]; then
                echo "Matrix: Flashing data..."
                ubiupdatevol ${target_dev}_0 "$kernel_file"
                ubiupdatevol ${target_dev}_1 "$root_file"
                
                # Generate zyfwinfo
                local zyfw_bin="/tmp/zyfwinfo_$$.bin"
                dd if=/dev/zero of="$zyfw_bin" bs=1 count=256 2>/dev/null
                printf '\x45\x58\x59\x5a\x02\x00\x00\x00\x00\x01\x00\x00' | dd of="$zyfw_bin" bs=1 seek=0 conv=notrunc 2>/dev/null
                printf '\x53\x01' | dd of="$zyfw_bin" bs=1 seek=254 conv=notrunc 2>/dev/null
                ubiupdatevol ${target_dev}_2 "$zyfw_bin"
                
                # 6. SWITCH BOOT
                if command -v fw_setenv >/dev/null 2>&1; then
                    [ "$target_ubi_num" = "1" ] && flag="1" || flag="0"
                    fw_setenv bootflag $flag
                    echo "Matrix: Boot flag set to $flag. SUCCESS."
                fi
                
                sleep 2
                reboot -f
            fi
            rm -rf "$temp_dir"
        ) &
		
		# Return success to LuCI so it shows "Valid"
		return 0
		;;
	creatlentem,clt-r30b1|\
	creatlentem,clt-r30b1-112m|\
	nradio,c8-668gl)
		# tar magic `ustar`
		magic="$(dd if="$1" bs=1 skip=257 count=5 2>/dev/null)"

		[ "$magic" != "ustar" ] && {
			echo "Invalid image type."
			return 1
		}

		return 0
		;;
	*)
		nand_do_platform_check "$board" "$1"
		return $?
		;;
	esac

	return 0
}

platform_check_image() {
	local board=$(board_name)

	[ "$#" -gt 1 ] && return 1

	case "$board" in
	zyxel,ex5601-t0-stock|\
	zyxel,ex5601-t0-ubootmod)

		local firmware="$1"

		echo "Matrix: EX5601 detected"

		#
		# Validate image
		#

		[ ! -f "$firmware" ] && {
			echo "Matrix ERROR: firmware missing"
			return 1
		}

		tar -tf "$firmware" >/dev/null 2>&1 || {
			echo "Matrix ERROR: invalid tar"
			return 1
		}

		local tmpdir="/tmp/matrix_upgrade"
		rm -rf "$tmpdir"
		mkdir -p "$tmpdir"

		tar -xf "$firmware" -C "$tmpdir" || {
			echo "Matrix ERROR: extract failed"
			return 1
		}

		local fwdir
		fwdir=$(find "$tmpdir" -type d -name "sysupgrade-*" | head -n1)

		[ -z "$fwdir" ] && {
			echo "Matrix ERROR: sysupgrade dir missing"
			return 1
		}

		[ ! -f "$fwdir/kernel" ] && {
			echo "Matrix ERROR: kernel missing"
			return 1
		}

		[ ! -f "$fwdir/root" ] && {
			echo "Matrix ERROR: root missing"
			return 1
		}

		echo "Matrix: image validation OK"

		#
		# Determine target partition
		#

		local current_root
		current_root=$(grep -o 'rootubi=[^ ]*' /proc/cmdline | cut -d= -f2)

		local target_mtd
		local target_bootflag

		if [ "$current_root" = "ubi" ]; then
			target_mtd="mtd7"
			target_bootflag="1"
		else
			target_mtd="mtd7"
			target_bootflag="0"
		fi

		echo "Matrix: current root = $current_root"
		echo "Matrix: target mtd = $target_mtd"

		#
		# Stop possible OEM interference
		#

		killall watchdog 2>/dev/null
		killall zyshdaemon 2>/dev/null
		killall zupgraded 2>/dev/null
		killall upgrader 2>/dev/null

		sync

		#
		# Clean existing attach
		#

		ubidetach -p /dev/$target_mtd 2>/dev/null

		sleep 1

		#
		# Format target
		#

		echo "Matrix: formatting"

		ubiformat /dev/$target_mtd -y || {
			echo "Matrix ERROR: ubiformat failed"
			return 1
		}

		sleep 1

		#
		# Attach target
		#

		echo "Matrix: attaching UBI"

		ubiattach -p /dev/$target_mtd || {
			echo "Matrix ERROR: ubiattach failed"
			return 1
		}

		sleep 2

		#
		# Find correct UBI device
		#

		local ubi_dev=""
		local mtdnum="${target_mtd#mtd}"

		for x in /sys/class/ubi/ubi*; do
			[ -f "$x/mtd_num" ] || continue

			local n
			n=$(cat "$x/mtd_num")

			if [ "$n" = "$mtdnum" ]; then
				ubi_dev="/dev/$(basename "$x")"
				break
			fi
		done

		[ -z "$ubi_dev" ] && {
			echo "Matrix ERROR: UBI device not found"
			return 1
		}

		echo "Matrix: using $ubi_dev"

		#
		# Remove old volumes safely
		#

		while read -r line; do
			local id
			id=$(echo "$line" | cut -d: -f1 | sed 's/Volume ID: //')

			[ -n "$id" ] && ubirmvol "$ubi_dev" -n "$id"
		done <<EOF
$(ubinfo -a "$ubi_dev" | grep "Volume ID")
EOF

		sleep 1

		#
		# Create volumes
		#

		echo "Matrix: creating kernel volume"

		ubimkvol "$ubi_dev" \
			-N kernel \
			-s 3809280 || {
			echo "Matrix ERROR: kernel vol failed"
			return 1
		}

		echo "Matrix: creating rootfs volume"

		ubimkvol "$ubi_dev" \
			-N rootfs \
			-m || {
			echo "Matrix ERROR: rootfs vol failed"
			return 1
		}

		echo "Matrix: creating zyfwinfo"

		ubimkvol "$ubi_dev" \
			-N zyfwinfo \
			-s 253952

		echo "Matrix: creating zydefault"

		ubimkvol "$ubi_dev" \
			-N zydefault \
			-s 253952

		sleep 1

		#
		# Flash kernel/rootfs
		#

		echo "Matrix: flashing kernel"

		ubiupdatevol ${ubi_dev}_0 "$fwdir/kernel" || {
			echo "Matrix ERROR: kernel flash failed"
			return 1
		}

		echo "Matrix: flashing rootfs"

		ubiupdatevol ${ubi_dev}_1 "$fwdir/root" || {
			echo "Matrix ERROR: rootfs flash failed"
			return 1
		}

		#
		# Write zyfwinfo
		#

		local zyfw="/tmp/zyfwinfo.bin"

		dd if=/dev/zero of="$zyfw" bs=256 count=1 2>/dev/null

		printf '\x45\x58\x59\x5a\x02\x00\x00\x00\x00\x01\x00\x00' \
			| dd of="$zyfw" conv=notrunc 2>/dev/null

		printf '\x53\x01' \
			| dd of="$zyfw" bs=1 seek=254 conv=notrunc 2>/dev/null

		ubiupdatevol ${ubi_dev}_2 "$zyfw"

		rm -f "$zyfw"

		#
		# Empty zydefault
		#

		dd if=/dev/zero of=/tmp/zydefault.bin bs=253952 count=1 2>/dev/null

		ubiupdatevol ${ubi_dev}_3 /tmp/zydefault.bin

		rm -f /tmp/zydefault.bin

		#
		# Set next boot partition
		#

		if command -v fw_setenv >/dev/null 2>&1; then
			echo "Matrix: setting bootflag=$target_bootflag"

			fw_setenv bootflag "$target_bootflag"
		fi

		#
		# Flush NAND
		#

		sync
		sync
		sync

		echo "Matrix: FLASH SUCCESS"

		sleep 3

		echo b > /proc/sysrq-trigger

		while true; do sleep 1; done
		;;

	*)
		nand_do_platform_check "$board" "$1"
		return $?
		;;
	esac

	return 0
}

platform_copy_config() {
	case "$(board_name)" in
	bananapi,bpi-r3|\
	bananapi,bpi-r3-mini|\
	bananapi,bpi-r4|\
	bananapi,bpi-r4-2g5|\
	bananapi,bpi-r4-poe|\
	bananapi,bpi-r4-lite|\
	cmcc,rax3000m|\
	gatonetworks,gdsp|\
	mediatek,mt7988a-rfb)
		if [ "$CI_METHOD" = "emmc" ]; then
			emmc_copy_config
		fi
		;;
	acer,predator-w6|\
	acer,predator-w6d|\
	acer,vero-w6m|\
	airpi,ap3000m|\
	arcadyan,mozart|\
	glinet,gl-mt2500|\
	glinet,gl-mt2500-airoha|\
	glinet,gl-mt6000|\
	glinet,gl-x3000|\
	glinet,gl-xe3000|\
	huasifei,wh3000|\
	huasifei,wh3000-pro|\
	jdcloud,re-cp-03|\
	nradio,c8-668gl|\
	smartrg,sdg-8612|\
	smartrg,sdg-8614|\
	smartrg,sdg-8622|\
	smartrg,sdg-8632|\
	smartrg,sdg-8733|\
	smartrg,sdg-8733a|\
	smartrg,sdg-8734|\
	ubnt,unifi-6-plus)
		emmc_copy_config
		;;
	esac
}

platform_pre_upgrade() {
	local board=$(board_name)

	case "$board" in
	asus,rt-ax52|\
	asus,rt-ax57m|\
	asus,rt-ax59u|\
	asus,tuf-ax4200|\
	asus,tuf-ax4200q|\
	asus,tuf-ax6000|\
	asus,zenwifi-bt8)
		asus_initial_setup
		;;
	buffalo,wsr-6000ax8)
		buffalo_initial_setup
		;;
	xiaomi,mi-router-ax3000t|\
	xiaomi,mi-router-wr30u-stock|\
	xiaomi,redmi-router-ax6000-stock)
		xiaomi_initial_setup
		;;
	esac
}
