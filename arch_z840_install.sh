#!/bin/bash
set -e

# Arch Linux Installation Script for HP Z840 Workstation
# 4x1TB SSD with LUKS encryption, BTRFS RAID10, GNOME desktop
# WARNING: This will DESTROY all data on /dev/sda, /dev/sdb, /dev/sdc, /dev/sdd

echo "=== Arch Linux Installation for HP Z840 ==="
echo "This script will:"
echo "- Encrypt 4x1TB SSDs with LUKS"
echo "- Create BTRFS RAID10 across encrypted drives"
echo "- Install Arch Linux with GNOME desktop"
echo "- Install C++ development tools"
echo ""
read -p "Press ENTER to continue or CTRL+C to abort..."

# Variables - MODIFY THESE IF YOUR DRIVES ARE DIFFERENT
DRIVES=("/dev/sda" "/dev/sdb" "/dev/sdc" "/dev/sdd")
EFI_DRIVE="${DRIVES[0]}"
HOSTNAME="z840-arch"
USERNAME="user"
TIMEZONE="America/New_York"

# Step 1: Verify we're booted in UEFI mode
if [ ! -d /sys/firmware/efi/efivars ]; then
    echo "ERROR: Not booted in UEFI mode. Please boot in UEFI mode."
    exit 1
fi

# Step 2: Update system clock
timedatectl set-ntp true

# Step 3: Partition drives
echo "=== Partitioning drives ==="
for drive in "${DRIVES[@]}"; do
    echo "Partitioning $drive..."
    parted -s "$drive" mklabel gpt
    
    if [ "$drive" == "$EFI_DRIVE" ]; then
        # First drive gets EFI partition
        parted -s "$drive" mkpart primary fat32 1MiB 1GiB
        parted -s "$drive" set 1 esp on
        parted -s "$drive" mkpart primary 1GiB 100%
    else
        # Other drives: single partition for data
        parted -s "$drive" mkpart primary 1MiB 100%
    fi
done

sleep 2

# Step 4: Format EFI partition
echo "=== Formatting EFI partition ==="
mkfs.fat -F32 "${EFI_DRIVE}1"

# Step 5: Setup LUKS encryption
echo "=== Setting up LUKS encryption ==="
echo "You will be asked to enter encryption password for each drive"

CRYPT_DEVS=()
for i in "${!DRIVES[@]}"; do
    drive="${DRIVES[$i]}"
    
    if [ "$drive" == "$EFI_DRIVE" ]; then
        partition="${drive}2"
    else
        partition="${drive}1"
    fi
    
    crypt_name="crypt$i"
    
    echo "Encrypting $partition..."
    cryptsetup luksFormat --type luks2 "$partition"
    cryptsetup open "$partition" "$crypt_name"
    
    CRYPT_DEVS+=("/dev/mapper/$crypt_name")
done

# Step 6: Create BTRFS RAID10
echo "=== Creating BTRFS RAID10 ==="
mkfs.btrfs -f -m raid10 -d raid10 -L arch_root "${CRYPT_DEVS[@]}"

# Step 7: Mount and create subvolumes
echo "=== Creating BTRFS subvolumes ==="
mount "${CRYPT_DEVS[0]}" /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@snapshots

umount /mnt

# Mount subvolumes
mount -o noatime,compress=zstd,space_cache=v2,subvol=@ "${CRYPT_DEVS[0]}" /mnt
mkdir -p /mnt/{home,var,tmp,.snapshots,boot}
mount -o noatime,compress=zstd,space_cache=v2,subvol=@home "${CRYPT_DEVS[0]}" /mnt/home
mount -o noatime,compress=zstd,space_cache=v2,subvol=@var "${CRYPT_DEVS[0]}" /mnt/var
mount -o noatime,compress=zstd,space_cache=v2,subvol=@tmp "${CRYPT_DEVS[0]}" /mnt/tmp
mount -o noatime,compress=zstd,space_cache=v2,subvol=@snapshots "${CRYPT_DEVS[0]}" /mnt/.snapshots

# Mount EFI partition
mount "${EFI_DRIVE}1" /mnt/boot

# Step 8: Install base system
echo "=== Installing base system ==="
pacstrap /mnt base linux linux-firmware btrfs-progs amd-ucode intel-ucode \
    networkmanager vim sudo base-devel

# Step 9: Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Step 10: Chroot and configure system
echo "=== Configuring system ==="
cat > /mnt/root/setup.sh << 'EOFCHROOT'
#!/bin/bash
set -e

# Timezone
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Localization
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# Root password
echo "Set root password:"
passwd

# Install bootloader and essential packages
pacman -S --noconfirm grub efibootmgr

# Configure mkinitcpio for encryption
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Install GRUB
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB

# Configure GRUB for encryption
UUID0=$(blkid -s UUID -o value ${DRIVES[0]}2)
sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$UUID0:crypt0 root=/dev/mapper/crypt0 rootflags=subvol=@\"|" /etc/default/grub
sed -i 's/^#GRUB_ENABLE_CRYPTODISK=y/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub

grub-mkconfig -o /boot/grub/grub.cfg

# Enable NetworkManager
systemctl enable NetworkManager

# Install GNOME
pacman -S --noconfirm gnome gnome-extra gdm
systemctl enable gdm

# Install C++ development tools
pacman -S --noconfirm gcc clang cmake gdb lldb valgrind git ninja meson

# Install useful tools
pacman -S --noconfirm firefox htop neofetch tree wget curl unzip zip \
    tmux rsync openssh man-db man-pages

# Create user
useradd -m -G wheel -s /bin/bash $USERNAME
echo "Set password for $USERNAME:"
passwd $USERNAME

# Enable sudo for wheel group
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

echo "=== Installation complete! ==="
EOFCHROOT

# Make script executable and run it
chmod +x /mnt/root/setup.sh

# Export variables for chroot
cat > /mnt/root/env.sh << EOF
export TIMEZONE="$TIMEZONE"
export HOSTNAME="$HOSTNAME"
export USERNAME="$USERNAME"
export DRIVES=(${DRIVES[@]})
EOF

# Execute in chroot
arch-chroot /mnt /bin/bash -c "source /root/env.sh && /root/setup.sh"

# Step 11: Setup crypttab for other drives
echo "=== Configuring crypttab ==="
for i in "${!DRIVES[@]}"; do
    if [ $i -eq 0 ]; then
        continue  # Skip first drive, already in GRUB config
    fi
    
    drive="${DRIVES[$i]}"
    partition="${drive}1"
    uuid=$(blkid -s UUID -o value "$partition")
    
    echo "crypt$i UUID=$uuid none luks" >> /mnt/etc/crypttab
done

# Cleanup
rm /mnt/root/setup.sh /mnt/root/env.sh

# Final message
echo ""
echo "=============================================="
echo "Installation complete!"
echo "=============================================="
echo ""
echo "IMPORTANT: Before rebooting, note:"
echo "1. All drives are encrypted with LUKS"
echo "2. You'll need to enter the password for the first drive at boot"
echo "3. Other drives will be unlocked automatically after system boot"
echo "4. Username: $USERNAME"
echo "5. System will boot into GNOME desktop"
echo ""
echo "Unmount and reboot:"
echo "  umount -R /mnt"
echo "  reboot"
echo ""