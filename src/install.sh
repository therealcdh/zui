#!/usr/bin/env bash
set -e

# Ensure Nix/ZFS binaries are in the path if run via sudo
export PATH=$PATH:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

DISK="$1"
POOL_NAME="rpool"

echo "=== ZFS INSTALLATION STARTING ON $DISK ==="

if [ -z "$DISK" ]; then
    echo "Error: No disk specified."
    exit 1
fi

# 1. Cleanup and Idempotency
echo "--- Cleaning up any existing mounts, pools, or LVM/RAID on $DISK ---"
# Deactivate Device Mapper devices (LVM, LUKS, etc)
dmsetup remove_all -f 2>/dev/null || true
# Deactivate LVM
vgchange -a n 2>/dev/null || true
# Deactivate MD RAID
mdadm --stop --scan 2>/dev/null || true

# Unmount anything on /mnt
umount -R /mnt 2>/dev/null || true

# Export the pool if it exists
zpool export -f "$POOL_NAME" 2>/dev/null || true

# Identify partitions
if [[ $DISK == *"nvme"* ]] || [[ $DISK == *"mmcblk"* ]]; then
    P1="${DISK}p1"
    P2="${DISK}p2"
else
    P1="${DISK}1"
    P2="${DISK}2"
fi

# Try to unmount partitions if they are mounted elsewhere
umount -l "$P1" 2>/dev/null || true
umount -l "$P2" 2>/dev/null || true

# Clear ZFS labels
zpool labelclear -f "$P2" 2>/dev/null || true
zpool labelclear -f "$DISK" 2>/dev/null || true

# Force wipe partitions
wipefs --force --all "$P1" 2>/dev/null || true
wipefs --force --all "$P2" 2>/dev/null || true
# Then wipe the disk
wipefs --force --all "$DISK" 2>/dev/null || true

sgdisk -Z "$DISK"
udevadm settle
partprobe "$DISK"
sleep 2

# 2. Partitioning
# Partition 1: EFI (512MB)
# Partition 2: ZFS
echo "--- Partitioning $DISK ---"
sgdisk -n 1:1M:+512M -t 1:EF00 "$DISK"
sgdisk -n 2:0:0      -t 2:BF01 "$DISK"

# Handle partition naming (nvme vs sdX)
if [[ $DISK == *"nvme"* ]] || [[ $DISK == *"mmcblk"* ]]; then
    PART_EFI="${DISK}p1"
    PART_ZFS="${DISK}p2"
else
    PART_EFI="${DISK}1"
    PART_ZFS="${DISK}2"
fi

# Wait for kernel to update partition table
udevadm settle
partprobe "$DISK"
sleep 2

# 3. Create ZFS Pool
echo "--- Creating ZFS Pool: $POOL_NAME ---"
zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -O compression=lz4 \
    -O acltype=posixacl \
    -O xattr=sa \
    -O relatime=on \
    -O mountpoint=none \
    -O canmount=off \
    -O devices=off \
    -o compatibility=grub2 \
    -R /mnt \
    "$POOL_NAME" "$PART_ZFS"

# 4. Create Datasets
echo "--- Creating ZFS Datasets ---"
zfs create -o mountpoint=none -o canmount=off "$POOL_NAME/ROOT"
zfs create -o mountpoint=/    -o canmount=noauto "$POOL_NAME/ROOT/ubuntu"
zfs mount "$POOL_NAME/ROOT/ubuntu"

zfs create -o mountpoint=/home "$POOL_NAME/USERDATA"

# 5. Format EFI
echo "--- Formatting EFI ---"
mkfs.vfat -F 32 "$PART_EFI"
mkdir -p /mnt/boot/efi
mount "$PART_EFI" /mnt/boot/efi

# 6. Copy Files from Live System
echo "--- Syncing Files from Live System ---"
# Assuming we are running in the nixubuntuisorefresh live environment
# where /rofs contains the root filesystem.
rsync -aAX --info=progress2 \
    --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
    --exclude='/run/*' --exclude='/tmp/*' --exclude='/mnt/*' \
    --exclude='/media/*' --exclude='/lost+found' \
    --exclude='/cdrom/*' /rofs/. /mnt/.

# Ensure kernel images and other boot files are copied from the live system's overlay
if [ -d /boot ] && [ "$(ls -A /boot)" ]; then
    echo "--- Syncing /boot from live overlay ---"
    rsync -aAX --exclude='/boot/efi/*' /boot/. /mnt/boot/.
fi

# 7. Finalize (Chroot)
echo "--- Finalizing (Chroot) ---"
for i in /dev /dev/pts /proc /sys /run; do mount -B "$i" "/mnt$i"; done

# Mount efivars if available for UEFI
if [ -d /sys/firmware/efi/efivars ]; then
    mkdir -p /mnt/sys/firmware/efi/efivars
    mount -t efivarfs efivarfs /mnt/sys/firmware/efi/efivars 2>/dev/null || true
fi

# Bind mount /nix to make Nix tools available in chroot
mkdir -p /mnt/nix
mount -B /nix /mnt/nix

# Copy resolv.conf for apt-get, using cat to avoid "same file" errors
rm -f /mnt/etc/resolv.conf
cat /etc/resolv.conf > /mnt/etc/resolv.conf || true

# Clean up man cache to avoid permission issues on ZFS, but keep directory structure
echo "--- Cleaning up man cache ---"
find /mnt/var/cache/man -type f -delete 2>/dev/null || true

# Use a clean PATH for the chroot, preferring host Nix tools only for ZFS commands
# and chroot's own tools for everything else.
CHROOT_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# Dynamically find the store path for zfs/zpool and add it to the chroot path
# We use the direct store path to avoid symlink resolution issues in the chroot
HOST_ZFS_BIN=$(which zpool)
if [ -n "$HOST_ZFS_BIN" ]; then
    REAL_ZFS_DIR=$(dirname $(readlink -f "$HOST_ZFS_BIN"))
    # Put Nix store path at the BEGINNING to ensure host tools are found first
    CHROOT_PATH="$REAL_ZFS_DIR:$CHROOT_PATH"
fi
# Also add common Nix profile paths
CHROOT_PATH="$CHROOT_PATH:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin"

echo "--- Debug: CHROOT_PATH is $CHROOT_PATH ---"

# Set a local TMPDIR and TEMP inside the chroot to avoid issues with host's Nix-shell paths
chroot /mnt /usr/bin/env PATH="$CHROOT_PATH" TMPDIR=/tmp TEMP=/tmp DEBIAN_FRONTEND=noninteractive ZPOOL_VDEV_NAME_PATH=1 bash -c "
    set -e
    echo '--- Configuring ZFS inside Chroot ---'
    # Diagnostic: check if zpool is found
    which zpool || (echo 'ERROR: zpool not found in chroot PATH' && exit 1)
    # Diagnostic: list kernels
    echo '--- Kernels found in /boot: ---'
    ls -l /boot/vmlinuz* || echo 'No kernels found in /boot!'
    
    # Ensure ZFS config dir exists
    mkdir -p /etc/zfs
    # Update ZFS cache
    zpool set cachefile=/etc/zfs/zpool.cache $POOL_NAME
    
    # Configure fstab for EFI
    echo '--- Configuring fstab ---'
    EFI_UUID=\$(blkid -s UUID -o value $PART_EFI)
    echo \"UUID=\$EFI_UUID /boot/efi vfat umask=0077 0 1\" > /etc/fstab
    
    # Install GRUB, ZFS tools and a kernel in Ubuntu
    echo '--- Running Apt Update ---'
    apt-get update
    echo '--- Installing ZFS, Grub and Kernel packages ---'
    # We include linux-image-generic to ensure a bootable kernel is present, 
    # as live systems sometimes don't have it in the expected location for rsync.
    apt-get install -y zfs-initramfs grub-efi-amd64-signed shim-signed linux-image-generic
    
    echo '--- Installing Grub to Disk ---'
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck
    echo '--- Updating Grub Config ---'
    update-grub
    echo '--- Updating Initramfs ---'
    # Use -c to create a new initramfs and -k all for all installed kernels
    update-initramfs -c -k all
"

echo "=== INSTALLATION COMPLETE ==="
sync
umount -l /mnt/nix || true
rmdir /mnt/nix || true
umount -R /mnt
zpool export "$POOL_NAME"
