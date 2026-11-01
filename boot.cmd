# One boot script for both UFS (scsi) and microSD (mmc).
# Check which partition actually contains this boot script instead of
# trusting a hardcoded device: try UFS first, then microSD.
setenv kernel_dev
setenv kernel_part
if test -e scsi 0:13 /boot/boot.scr; then
    setenv kernel_dev scsi
    setenv kernel_part 0:13
elif test -e mmc 0:1 /boot/boot.scr; then
    setenv kernel_dev mmc
    setenv kernel_part 0:1
else
    echo "boot.scr not found on scsi 0:13 or mmc 0:1"
    exit 1
fi
echo "boot.scr found on ${kernel_dev} ${kernel_part}"

# Read the ext4 UUID directly from the filesystem that holds boot.scr.
setenv rootuuid
setenv rootarg
if fsuuid ${kernel_dev} ${kernel_part} rootuuid; then
    if test -n "${rootuuid}"; then
        setenv rootarg "root=UUID=${rootuuid}"
    fi
fi

if test -z "${rootarg}"; then
    if test "${kernel_dev}" = "scsi"; then
        # fsuuid unavailable: fall back to the UFS partition UUID.
        setenv rootuuid
        part uuid scsi ${kernel_part} rootuuid
        if test -n "${rootuuid}"; then
            setenv rootarg "root=PARTUUID=${rootuuid}"
        fi
    fi
fi

if test -z "${rootarg}"; then
    echo "Could not determine root UUID for ${kernel_dev} ${kernel_part}"
    exit 1
fi

setenv bootargs "clk_ignore_unused pd_ignore_unused ${rootarg} rootwait rw"
load ${kernel_dev} ${kernel_part} ${kernel_addr_r} /boot/vmlinuz-7.3.0-sm6225-upstream+
load ${kernel_dev} ${kernel_part} ${fdt_addr_r} /boot/dtbs/sm6225-xiaomi-tapas.dtb
load ${kernel_dev} ${kernel_part} ${ramdisk_addr_r} /boot/initrd.img-7.3.0-sm6225-upstream+
booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
