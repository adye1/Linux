#!/bin/bash
#
# Arch Linux Installation Script for HP Z840
# 128GB RAM, 4x1TB SSDs with encrypted btrfs RAID10
# GNOME Desktop with Bluetooth and PipeWire
#
# WARNING: This will DESTROY all data on the specified disks
# Review and modify variables before running

set -e

# Configuration
DISK1="/dev/sda"
DISK2="/dev/sdb"
DISK3="/dev/sdc"
DISK4="/dev/sdd"
HOSTNAME="z840-workstation"
USERNAME="adam"
TIMEZONE="America/New_York"
LOCALE="en_US.UTF-8"

echo "=== Arch Linux Installation for HP Z840 ==="
echo "Disks: $DISK1 $DISK2 $DISK3 $DISK4"
echo "This will DESTROY all data on these disks!"
read -p "Press Enter to continue or Ctrl+C to abort..."

# Update system clock
timedatectl set-ntp true

# Partition all disks identically
# 1GB EFI, 16GB swap, rest for root
for DISK in $DISK1 $DISK2 $DISK3 $DISK4; do
    echo "Partitioning $DISK..."
    parted -s $DISK mklabel gpt
    parted -s $DISK mkpart ESP fat32 1MiB 1025MiB
    parted -s $DISK set 1 esp on
    parted -s $DISK mkpart primary linux-swap 1025MiB 17409MiB
    parted -s $DISK mkpart primary 17409MiB 100%
done

# Format EFI partition on first disk
mkfs.fat -F32 ${DISK1}1

# Setup swap on all disks (RAID0 for swap)
echo "Setting up encrypted swap..."
for i in 1 2 3 4; do
    DISK_VAR="DISK$i"
    DISK="${!DISK_VAR}"
    mkswap ${DISK}2
done
# Enable swap on first disk for now
swapon ${DISK1}2

# Setup LUKS encryption on root partitions
echo "Setting up LUKS encryption..."
echo "You will be prompted to enter a passphrase for disk encryption."

for i in 1 2 3 4; do
    DISK_VAR="DISK$i"
    DISK="${!DISK_VAR}"
    echo "Encrypting ${DISK}3..."
    cryptsetup luksFormat ${DISK}3
    cryptsetup open ${DISK}3 cryptroot${i}
done

# Create btrfs RAID10 across encrypted partitions
echo "Creating btrfs RAID10 filesystem..."
mkfs.btrfs -f -L archroot -d raid10 -m raid10 \
    /dev/mapper/cryptroot1 \
    /dev/mapper/cryptroot2 \
    /dev/mapper/cryptroot3 \
    /dev/mapper/cryptroot4

# Mount root and create subvolumes
mount /dev/mapper/cryptroot1 /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@cache
umount /mnt

# Mount with optimal options
mount -o noatime,compress=zstd,subvol=@ /dev/mapper/cryptroot1 /mnt
mkdir -p /mnt/{home,boot,.snapshots,var/log,var/cache}
mount -o noatime,compress=zstd,subvol=@home /dev/mapper/cryptroot1 /mnt/home
mount -o noatime,compress=zstd,subvol=@snapshots /dev/mapper/cryptroot1 /mnt/.snapshots
mount -o noatime,compress=zstd,subvol=@log /dev/mapper/cryptroot1 /mnt/var/log
mount -o noatime,compress=zstd,subvol=@cache /dev/mapper/cryptroot1 /mnt/var/cache
mount ${DISK1}1 /mnt/boot

# Install base system
echo "Installing base system..."
pacstrap /mnt base linux linux-firmware btrfs-progs cryptsetup lvm2 \
    base-devel git vim nano networkmanager \
    intel-ucode amd-ucode

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot and configure
arch-chroot /mnt /bin/bash <<EOF
set -e

# Set timezone
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Set locale
echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

# Set hostname
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

# Configure mkinitcpio for encryption
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Install bootloader
bootctl install

# Get UUID of first encrypted partition
CRYPT_UUID=\$(blkid -s UUID -o value ${DISK1}3)

# Configure bootloader
cat > /boot/loader/loader.conf <<LOADER
default arch.conf
timeout 3
console-mode max
editor no
LOADER

cat > /boot/loader/entries/arch.conf <<BOOTENTRY
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /amd-ucode.img
initrd  /initramfs-linux.img
options cryptdevice=UUID=\$CRYPT_UUID:cryptroot1 root=/dev/mapper/cryptroot1 rootflags=subvol=@ rw quiet
BOOTENTRY

# Install GNOME and related packages
pacman -S --noconfirm gnome gnome-extra gdm

# Install Bluetooth
pacman -S --noconfirm bluez bluez-utils

# Install PipeWire
pacman -S --noconfirm pipewire pipewire-alsa pipewire-pulse pipewire-jack \
    wireplumber gst-plugin-pipewire

# Install additional utilities
pacman -S --noconfirm firefox chromium htop btop neofetch \
    noto-fonts noto-fonts-emoji ttf-dejavu ttf-liberation

# Enable services
systemctl enable NetworkManager
systemctl enable gdm
systemctl enable bluetooth

# Set root password
echo "Set root password:"
passwd

# Create user
useradd -m -G wheel,audio,video,storage -s /bin/bash $USERNAME
echo "Set password for $USERNAME:"
passwd $USERNAME

# Configure sudo
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Configure swap resume (optional)
# Add swap partitions to crypttab for auto-unlock
cat >> /etc/crypttab <<CRYPTTAB
swap1 ${DISK1}2 /dev/urandom swap,cipher=aes-xts-plain64,size=256
swap2 ${DISK2}2 /dev/urandom swap,cipher=aes-xts-plain64,size=256
swap3 ${DISK3}2 /dev/urandom swap,cipher=aes-xts-plain64,size=256
swap4 ${DISK4}2 /dev/urandom swap,cipher=aes-xts-plain64,size=256
CRYPTTAB

cat >> /etc/fstab <<FSTAB
/dev/mapper/swap1 none swap defaults 0 0
/dev/mapper/swap2 none swap defaults 0 0
/dev/mapper/swap3 none swap defaults 0 0
/dev/mapper/swap4 none swap defaults 0 0
FSTAB

EOF

echo "=== Installation Complete ==="
echo "1. Unmount: umount -R /mnt"
echo "2. Close LUKS: cryptsetup close cryptroot{1,2,3,4}"
echo "3. Reboot: reboot"
echo ""
echo "After reboot:"
echo "- Login with your user account"
echo "- GNOME should start automatically"
echo "- Bluetooth: use Settings > Bluetooth"
echo "- Audio managed by PipeWire"