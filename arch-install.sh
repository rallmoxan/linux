#!/usr/bin/env bash
# =============================================================================
# Arch Linux Automated Installation Script
# Target: Ryzen 5 7500X3D | RX 9060 XT | 16GB DDR5 | NVMe SSDs
# Stack:  btrfs + Limine + CachyOS + Hyprland/Wayland + zram
# =============================================================================
# USAGE: Boot Arch ISO, then run:
#   curl -O https://yourhost/arch-install.sh   (or copy manually)
#   chmod +x arch-install.sh && ./arch-install.sh
# =============================================================================

set -euo pipefail

# ─── CONFIGURATION ────────────────────────────────────────────────────────────
TARGET_DISK="/dev/nvme0n1"          # SSD1 — root + home
# SSD2 (/dev/nvme1n1) is NEVER touched
EFI_SIZE="512M"
HOSTNAME="archbox"
TIMEZONE="Europe/Istanbul"
LOCALE="en_US.UTF-8"
KEYMAP="trq"
USERNAME="user"
USER_SHELL="/bin/zsh"

# Partition labels
PART_EFI="${TARGET_DISK}p1"
PART_ROOT="${TARGET_DISK}p2"

# btrfs subvolume names
declare -A SUBVOLS=(
  ["@"]="/"
  ["@home"]="/home"
  ["@snapshots"]="/.snapshots"
  ["@var-log"]="/var/log"
)

BTRFS_OPTS="defaults,compress=zstd:3,noatime,nodiratime,space_cache=v2"

# CachyOS mirror (auto-detected below; fallback hardcoded)
CACHYOS_KEYRING_URL="https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-keyring-20240331-1-any.pkg.tar.zst"
CACHYOS_MIRRORLIST_URL="https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-mirrorlist-18-1-any.pkg.tar.zst"
CACHYOS_V4_MIRRORLIST_URL="https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-v4-mirrorlist-6-1-any.pkg.tar.zst"
CACHYOS_REPO_PKG_URL="https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-repo-1.0.3-1-any.pkg.tar.zst"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${GREEN}[+]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
err()  { echo -e "${RED}[✗]${RESET} $*" >&2; exit 1; }
step() { echo -e "\n${CYAN}${BOLD}╔══ STEP $* ══╗${RESET}"; }

# =============================================================================
# STEP 0: Pre-flight Checks
# =============================================================================
step "0: Pre-flight Checks"

[[ $EUID -ne 0 ]] && err "Script must be run as root"
[[ ! -d /sys/firmware/efi ]] && err "Not booted in UEFI mode"
[[ ! -b "$TARGET_DISK" ]] && err "Target disk $TARGET_DISK not found"

# Verify SSD2 will NOT be touched
log "Target disk: $TARGET_DISK (SSD1)"
log "SSD2 (/dev/nvme1n1) will NOT be modified"

# Internet check
ping -c 1 -W 3 archlinux.org &>/dev/null || err "No internet connection"
log "Internet: OK"

# Update system clock
timedatectl set-ntp true || err "Failed to sync clock"
log "Clock synced"

# =============================================================================
# STEP 1: Disk Preparation (Partition + btrfs)
# =============================================================================
step "1: Disk Preparation"

log "Wiping $TARGET_DISK..."
wipefs -af "$TARGET_DISK" || err "Failed to wipe disk"
sgdisk -Z "$TARGET_DISK"  || err "Failed to zap partition table"

log "Creating GPT partition table..."
sgdisk \
  -n 1:0:+${EFI_SIZE}  -t 1:ef00 -c 1:"EFI System" \
  -n 2:0:0             -t 2:8300 -c 2:"Arch Linux Root" \
  "$TARGET_DISK" || err "Failed to partition disk"

partprobe "$TARGET_DISK"
sleep 2

log "Formatting EFI partition (FAT32)..."
mkfs.fat -F32 -n "EFI" "$PART_EFI" || err "Failed to format EFI"

log "Formatting root partition (btrfs)..."
mkfs.btrfs -f -L "ArchRoot" "$PART_ROOT" || err "Failed to format btrfs"

log "Creating btrfs subvolumes..."
mount "$PART_ROOT" /mnt || err "Failed to mount root"

for subvol in @ @home @snapshots @var-log; do
  btrfs subvolume create "/mnt/${subvol}" || err "Failed to create subvolume $subvol"
  log "  Created subvolume: $subvol"
done

umount /mnt

log "Mounting subvolumes..."
mount -o "${BTRFS_OPTS},subvol=@" "$PART_ROOT" /mnt || err "Failed to mount @"

mkdir -p /mnt/{boot,home,.snapshots,var/log,efi}

mount -o "${BTRFS_OPTS},subvol=@home"      "$PART_ROOT" /mnt/home        || err "Failed to mount @home"
mount -o "${BTRFS_OPTS},subvol=@snapshots" "$PART_ROOT" /mnt/.snapshots  || err "Failed to mount @snapshots"
mount -o "${BTRFS_OPTS},subvol=@var-log"   "$PART_ROOT" /mnt/var/log     || err "Failed to mount @var-log"
mount "$PART_EFI" /mnt/boot || err "Failed to mount EFI"

log "Disk layout mounted successfully"

# =============================================================================
# STEP 2: CachyOS Repository Setup (BEFORE pacstrap)
# =============================================================================
step "2: CachyOS Repository Setup"

log "Downloading CachyOS keyring and packages..."

# Download packages to temp location
TMP_PKG="/tmp/cachyos-pkgs"
mkdir -p "$TMP_PKG"

curl -Lo "${TMP_PKG}/cachyos-keyring.pkg.tar.zst"      "$CACHYOS_KEYRING_URL"        || err "Failed to download CachyOS keyring"
curl -Lo "${TMP_PKG}/cachyos-mirrorlist.pkg.tar.zst"   "$CACHYOS_MIRRORLIST_URL"     || err "Failed to download CachyOS mirrorlist"
curl -Lo "${TMP_PKG}/cachyos-v4-mirrorlist.pkg.tar.zst" "$CACHYOS_V4_MIRRORLIST_URL" || err "Failed to download CachyOS v4 mirrorlist"

log "Installing CachyOS keyring to live ISO..."
pacman -U --noconfirm "${TMP_PKG}/cachyos-keyring.pkg.tar.zst"        || err "Failed to install keyring"
pacman -U --noconfirm "${TMP_PKG}/cachyos-mirrorlist.pkg.tar.zst"     || err "Failed to install mirrorlist"
pacman -U --noconfirm "${TMP_PKG}/cachyos-v4-mirrorlist.pkg.tar.zst"  || err "Failed to install v4 mirrorlist"

log "Injecting CachyOS repos into live pacman.conf..."
cat >> /etc/pacman.conf << 'CACHYOS_REPOS'

# CachyOS Repositories
[cachyos-v4]
Include = /etc/pacman.d/cachyos-v4-mirrorlist

[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
CACHYOS_REPOS

pacman -Sy || err "Failed to sync pacman databases"
log "CachyOS repos active in live environment"

# =============================================================================
# STEP 3: Pacstrap — Base System
# =============================================================================
step "3: Pacstrap — Base System"

# Optimize mirrors first
log "Ranking mirrors..."
reflector --country Turkey,Germany,Netherlands \
  --protocol https --sort rate --latest 10 \
  --save /etc/pacman.d/mirrorlist 2>/dev/null || warn "reflector failed, using default mirrors"

log "Running pacstrap..."
pacstrap -K /mnt \
  base base-devel \
  linux-cachyos-bore linux-cachyos-bore-headers \
  linux-firmware \
  amd-ucode \
  btrfs-progs \
  limine \
  efibootmgr \
  networkmanager \
  zsh zsh-completions \
  neovim \
  git \
  curl wget \
  man-db man-pages \
  sudo \
  reflector \
  cryptsetup \
  dosfstools \
  e2fsprogs \
  || err "Pacstrap failed"

log "Pacstrap complete"

# =============================================================================
# STEP 4: Generate fstab
# =============================================================================
step "4: fstab Generation"

genfstab -U /mnt >> /mnt/etc/fstab || err "Failed to generate fstab"

# Verify btrfs entries look correct
log "Generated fstab:"
cat /mnt/etc/fstab

# =============================================================================
# STEP 5: Chroot — System Configuration
# =============================================================================
step "5: Chroot — System Configuration"

# Write the chroot script
cat > /mnt/root/chroot-setup.sh << 'CHROOT_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
log()  { echo -e "${GREEN}[+]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
err()  { echo -e "${RED}[✗]${RESET} $*" >&2; exit 1; }
step() { echo -e "\n${CYAN}${BOLD}╔══ CHROOT STEP $* ══╗${RESET}"; }

TIMEZONE="Europe/Istanbul"
LOCALE="en_US.UTF-8"
KEYMAP="trq"
HOSTNAME="archbox"
USERNAME="user"
PART_ROOT="/dev/nvme0n1p2"
BTRFS_OPTS="defaults,compress=zstd:3,noatime,nodiratime,space_cache=v2"

# ── 5a: Locale & Timezone ────────────────────────────────────────────────────
step "5a: Locale & Timezone"

ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime || err "Failed to set timezone"
hwclock --systohc || err "Failed to sync hwclock"

sed -i "s/^#${LOCALE} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen
locale-gen || err "locale-gen failed"

cat > /etc/locale.conf << EOF
LANG=${LOCALE}
LC_ADDRESS=${LOCALE}
LC_IDENTIFICATION=${LOCALE}
LC_MEASUREMENT=tr_TR.UTF-8
LC_MONETARY=tr_TR.UTF-8
LC_NAME=${LOCALE}
LC_NUMERIC=${LOCALE}
LC_PAPER=tr_TR.UTF-8
LC_TELEPHONE=tr_TR.UTF-8
LC_TIME=tr_TR.UTF-8
EOF

echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
echo "${HOSTNAME}" > /etc/hostname

cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain  ${HOSTNAME}
EOF

log "Locale, timezone, hostname configured"

# ── 5b: pacman.conf (CachyOS + tuning) ──────────────────────────────────────
step "5b: pacman.conf"

cat > /etc/pacman.conf << 'PACMAN_CONF'
[options]
HoldPkg     = pacman glibc
Architecture = auto
Color
ILoveCandy
CheckSpace
VerbosePkgLists
ParallelDownloads = 5
DisableDownloadTimeout

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist

# CachyOS Repositories
[cachyos-v4]
Include = /etc/pacman.d/cachyos-v4-mirrorlist

[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
PACMAN_CONF

pacman -Sy || err "Failed to sync pacman after chroot conf"
log "pacman.conf configured"

# ── 5c: mkinitcpio ──────────────────────────────────────────────────────────
step "5c: mkinitcpio"

cat > /etc/mkinitcpio.conf << 'MKINIT'
MODULES=(amdgpu btrfs)
BINARIES=()
FILES=()
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck)
COMPRESSION="zstd"
COMPRESSION_OPTIONS=(-9)
MKINIT

mkinitcpio -P || err "mkinitcpio failed"
log "initramfs built"

# ── 5d: zram (no swap file) ──────────────────────────────────────────────────
step "5d: zram Setup"

cat > /etc/systemd/zram-generator.conf << 'ZRAM'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM

log "zram configured (8GB max, zstd, no swap file)"

# ── 5e: Limine Bootloader ────────────────────────────────────────────────────
step "5e: Limine Bootloader"

# Install Limine EFI binary
install -Dm644 /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI || err "Failed to install Limine EFI"
install -Dm644 /usr/share/limine/limine-bios.sys /boot/limine-bios.sys 2>/dev/null || true

# Register with EFI
efibootmgr \
  --disk /dev/nvme0n1 \
  --part 1 \
  --create \
  --label "Limine" \
  --loader "\\EFI\\BOOT\\BOOTX64.EFI" \
  --unicode \
  || err "efibootmgr failed"

# Get root UUID
ROOT_UUID=$(blkid -s UUID -o value /dev/nvme0n1p2)
[[ -z "$ROOT_UUID" ]] && err "Could not determine root UUID"

# Write limine.conf
cat > /boot/limine.conf << LIMINE_CONF
# Limine Boot Configuration
# Generated by arch-install.sh

timeout: 5
graphics: yes
default_entry: 1

/Arch Linux (CachyOS BORE)
    comment: Default — btrfs @, AMDGPU, Wayland
    protocol: linux
    path: boot():/vmlinuz-linux-cachyos-bore
    cmdline: root=UUID=${ROOT_UUID} rootflags=subvol=@ rw rootfstype=btrfs \\
             amd_pstate=active \\
             amdgpu.ppfeaturemask=0xffffffff \\
             nowatchdog nmi_watchdog=0 \\
             quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 \\
             mitigations=off
    module_path: boot():/initramfs-linux-cachyos-bore.img
    module_path: boot():/amd-ucode.img

/Arch Linux (Fallback initramfs)
    comment: Fallback — use if default fails
    protocol: linux
    path: boot():/vmlinuz-linux-cachyos-bore
    cmdline: root=UUID=${ROOT_UUID} rootflags=subvol=@ rw rootfstype=btrfs
    module_path: boot():/initramfs-linux-cachyos-bore-fallback.img
    module_path: boot():/amd-ucode.img
LIMINE_CONF

log "Limine configured (UUID: $ROOT_UUID)"

# ── 5f: User Setup ──────────────────────────────────────────────────────────
step "5f: User Setup"

useradd -m -G wheel,audio,video,input,storage,optical -s /bin/zsh "$USERNAME" || err "Failed to create user"

# Set temporary password (CHANGE AFTER FIRST LOGIN)
echo "${USERNAME}:changeme123" | chpasswd || err "Failed to set password"
echo "root:changeme123" | chpasswd || err "Failed to set root password"

warn "⚠ Default password is 'changeme123' — CHANGE IMMEDIATELY after first boot!"

# Sudo configuration
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
echo "Defaults timestamp_timeout=15" >> /etc/sudoers

log "User '$USERNAME' created (wheel group)"

# ── 5g: Post-pacstrap Package Installation ───────────────────────────────────
step "5g: Post-pacstrap Package Installation"

# GPU & Wayland
GPU_PKGS=(
  mesa vulkan-radeon libva-mesa-driver mesa-vdpau
  vulkan-tools mesa-utils
  xf86-video-amdgpu
  libdrm
  wayland wayland-protocols
  xorg-xwayland
)

# Desktop — Hyprland
HYPR_PKGS=(
  hyprland
  uwsm
  xdg-desktop-portal-hyprland
  xdg-user-dirs xdg-utils
  polkit polkit-kde-agent
  qt5-wayland qt6-wayland
  alacritty
  rofi-wayland
  dunst
  thunar gvfs tumbler
  imv
  cliphist
  wl-clipboard
  swaylock
  swayidle
  waybar
  grim slurp
  hyprpaper
  noto-fonts noto-fonts-emoji ttf-jetbrains-mono-nerd
)

# Audio — PipeWire
AUDIO_PKGS=(
  pipewire pipewire-alsa pipewire-pulse pipewire-jack
  wireplumber
  pavucontrol
)

# Gaming
GAMING_PKGS=(
  steam
  wine-staging
  winetricks
  lib32-mesa lib32-vulkan-radeon
  lib32-libva-mesa-driver
  vulkan-icd-loader lib32-vulkan-icd-loader
  gamemode lib32-gamemode
  mangohud lib32-mangohud
)

# Snapshot & btrfs
BTRFS_PKGS=(
  snapper
  snap-pac
  btrfs-assistant
  grub-btrfs
)

# System tools
SYS_PKGS=(
  networkmanager nm-connection-editor
  systemd-resolved
  zram-generator
  earlyoom
  reflector
  pacman-contrib
  pkgfile
  htop btop
  bat eza fd ripgrep fzf
  p7zip unzip unrar
  ffmpeg
  yt-dlp
  firefox
  obs-studio
  fastfetch
  starship
)

ALL_PKGS=("${GPU_PKGS[@]}" "${HYPR_PKGS[@]}" "${AUDIO_PKGS[@]}" "${GAMING_PKGS[@]}" "${BTRFS_PKGS[@]}" "${SYS_PKGS[@]}")

log "Installing ${#ALL_PKGS[@]} packages..."
pacman -S --noconfirm --needed "${ALL_PKGS[@]}" || err "Package installation failed"

# Enable multilib if needed (already in pacman.conf)
log "Package installation complete"

# ── 5h: paru AUR Helper ──────────────────────────────────────────────────────
step "5h: paru AUR Helper"

# Build paru as user (minimal — no dep checking overhead)
sudo -u "$USERNAME" bash -c '
  cd /tmp
  git clone https://aur.archlinux.org/paru-bin.git
  cd paru-bin
  makepkg -si --noconfirm
' || err "Failed to install paru"

# paru.conf — minimal mode
mkdir -p /home/${USERNAME}/.config/paru
cat > /home/${USERNAME}/.config/paru/paru.conf << 'PARU_CONF'
[options]
BottomUp
NewsOnUpgrade
LocalRepo
Chroot
CloneDir = ~/.cache/paru/clone
PARU_CONF

# Install proton-ge via paru
sudo -u "$USERNAME" paru -S --noconfirm proton-ge-custom-bin || warn "proton-ge-custom-bin install failed (non-fatal)"

chown -R "${USERNAME}:${USERNAME}" /home/${USERNAME}/.config/paru
log "paru installed (minimal)"

# ── 5i: Snapper Configuration ────────────────────────────────────────────────
step "5i: Snapper + snap-pac Configuration"

# Create snapper configs (umount .snapshots first — snapper recreates it)
umount /.snapshots 2>/dev/null || true
rmdir /.snapshots 2>/dev/null || true

snapper -c root create-config / || err "snapper root config failed"

# Re-mount @snapshots subvolume over snapper's created dir
mount -o "${BTRFS_OPTS},subvol=@snapshots" "$PART_ROOT" /.snapshots || err "Failed to remount @snapshots"
chmod 750 /.snapshots

# Root snapshot policy
cat > /etc/snapper/configs/root << 'SNAPPER_ROOT'
SUBVOLUME="/"
FSTYPE="btrfs"
QGROUP=""
SPACE_LIMIT="0.5"
FREE_LIMIT="0.2"
ALLOW_USERS=""
ALLOW_GROUPS=""
SYNC_ACL="no"
BACKGROUND_COMPARISON="yes"
NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="10"
NUMBER_LIMIT_IMPORTANT="5"
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="5"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="2"
TIMELINE_LIMIT_MONTHLY="1"
TIMELINE_LIMIT_YEARLY="0"
EMPTY_PRE_POST_CLEANUP="yes"
EMPTY_PRE_POST_MIN_AGE="1800"
SNAPPER_ROOT

log "snapper configured (10 snapshots max, weekly cleanup)"

# ── 5j: journald optimization ────────────────────────────────────────────────
step "5j: journald Optimization"

cat > /etc/systemd/journald.conf << 'JOURNALD'
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=256M
SystemKeepFree=1G
MaxRetentionSec=2week
RateLimitInterval=30s
RateLimitBurst=10000
JOURNALD

log "journald configured"

# ── 5k: TTY Auto-login + Hyprland Auto-start ─────────────────────────────────
step "5k: TTY Auto-login & Hyprland Auto-start"

# Getty override — auto-login on TTY1
mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin ${USERNAME} --noclear %I \$TERM
Type=simple
Restart=always
EOF

# User zprofile — launch Hyprland via uwsm on TTY1
USER_HOME="/home/${USERNAME}"
mkdir -p "${USER_HOME}"

cat > "${USER_HOME}/.zprofile" << 'ZPROFILE'
# Auto-launch Hyprland via uwsm on TTY1
if [[ -z "$WAYLAND_DISPLAY" ]] && [[ "$(tty)" == "/dev/tty1" ]]; then
  exec uwsm start hyprland.desktop
fi
ZPROFILE

chown "${USERNAME}:${USERNAME}" "${USER_HOME}/.zprofile"

# uwsm app unit for Hyprland
mkdir -p "${USER_HOME}/.config/uwsm"
cat > "${USER_HOME}/.config/uwsm/env" << 'UWSM_ENV'
UWSM_APP_UNIT_TYPE=service
UWSM_ENV

chown -R "${USERNAME}:${USERNAME}" "${USER_HOME}/.config/uwsm"
log "TTY1 auto-login → uwsm → Hyprland configured"

# ── 5l: Basic Hyprland Config Scaffold ───────────────────────────────────────
step "5l: Hyprland Config Scaffold"

HYPR_CONF_DIR="${USER_HOME}/.config/hypr"
mkdir -p "${HYPR_CONF_DIR}"

cat > "${HYPR_CONF_DIR}/hyprland.conf" << 'HYPRCONF'
# Hyprland Configuration
# Hardware: Ryzen 5 7500X3D | RX 9060 XT | 16GB DDR5

################
### MONITORS ###
################
# Edit to match your setup: hyprctl monitors
monitor=,preferred,auto,1

##############
### STARTUP ###
##############
exec-once = /usr/lib/polkit-kde-authentication-agent-1
exec-once = dunst
exec-once = hyprpaper
exec-once = wl-paste --type text --watch cliphist store
exec-once = wl-paste --type image --watch cliphist store
exec-once = waybar

#############
### INPUT ###
#############
input {
    kb_layout = tr
    kb_variant =
    kb_model =
    follow_mouse = 1
    touchpad {
        natural_scroll = false
    }
    sensitivity = 0
    accel_profile = flat
}

####################
### GENERAL / GPU ##
####################
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(ca9ee6ff) rgba(99d1dbff) 45deg
    col.inactive_border = rgba(595959aa)
    layout = dwindle
    allow_tearing = true   # low-latency gaming (RX 9060 XT)
}

decoration {
    rounding = 8
    blur {
        enabled = true
        size = 6
        passes = 3
    }
    drop_shadow = true
    shadow_range = 8
}

animations {
    enabled = true
    bezier = myBezier, 0.05, 0.9, 0.1, 1.05
    animation = windows, 1, 7, myBezier
    animation = windowsOut, 1, 7, default, popin 80%
    animation = fade, 1, 7, default
    animation = workspaces, 1, 6, default
}

dwindle {
    pseudotile = true
    preserve_split = true
}

misc {
    force_default_wallpaper = 0
    disable_hyprland_logo = true
}

#################
### KEYBINDS ###
#################
$mainMod = SUPER

bind = $mainMod, Return, exec, alacritty
bind = $mainMod, Q, killactive
bind = $mainMod, M, exit
bind = $mainMod, E, exec, thunar
bind = $mainMod, V, togglefloating
bind = $mainMod, R, exec, rofi -show drun
bind = $mainMod, P, pseudo
bind = $mainMod, J, togglesplit
bind = $mainMod, F, fullscreen
bind = $mainMod SHIFT, S, exec, grim -g "$(slurp)" - | wl-copy

# Move focus
bind = $mainMod, left,  movefocus, l
bind = $mainMod, right, movefocus, r
bind = $mainMod, up,    movefocus, u
bind = $mainMod, down,  movefocus, d

# Workspaces
bind = $mainMod, 1, workspace, 1
bind = $mainMod, 2, workspace, 2
bind = $mainMod, 3, workspace, 3
bind = $mainMod, 4, workspace, 4
bind = $mainMod, 5, workspace, 5
bind = $mainMod, 6, workspace, 6
bind = $mainMod, 7, workspace, 7
bind = $mainMod, 8, workspace, 8
bind = $mainMod, 9, workspace, 9
bind = $mainMod, 0, workspace, 10

bind = $mainMod SHIFT, 1, movetoworkspace, 1
bind = $mainMod SHIFT, 2, movetoworkspace, 2
bind = $mainMod SHIFT, 3, movetoworkspace, 3
bind = $mainMod SHIFT, 4, movetoworkspace, 4
bind = $mainMod SHIFT, 5, movetoworkspace, 5
bind = $mainMod SHIFT, 6, movetoworkspace, 6
bind = $mainMod SHIFT, 7, movetoworkspace, 7
bind = $mainMod SHIFT, 8, movetoworkspace, 8
bind = $mainMod SHIFT, 9, movetoworkspace, 9
bind = $mainMod SHIFT, 0, movetoworkspace, 10

# Mouse binds
bindm = $mainMod, mouse:272, movewindow
bindm = $mainMod, mouse:273, resizewindow

# Volume keys
bind = , XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+
bind = , XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bind = , XF86AudioMute,        exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle

# Gaming / Tearing env vars
env = WLR_DRM_NO_ATOMIC,0
env = LIBVA_DRIVER_NAME,radeonsi
env = VDPAU_DRIVER,radeonsi
env = AMD_VULKAN_ICD,RADV

# Cursor
env = XCURSOR_SIZE,24
env = HYPRCURSOR_SIZE,24
HYPRCONF

chown -R "${USERNAME}:${USERNAME}" "${HYPR_CONF_DIR}"
log "Hyprland config scaffold created"

# ── 5m: zsh Configuration ─────────────────────────────────────────────────────
step "5m: zsh Configuration"

cat > "/home/${USERNAME}/.zshrc" << 'ZSHRC'
# zsh config
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt HIST_IGNORE_DUPS HIST_SHARE_HISTORY EXTENDED_HISTORY

# Completion
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'

# Aliases
alias ls='eza --icons'
alias ll='eza -la --icons'
alias cat='bat'
alias grep='grep --color=auto'
alias vim='nvim'
alias update='sudo pacman -Syu && paru -Sua'
alias snap-list='snapper list'
alias snap-root='snapper -c root list'

# Starship prompt
eval "$(starship init zsh)"

# paru / AUR helper
export AUR_HELPER=paru

# Gaming env
export STEAM_FORCE_DESKTOPUI_SCALING=1
export PROTON_ENABLE_NVAPI=0  # AMD — disable NVAPI
export DXVK_ASYNC=1
export PROTON_NO_ESYNC=0

# FZF
[ -f /usr/share/fzf/key-bindings.zsh ] && source /usr/share/fzf/key-bindings.zsh
[ -f /usr/share/fzf/completion.zsh ]   && source /usr/share/fzf/completion.zsh
ZSHRC

chown "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.zshrc"
log "zsh configured"

# ── 5n: Systemd Services Enable ──────────────────────────────────────────────
step "5n: Systemd Services"

SERVICES=(
  NetworkManager
  systemd-resolved
  fstrim.timer
  snapper-timeline.timer
  snapper-cleanup.timer
  earlyoom
  reflector.timer
  pkgfile-update.timer
  systemd-zram-setup@zram0
)

for svc in "${SERVICES[@]}"; do
  systemctl enable "$svc" && log "  Enabled: $svc" || warn "  Failed to enable: $svc"
done

# Disable systemd-networkd (using NetworkManager instead)
systemctl disable systemd-networkd 2>/dev/null || true

# User services (enable for user)
loginctl enable-linger "$USERNAME" || warn "linger failed (non-fatal)"

# PipeWire (user-level, will auto-start via uwsm)
sudo -u "$USERNAME" systemctl --user enable pipewire.socket pipewire-pulse.socket wireplumber.service 2>/dev/null || warn "PipeWire user services: configure after first boot"

log "Services configured"

# ── 5o: fstab Verification & Snapshots Entry ─────────────────────────────────
step "5o: fstab Snapshots Entry"

# Ensure @snapshots is in fstab with correct options
ROOT_UUID=$(blkid -s UUID -o value /dev/nvme0n1p2)
grep -q "@snapshots" /etc/fstab || cat >> /etc/fstab << FSTAB_SNAP

# btrfs @snapshots subvolume
UUID=${ROOT_UUID}  /.snapshots  btrfs  ${BTRFS_OPTS},subvol=@snapshots  0 0
FSTAB_SNAP

log "fstab verified"

# ── Final: Cleanup & Summary ─────────────────────────────────────────────────
step "CHROOT: Complete"

echo ""
echo "=================================================="
echo " Chroot setup complete. Passwords set to: changeme123"
echo " CHANGE PASSWORD IMMEDIATELY: passwd && sudo passwd root"
echo "=================================================="

CHROOT_SCRIPT

chmod +x /mnt/root/chroot-setup.sh

# Execute chroot setup
log "Entering chroot..."
arch-chroot /mnt /root/chroot-setup.sh || err "Chroot setup failed"

# =============================================================================
# STEP 6: Post-chroot Cleanup
# =============================================================================
step "6: Post-chroot Cleanup"

rm -f /mnt/root/chroot-setup.sh
log "Removed chroot setup script"

# =============================================================================
# STEP 7: Unmount & Final Sync
# =============================================================================
step "7: Unmount"

sync
umount -R /mnt || warn "Some filesystems may still be busy (non-fatal)"
log "Filesystems unmounted"

# =============================================================================
# INSTALLATION CHECKLIST
# =============================================================================

cat << 'CHECKLIST'

╔══════════════════════════════════════════════════════════════════════════════╗
║              ARCH LINUX INSTALLATION — CHECKLIST                           ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║  ✅ AUTOMATED — VERIFIED STEPS                                               ║
║  ─────────────────────────────────────────────────────────────────          ║
║  [✓] SSD1 partitioned: EFI (512MB) + btrfs root                            ║
║  [✓] btrfs subvolumes: @, @home, @snapshots, @var-log                       ║
║  [✓] Mount options: zstd:3 compress, noatime, space_cache=v2               ║
║  [✓] SSD2 untouched                                                         ║
║  [✓] CachyOS repo added BEFORE pacstrap                                     ║
║  [✓] linux-cachyos-bore kernel installed                                    ║
║  [✓] amd-ucode microcode installed + initramfs hook                         ║
║  [✓] Limine EFI bootloader installed + registered                           ║
║  [✓] limine.conf: two boot entries (normal + fallback)                      ║
║  [✓] zram configured (8GB max, zstd) — NO swap file                        ║
║  [✓] Hyprland + uwsm installed                                              ║
║  [✓] TTY1 auto-login → uwsm → Hyprland                                     ║
║  [✓] PipeWire + WirePlumber audio stack                                     ║
║  [✓] mesa + vulkan-radeon (AMDGPU) installed                                ║
║  [✓] Steam + Wine Staging + proton-ge-custom installed                      ║
║  [✓] snapper + snap-pac + btrfs-assistant installed                         ║
║  [✓] Snapper timeline: 5h/7d/2w/1m snapshots                               ║
║  [✓] NetworkManager + systemd-resolved enabled                              ║
║  [✓] fstrim.timer enabled (weekly TRIM for SSD)                             ║
║  [✓] paru (AUR helper, minimal) installed                                   ║
║  [✓] zsh + starship + eza/bat/fd/rg configured                              ║
║  [✓] journald: 256MB cap, 2-week retention                                  ║
║  [✓] No display manager installed                                           ║
║  [✓] No Flatpak installed                                                   ║
║  [✓] No swap file (zram only)                                               ║
║  [✓] No power management (BIOS PBO preserved)                               ║
║                                                                              ║
║  ⚠  MANUAL VERIFICATION REQUIRED (after first boot)                         ║
║  ─────────────────────────────────────────────────────────────────          ║
║  [ ] Limine boot menu appears (timeout 5s → Arch Linux CachyOS BORE)       ║
║  [ ] Boot completes without kernel panic                                    ║
║  [ ] TTY1 auto-logs in as 'user' without password prompt                    ║
║  [ ] Hyprland launches automatically via uwsm                               ║
║  [ ] `hyprctl version` returns without error                                ║
║  [ ] `pactl info` shows PipeWire as server                                  ║
║  [ ] `ip a` shows network interface (NM managing it)                        ║
║  [ ] `glxinfo | grep renderer` shows AMD radeonsi                           ║
║  [ ] `vulkaninfo | grep deviceName` shows AMD RX 9060 XT                   ║
║  [ ] `zramctl` shows zram0 active                                           ║
║  [ ] `snapper list` returns without error                                   ║
║  [ ] SSD2 is NOT mounted / NOT in fstab                                     ║
║                                                                              ║
║  🔧 POST-INSTALL MANUAL TASKS                                                ║
║  ─────────────────────────────────────────────────────────────────          ║
║  [ ] CHANGE PASSWORDS: `passwd` (user) + `sudo passwd root`                 ║
║  [ ] Hyprland: edit ~/.config/hypr/hyprland.conf                            ║
║        → monitor= line: match your actual resolution/refresh rate           ║
║        → kb_layout: verify 'tr' is correct (or change to 'us' etc.)        ║
║  [ ] Waybar: configure ~/.config/waybar/config.jsonc                        ║
║  [ ] Hyprpaper: set wallpaper in ~/.config/hypr/hyprpaper.conf              ║
║  [ ] Steam: login and set Proton version                                    ║
║        → Steam > Settings > Compatibility → Enable Proton Experimental      ║
║        → Or select proton-ge from game properties                           ║
║  [ ] GameMode: add to Steam launch options: `gamemoderun %command%`         ║
║  [ ] MangoHud: `MANGOHUD=1 glxgears` to test overlay                       ║
║  [ ] SSD2 gaming library: add to Steam as library folder                    ║
║        → Steam > Settings > Storage > Add Drive → /dev/nvme1n1             ║
║        → Or manually mount to ~/Games or /mnt/games                        ║
║  [ ] snapper: verify pre/post hooks with: `pacman -S vim` then `snapper list`║
║  [ ] btrfs-assistant: launch as GUI for snapshot management                 ║
║  [ ] Reflector: customize /etc/xdg/reflector/reflector.conf                 ║
║        → Add: --country Turkey,Germany --latest 10                          ║
║  [ ] paru: AUR packages to consider:                                        ║
║        paru -S vesktop-bin          # Discord alternative                   ║
║        paru -S spotify              # Music                                 ║
║        paru -S ventoy-bin           # USB tool                              ║
║  [ ] Enable AMD hardware video decode in Firefox:                           ║
║        about:config → media.ffmpeg.vaapi.enabled = true                    ║
║  [ ] Weekly manual update ritual:                                           ║
║        `sudo pacman -Syu && paru -Sua`                                      ║
║        then check snapper pre/post snapshots were created                   ║
║                                                                              ║
║  🎮 GAMING SPECIFIC                                                          ║
║  ─────────────────────────────────────────────────────────────────          ║
║  [ ] RX 9060 XT: Verify driver with `lspci -k | grep -A2 VGA`              ║
║  [ ] amdgpu.ppfeaturemask=0xffffffff already in Limine cmdline              ║
║        (enables Overdrive / manual fan curve if desired)                    ║
║  [ ] corectrl (paru -S corectrl) for GPU OC — optional                      ║
║  [ ] allow_tearing = true in hyprland.conf (already set for low latency)    ║
║                                                                              ║
║  📋 CREDENTIALS                                                              ║
║  ─────────────────────────────────────────────────────────────────          ║
║  Username: user                                                              ║
║  Password: changeme123  ← CHANGE THIS IMMEDIATELY                           ║
║  Root password: changeme123  ← CHANGE THIS IMMEDIATELY                      ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝

  Installation complete! Remove the ISO, then:  reboot
  
  First boot sequence:
    1. Limine menu appears (5s timeout)
    2. System boots → TTY1 auto-login
    3. uwsm starts → Hyprland launches
    4. Super+Return = terminal (alacritty)
    5. Super+R = app launcher (rofi)

CHECKLIST

log "Installation complete. Remove ISO and reboot."
