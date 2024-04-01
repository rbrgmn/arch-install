#!/usr/bin/env bash

### VARIABLES USER
_HOSTNAME="arch"
_DISK_INSTALL="/dev/sda"
_USERNAME="anon"

### VARIABLES DEFAULT
_SIZE_SWAP=8
_SIZE_ROOT=64

### VARIABLES SYSTEM

# Check vendor architecture
_CPU=$(grep vendor_id /proc/cpuinfo)
if [[ $_CPU == *"AuthenticAMD"* ]]; then
    _MICROCODE=amd-ucode
else
    _MICROCODE=intel-ucode
fi


### MAIN

clear
pacman -Sy


### CREATE NEW PARTITION SCHEME AND FORMAT BLOCK DEVICES

echo "Clear old partition"
dd if=/dev/urandom of=$_DISK_INSTALL bs=1M count=1024 &>/dev/null

parted -s "$_DISK_INSTALL" \
  mklabel GPT\
  mkpart ESP fat32 1MiB 512MiB\
  set 1 esp on\
  mkpart cryptfs 513MiB 100%\

sleep 0.5

# Get partition block devices
_ESP="/dev/$(lsblk $_DISK_INSTALL -o NAME,PARTLABEL | grep ESP| cut -d " " -f1 | cut -c7-)"
_CRYPTFS="/dev/$(lsblk $_DISK_INSTALL -o NAME,PARTLABEL | grep cryptfs | cut -d " " -f1 | cut -c7-)"

# Create luks2 partition
echo "YES" | cryptsetup luksFormat $_CRYPTFS

# Create logical volumes
echo "Type password for cryptfs"
cryptsetup open $_CRYPTFS cryptfs
pvcreate /dev/mapper/cryptfs
vgcreate cryptfs /dev/mapper/cryptfs

lvcreate -L"$_SIZE_SWAP"G -n swap cryptfs
lvcreate -L"$_SIZE_ROOT"G -n root cryptfs
lvcreate -l 100%FREE -n home cryptfs

# Format partitions
echo "Create ESP Partition"
mkfs.fat -F32 $_ESP &>/dev/null
echo "Create ROOT PArtition"
mkfs.ext4 /dev/cryptfs/root &>/dev/null
echo "Create HOME Partition"
mkfs.ext4 /dev/cryptfs/home &>/dev/null
echo "Create SWAP Partition"
mkswap /dev/cryptfs/swap &>/dev/null


### MOUNT NEW FILESYSTEM
echo "Create and mount File System"
mount /dev/cryptfs/root /mnt
mkdir -p /mnt/{boot,home}
mount /dev/cryptfs/home /mnt/home
mount $_ESP /mnt/boot
swapon /dev/cryptfs/swap


### PACSTRAP
echo "PACSTRAP"
pacstrap /mnt base base-devel linux linux-firmware networkmanager lvm2 vim $_MICROCODE
clear

# GENERATING FSTAB
echo "Generate FSTAB"
genfstab -U /mnt >> /mnt/etc/fstab


# Set hostname
echo "Set hostname"
echo "$_HOSTNAME" >> /mnt/etc/hostname

# Setting hosts file.
echo "Setting hosts file."
cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   "$_HOSTNAME".localdomain   $_HOSTNAME
EOF

# Locale set
echo "Set locale"
echo "en_US.UTF-8 UTF-8"  > /mnt/etc/locale.gen
echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf

echo "KEYMAP=us" > /mnt/etc/vconsole.conf

# mkinitcpio
echo "Create mkinitcpio"
_HOOKS=$(grep -E "^HOOKS=\(" /mnt/etc/mkinitcpio.conf)
sed -i "s/$_HOOKS/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt lvm2 filesystems fsck)/g" /mnt/etc/mkinitcpio.conf


# ARCH-CHROOT
echo 'ARCH-CHROOT'
arch-chroot /mnt /bin/bash -e <<EOF
    # Setting up timezone.
    ln -sf /usr/share/zoneinfo/$(curl -s http://ip-api.com/line?fields=timezone) /etc/localtime &>/dev/null
    # Setting up clock.
    hwclock --systohc
    # Generating locales.my keys aren't even on
    echo "Generating locales."
    locale-gen &>/dev/null
    # Generating a new initramfs.
    mkinitcpio -P &>/dev/null
    #install boot
    bootctl --path=/boot install &>/dev/null
    # Adding user with sudo privilege
    useradd -m -G wheel,users -s /bin/bash $_USERNAME
EOF

# Add menu
echo "Add bootmenu"
cat > /mnt/boot/loader/loader.conf <<EOF
default arch
timeout 0
editor 0
EOF

# Add core
echo "Add core to bootmenu"
echo "title   Arch Linux" > /mnt/boot/loader/entries/arch.conf
echo "linux   /vmlinuz-linux" >> /mnt/boot/loader/entries/arch.conf
echo "initrd  /initramfs-linux.img" >> /mnt/boot/loader/entries/arch.conf
echo "options cryptdevice=UUID=$(blkid -s UUID -o value $_CRYPTFS):cryptfs root=/dev/cryptfs/root quiet rw" >> /mnt/boot/loader/entries/arch.conf


echo "Setting user password for $_USERNAME" && arch-chroot /mnt /bin/passwd $_USERNAME
# Giving wheel user sudo access.
sed -i 's/# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/g' /mnt/etc/sudoers
echo "$_USERNAME    ALL=(ALL)    ALL" > /mnt/etc/sudoers.d/$_USERNAME

# Enabling NetworkManager.
systemctl enable NetworkManager --root=/mnt &>/dev/null

umount -R /mnt
sleep 3
cryptsetup close $_CRYPTFS
sleep 3
reboot
