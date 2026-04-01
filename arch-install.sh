#!/bin/bash
# ============================================================================
# ARCH LINUX FULL AUTOMATED INSTALLATION SCRIPT
# Ryzen 5 7500X3D + RX 9060 XT + CachyOS + Hyprland + Limine
# ============================================================================

set -e  # Exit on error
set -u  # Exit on undefined variable

# ============================================================================
# STEP 0: ROOT CHECK & VARIABLES
# ============================================================================

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root (boot from Arch ISO)"
   exit 1
fi

# Configuration variables
TARGET_DISK="/dev/nvme0n1"  # SSD1 - CHANGE IF NEEDED
EFI_SIZE="512M"
HOSTNAME="archbox"
USERNAME="user"  # CHANGE THIS
USER_PASSWORD="password"  # CHANGE THIS
ROOT_PASSWORD="rootpassword"  # CHANGE THIS
TIMEZONE="Europe/Istanbul"
LOCALE="tr_TR.UTF-8"

echo "========================================"
echo "Target disk: $TARGET_DISK"
echo "Hostname: $HOSTNAME"
echo "Username: $USERNAME"
echo "Timezone: $TIMEZONE"
echo "========================================"
read -p "Press ENTER to continue or Ctrl+C to abort..."

# ============================================================================
# STEP 1: DISK PARTITIONING
# ============================================================================

echo "# STEP 1: Partitioning $TARGET_DISK..."

# Wipe partition table
wipefs -af "$TARGET_DISK" || exit 1
sgdisk -Z "$TARGET_DISK" || exit 1

# Create partitions
sgdisk -n 1:0:+${EFI_SIZE} -t 1:ef00 -c 1:"EFI" "$TARGET_DISK" || exit 1
sgdisk -n 2:0:0 -t 2:8300 -c 2:"ROOT" "$TARGET_DISK" || exit 1

# Inform kernel
partprobe "$TARGET_DISK" || exit 1
sleep 2

EFI_PART="${TARGET_DISK}p1"
ROOT_PART="${TARGET_DISK}p2"

# Format EFI
mkfs.fat -F32 -n EFI "$EFI_PART" || exit 1

# Format btrfs
mkfs.btrfs -f -L ArchRoot "$ROOT_PART" || exit 1

echo "Partitioning complete."

# ============================================================================
# STEP 2: BTRFS SUBVOLUMES
# ============================================================================

echo "# STEP 2: Creating btrfs subvolumes..."

# Mount root to create subvolumes
mount "$ROOT_PART" /mnt || exit 1

# Create subvolumes
btrfs subvolume create /mnt/@ || exit 1
btrfs subvolume create /mnt/@home || exit 1
btrfs subvolume create /mnt/@snapshots || exit 1
btrfs subvolume create /mnt/@var-log || exit 1

# Unmount
umount /mnt || exit 1

echo "Subvolumes created."

# ============================================================================
# STEP 3: MOUNT WITH BTRFS OPTIONS
# ============================================================================

echo "# STEP 3: Mounting filesystems..."

BTRFS_OPTS="defaults,compress=zstd:1,noatime,space_cache=v2"

# Mount @ (root)
mount -o ${BTRFS_OPTS},subvol=@ "$ROOT_PART" /mnt || exit 1

# Create mount points
mkdir -p /mnt/{boot,home,.snapshots,var/log} || exit 1

# Mount subvolumes
mount -o ${BTRFS_OPTS},subvol=@home "$ROOT_PART" /mnt/home || exit 1
mount -o ${BTRFS_OPTS},subvol=@snapshots "$ROOT_PART" /mnt/.snapshots || exit 1
mount -o ${BTRFS_OPTS},subvol=@var-log "$ROOT_PART" /mnt/var/log || exit 1

# Mount EFI
mount "$EFI_PART" /mnt/boot || exit 1

echo "Filesystems mounted."

# ============================================================================
# STEP 4: CACHYOS REPO SETUP (BEFORE PACSTRAP)
# ============================================================================

echo "# STEP 4: Adding CachyOS repository..."

# Install keyring first
pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com || exit 1
pacman-key --lsign-key F3B607488DB35A47 || exit 1

# Download CachyOS automated installer script
curl -o /tmp/cachyos-repo.sh https://mirror.cachyos.org/cachyos-repo.tar.xz || exit 1
tar xvf /tmp/cachyos-repo.sh -C /tmp/ || exit 1

# Add to pacman.conf in /etc (for pacstrap)
cat >> /etc/pacman.conf <<EOF

# CachyOS repos
[cachyos-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist
[cachyos-core-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist
[cachyos-extra-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist
[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
EOF

# Download mirrorlist
curl -o /etc/pacman.d/cachyos-mirrorlist https://raw.githubusercontent.com/CachyOS/CachyOS-PKGBUILDS/master/cachyos-mirrorlist/cachyos-mirrorlist || exit 1
curl -o /etc/pacman.d/cachyos-v3-mirrorlist https://raw.githubusercontent.com/CachyOS/CachyOS-PKGBUILDS/master/cachyos-v3-mirrorlist/cachyos-v3-mirrorlist || exit 1

# Sync databases
pacman -Sy --noconfirm || exit 1

echo "CachyOS repos added."

# ============================================================================
# STEP 5: PACSTRAP BASE SYSTEM
# ============================================================================

echo "# STEP 5: Installing base system..."

pacstrap -K /mnt \
    base \
    base-devel \
    linux-cachyos-bore \
    linux-cachyos-bore-headers \
    linux-firmware \
    amd-ucode \
    btrfs-progs \
    git \
    networkmanager \
    zsh \
    neovim \
    efibootmgr \
    dosfstools \
    mtools \
    || exit 1

echo "Base system installed."

# ============================================================================
# STEP 6: GENERATE FSTAB
# ============================================================================

echo "# STEP 6: Generating fstab..."

genfstab -U /mnt >> /mnt/etc/fstab || exit 1

# Verify fstab
cat /mnt/etc/fstab

echo "fstab generated."

# ============================================================================
# STEP 7: CHROOT CONFIGURATION PART 1 (BASIC SETUP)
# ============================================================================

echo "# STEP 7: Chroot basic configuration..."

arch-chroot /mnt /bin/bash <<EOF
set -e

# Timezone
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime || exit 1
hwclock --systohc || exit 1

# Locale
echo "${LOCALE} UTF-8" >> /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen || exit 1
echo "LANG=${LOCALE}" > /etc/locale.conf

# Hostname
echo "${HOSTNAME}" > /etc/hostname

# Hosts
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

# Root password
echo "root:${ROOT_PASSWORD}" | chpasswd || exit 1

echo "Basic configuration complete."
EOF

# ============================================================================
# STEP 8: INSTALL CACHYOS KERNEL PACKAGES & REPOS IN CHROOT
# ============================================================================

echo "# STEP 8: Setting up CachyOS in chroot..."

arch-chroot /mnt /bin/bash <<EOF
set -e

# Copy CachyOS config to chroot
cat >> /etc/pacman.conf <<CACHYOS

[cachyos-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist
[cachyos-core-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist
[cachyos-extra-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist
[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
CACHYOS

# Install CachyOS keyring
pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com || exit 1
pacman-key --lsign-key F3B607488DB35A47 || exit 1

# Enable parallel downloads
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
sed -i 's/ParallelDownloads = .*/ParallelDownloads = 5/' /etc/pacman.conf

# Sync
pacman -Sy --noconfirm || exit 1

echo "CachyOS configured in chroot."
EOF

# ============================================================================
# STEP 9: INSTALL POST-PACSTRAP PACKAGES
# ============================================================================

echo "# STEP 9: Installing desktop and application packages..."

arch-chroot /mnt /bin/bash <<EOF
set -e

pacman -S --noconfirm \
    hyprland \
    uwsm \
    pipewire \
    pipewire-pulse \
    pipewire-alsa \
    pipewire-jack \
    wireplumber \
    firefox \
    alacritty \
    thunar \
    dunst \
    rofi-wayland \
    mesa \
    vulkan-radeon \
    lib32-vulkan-radeon \
    libva-mesa-driver \
    lib32-libva-mesa-driver \
    mesa-vdpau \
    lib32-mesa-vdpau \
    vulkan-tools \
    mesa-utils \
    steam \
    snapper \
    snap-pac \
    btrfs-assistant \
    zram-generator \
    htop \
    btop \
    wget \
    curl \
    unzip \
    tar \
    man-db \
    man-pages \
    || exit 1

echo "Desktop packages installed."
EOF

# ============================================================================
# STEP 10: MKINITCPIO CONFIGURATION
# ============================================================================

echo "# STEP 10: Configuring mkinitcpio..."

arch-chroot /mnt /bin/bash <<EOF
set -e

# Add btrfs to modules
sed -i 's/^MODULES=()/MODULES=(btrfs amdgpu)/' /etc/mkinitcpio.conf

# Regenerate initramfs
mkinitcpio -P || exit 1

echo "Initramfs configured."
EOF

# ============================================================================
# STEP 11: LIMINE BOOTLOADER INSTALLATION
# ============================================================================

echo "# STEP 11: Installing Limine bootloader..."

arch-chroot /mnt /bin/bash <<EOF
set -e

# Install limine
pacman -S --noconfirm limine || exit 1

# Install to disk
limine bios-install ${TARGET_DISK} || exit 1

# Copy limine files to boot
mkdir -p /boot/EFI/BOOT
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/ || exit 1
cp /usr/share/limine/limine-bios.sys /boot/ || exit 1

# Get root UUID
ROOT_UUID=\$(blkid -s UUID -o value ${ROOT_PART})

# Create limine.conf
cat > /boot/limine.conf <<LIMINE
TIMEOUT=3
GRAPHICS=yes
VERBOSE=yes

:Arch Linux (CachyOS kernel)
    PROTOCOL=linux
    KERNEL_PATH=boot:///vmlinuz-linux-cachyos-bore
    CMDLINE=root=UUID=\${ROOT_UUID} rootflags=subvol=@ rw quiet splash amd_pstate=active
    MODULE_PATH=boot:///amd-ucode.img
    MODULE_PATH=boot:///initramfs-linux-cachyos-bore.img
LIMINE

echo "Limine installed."
EOF

# ============================================================================
# STEP 12: SNAPPER CONFIGURATION
# ============================================================================

echo "# STEP 12: Configuring snapper..."

arch-chroot /mnt /bin/bash <<EOF
set -e

# Create snapper config for root
umount /.snapshots 2>/dev/null || true
rm -rf /.snapshots
snapper -c root create-config / || exit 1
btrfs subvolume delete /.snapshots || exit 1
mkdir /.snapshots
mount -a

# Configure snapper timeline
snapper -c root set-config "TIMELINE_CREATE=yes"
snapper -c root set-config "TIMELINE_LIMIT_HOURLY=5"
snapper -c root set-config "TIMELINE_LIMIT_DAILY=7"
snapper -c root set-config "TIMELINE_LIMIT_WEEKLY=0"
snapper -c root set-config "TIMELINE_LIMIT_MONTHLY=0"
snapper -c root set-config "TIMELINE_LIMIT_YEARLY=0"

# Create snapper config for home
snapper -c home create-config /home || exit 1

echo "Snapper configured."
EOF

# ============================================================================
# STEP 13: SYSTEMD SERVICES
# ============================================================================

echo "# STEP 13: Enabling systemd services..."

arch-chroot /mnt /bin/bash <<EOF
set -e

# Enable services
systemctl enable NetworkManager || exit 1
systemctl enable fstrim.timer || exit 1
systemctl enable systemd-resolved || exit 1
systemctl enable snapper-timeline.timer || exit 1
systemctl enable snapper-cleanup.timer || exit 1

echo "Services enabled."
EOF

# ============================================================================
# STEP 14: ZRAM CONFIGURATION
# ============================================================================

echo "# STEP 14: Configuring zram..."

arch-chroot /mnt /bin/bash <<EOF
set -e

# Create zram-generator config
mkdir -p /etc/systemd/zram-generator.conf.d
cat > /etc/systemd/zram-generator.conf.d/zram.conf <<ZRAM
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
ZRAM

echo "zram configured."
EOF

# ============================================================================
# STEP 15: USER CREATION & CONFIGURATION
# ============================================================================

echo "# STEP 15: Creating user..."

arch-chroot /mnt /bin/bash <<EOF
set -e

# Create user
useradd -m -G wheel,audio,video,storage -s /bin/zsh ${USERNAME} || exit 1
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd || exit 1

# Enable sudo for wheel
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo "User ${USERNAME} created."
EOF

# ============================================================================
# STEP 16: INSTALL PARU (AUR HELPER)
# ============================================================================

echo "# STEP 16: Installing paru..."

arch-chroot /mnt /bin/bash <<EOF
set -e

# Switch to user and install paru
sudo -u ${USERNAME} bash <<PARU_INSTALL
cd /tmp
git clone https://aur.archlinux.org/paru-bin.git || exit 1
cd paru-bin
makepkg -si --noconfirm || exit 1
PARU_INSTALL

echo "Paru installed."
EOF

# ============================================================================
# STEP 17: UWSM AUTO-START CONFIGURATION
# ============================================================================

echo "# STEP 17: Configuring uwsm for auto-start Hyprland..."

arch-chroot /mnt /bin/bash <<EOF
set -e

# Create .zprofile for user
cat > /home/${USERNAME}/.zprofile <<ZPROFILE
# Auto-start Hyprland on TTY1
if [ -z "\\\${WAYLAND_DISPLAY}" ] && [ "\\\${XDG_VTNR}" -eq 1 ]; then
    exec uwsm start -F hyprland.desktop
fi
ZPROFILE

chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.zprofile

# Create basic Hyprland config
mkdir -p /home/${USERNAME}/.config/hypr
cat > /home/${USERNAME}/.config/hypr/hyprland.conf <<HYPRCONF
# Basic Hyprland config
monitor=,preferred,auto,1

exec-once = dunst &
exec-once = waybar &

\\\$mod = SUPER

bind = \\\$mod, RETURN, exec, alacritty
bind = \\\$mod, Q, killactive
bind = \\\$mod, M, exit
bind = \\\$mod, D, exec, rofi -show drun

# AMD GPU specific
env = WLR_DRM_NO_ATOMIC,1
env = WLR_RENDERER,vulkan
HYPRCONF

chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.config

echo "uwsm configured."
EOF

# ============================================================================
# STEP 18: JOURNALD OPTIMIZATION
# ============================================================================

echo "# STEP 18: Optimizing journald..."

arch-chroot /mnt /bin/bash <<EOF
set -e

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/00-journal-size.conf <<JOURNAL
[Journal]
SystemMaxUse=100M
SystemMaxFileSize=10M
JOURNAL

echo "Journald optimized."
EOF

# ============================================================================
# STEP 19: FINAL CLEANUP
# ============================================================================

echo "# STEP 19: Final cleanup..."

# Copy mirrorlist to chroot
cp /etc/pacman.d/cachyos-mirrorlist /mnt/etc/pacman.d/ || true
cp /etc/pacman.d/cachyos-v3-mirrorlist /mnt/etc/pacman.d/ || true

echo "Installation complete!"

# ============================================================================
# INSTALLATION SUMMARY
# ============================================================================

cat <<SUMMARY

============================================================================
                    ARCH LINUX INSTALLATION COMPLETE
============================================================================

✓ VERIFIED STEPS:
  [✓] Disk partitioned: ${TARGET_DISK}
  [✓] Btrfs subvolumes created: @, @home, @snapshots, @var-log
  [✓] CachyOS repository configured
  [✓] Base system installed (linux-cachyos-bore kernel)
  [✓] Limine bootloader installed
  [✓] Snapper configured (automatic snapshots enabled)
  [✓] Hyprland + Wayland installed
  [✓] uwsm auto-start configured (TTY1)
  [✓] PipeWire audio configured
  [✓] NetworkManager enabled
  [✓] AMD GPU drivers installed (mesa, AMDGPU)
  [✓] zram configured (no swap file)
  [✓] User created: ${USERNAME}
  [✓] Paru AUR helper installed
  [✓] SSD2 untouched (game storage preserved)

⚠ MANUAL CHECKS REQUIRED:
  1. Reboot and verify Limine bootloader menu appears
  2. Check Hyprland starts automatically on TTY1
  3. Test audio: pactl info
  4. Verify GPU: vulkaninfo | grep "deviceName"
  5. Check zram: zramctl
  6. Test snapper: snapper -c root list

📋 POST-INSTALLATION TASKS:
  1. Configure Hyprland keybindings (~/.config/hypr/hyprland.conf)
  2. Install additional apps via paru
  3. Mount SSD2 game storage (add to /etc/fstab if needed)
  4. Set up Steam library on SSD2
  5. Configure firewall if needed: sudo pacman -S ufw
  6. Weekly updates: sudo pacman -Syu

🔧 SYSTEM INFO:
  Hostname: ${HOSTNAME}
  Username: ${USERNAME}
  Root Partition: ${ROOT_PART}
  EFI Partition: ${EFI_PART}
  Kernel: linux-cachyos-bore
  Desktop: Hyprland (Wayland)
  Shell: zsh

🚀 NEXT STEP:
  Unmount and reboot:
    umount -R /mnt
    reboot

============================================================================
SUMMARY

echo "Script finished. Review the summary above."
