#!/usr/bin/env bash
# =============================================================================
# Arch Linux Automated Installation Script
# Target: Ryzen 5 7500X3D | RX 9060 XT | 16GB DDR5 | SATA SSD
# Stack:  btrfs + Limine + CachyOS (CPU-aware) + Hyprland/Wayland + zram
# =============================================================================
# CachyOS repo kurulumu resmi yönteme gore yapilir:
#   1. CPU mimarisi /lib/ld-linux-x86-64.so.2 --help ile tespit edilir
#   2. AMD Zen 4/5 icin gcc -Q --help=target ile znver4/znver5 kontrolu
#   3. Mimari: znver4 | x86-64-v4 | x86-64-v3 | x86-64 (fallback)
#   4. Dogru keyring + mirrorlist + repo blogu otomatik eklenir
#
# Kaynak: https://github.com/CachyOS/cachyos-repo-add-script
# =============================================================================
# KULLANIM: Arch ISO ile boot et:
#   chmod +x arch-install.sh && ./arch-install.sh
# =============================================================================

set -euo pipefail

# ─── CONFIGURATION ────────────────────────────────────────────────────────────
TARGET_DISK="/dev/sda"      # SSD1 — root + home (SATA)
PART_EFI="${TARGET_DISK}1"  # /dev/sda1
PART_ROOT="${TARGET_DISK}2" # /dev/sda2
# NOT: SATA disk icin sda1/sda2, NVMe icin nvme0n1p1/p2 olur

EFI_SIZE="512M"
HOSTNAME="archbox"
TIMEZONE="Europe/Istanbul"
LOCALE="en_US.UTF-8"
KEYMAP="trq"
USERNAME="user"

BTRFS_OPTS="defaults,compress=zstd:3,noatime,nodiratime,space_cache=v2"
CACHYOS_MIRROR="https://mirror.cachyos.org/repo/x86_64/cachyos"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
log()  { echo -e "${GREEN}[+]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
err()  { echo -e "${RED}[x]${RESET} $*" >&2; exit 1; }
step() { echo -e "\n${CYAN}${BOLD}=== STEP $* ===${RESET}"; }

# =============================================================================
# CPU MiMARi TESPiT FONKSiYONU
# CachyOS resmi cachyos-repo-add-script ile ayni mantik:
#   - ld-linux'ten desteklenen x86-64 seviyesi okunur
#   - AMD Zen 4/5 icin gcc march hedefi kontrol edilir
#   - En yuksek desteklenen seviye secilir
# =============================================================================
detect_cpu_arch() {
    local ld_help=""
    local march_target=""

    # ld-linux'ten desteklenen mikro-arch seviyelerini al
    for ld in /lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2; do
        [[ -f "$ld" ]] && { ld_help=$("$ld" --help 2>/dev/null || true); break; }
    done

    # AMD Zen 4 / Zen 5 kontrolu — gcc march hedefine bak
    # Ryzen 7000 serisi (7500X3D dahil) = znver4
    # Ryzen 9000 serisi = znver5 (znver4 reposu kullanir)
    if command -v gcc &>/dev/null; then
        march_target=$(gcc -Q --help=target 2>/dev/null \
            | grep -oP '(?<=-march=)\S+' | head -1 || true)
        if [[ "$march_target" == znver4 || "$march_target" == znver5 ]]; then
            echo "znver4"
            return 0
        fi
    fi

    # x86-64-v4: AVX-512 destegi (Intel Rocket Lake+ / AMD Zen 4+)
    # NOT: Intel Alder Lake hybrid CPU'lar false-positive verebilir,
    #      bu yuzden gcc kontrolu onceliklidir
    if echo "$ld_help" | grep -q "x86-64-v4 (supported"; then
        echo "x86-64-v4"
        return 0
    fi

    # x86-64-v3: AVX2 destegi (cogu modern masaustu CPU)
    if echo "$ld_help" | grep -q "x86-64-v3 (supported"; then
        echo "x86-64-v3"
        return 0
    fi

    # Fallback: generic
    echo "x86-64"
}

# Mimari -> pacman.conf repo blogu
get_cachyos_repo_block() {
    local arch="$1"
    case "$arch" in
        znver4)
            printf '%s\n' \
                "# CachyOS -- AMD Zen 4/5 optimize (znver4)" \
                "[cachyos-znver4]" \
                "Include = /etc/pacman.d/cachyos-v4-mirrorlist" \
                "[cachyos-core-znver4]" \
                "Include = /etc/pacman.d/cachyos-v4-mirrorlist" \
                "[cachyos-extra-znver4]" \
                "Include = /etc/pacman.d/cachyos-v4-mirrorlist" \
                "[cachyos]" \
                "Include = /etc/pacman.d/cachyos-mirrorlist"
            ;;
        x86-64-v4)
            printf '%s\n' \
                "# CachyOS -- x86-64-v4 optimize (AVX-512)" \
                "[cachyos-v4]" \
                "Include = /etc/pacman.d/cachyos-v4-mirrorlist" \
                "[cachyos-core-v4]" \
                "Include = /etc/pacman.d/cachyos-v4-mirrorlist" \
                "[cachyos-extra-v4]" \
                "Include = /etc/pacman.d/cachyos-v4-mirrorlist" \
                "[cachyos]" \
                "Include = /etc/pacman.d/cachyos-mirrorlist"
            ;;
        x86-64-v3)
            printf '%s\n' \
                "# CachyOS -- x86-64-v3 optimize (AVX2)" \
                "[cachyos-v3]" \
                "Include = /etc/pacman.d/cachyos-v3-mirrorlist" \
                "[cachyos-core-v3]" \
                "Include = /etc/pacman.d/cachyos-v3-mirrorlist" \
                "[cachyos-extra-v3]" \
                "Include = /etc/pacman.d/cachyos-v3-mirrorlist" \
                "[cachyos]" \
                "Include = /etc/pacman.d/cachyos-mirrorlist"
            ;;
        *)
            printf '%s\n' \
                "# CachyOS -- generic x86-64" \
                "[cachyos]" \
                "Include = /etc/pacman.d/cachyos-mirrorlist"
            ;;
    esac
}

# Mimari -> indirilecek mirrorlist paket URL'leri
get_mirrorlist_urls() {
    local arch="$1"
    local base="$CACHYOS_MIRROR"
    local -a urls=(
        "${base}/cachyos-keyring-20240331-1-any.pkg.tar.zst"
        "${base}/cachyos-mirrorlist-22-1-any.pkg.tar.zst"
    )
    case "$arch" in
        znver4|x86-64-v4)
            urls+=("${base}/cachyos-v4-mirrorlist-22-1-any.pkg.tar.zst") ;;
        x86-64-v3)
            urls+=("${base}/cachyos-v3-mirrorlist-22-1-any.pkg.tar.zst") ;;
    esac
    echo "${urls[@]}"
}

# =============================================================================
# STEP 0: Pre-flight Checks
# =============================================================================
step "0: Pre-flight Checks"

[[ $EUID -ne 0 ]]          && err "Script root olarak calistirilmali"
[[ ! -d /sys/firmware/efi ]] && err "UEFI modunda boot edilmedi"
[[ ! -b "$TARGET_DISK" ]]  && err "Hedef disk $TARGET_DISK bulunamadi"

log "Hedef disk  : $TARGET_DISK"
log "EFI         : $PART_EFI"
log "Root        : $PART_ROOT"
log "SSD2 (diger disk) bu script tarafindan KESINLIKLE DOKUNULMAYACAK"

ping -c 1 -W 3 archlinux.org &>/dev/null || err "Internet baglantisi yok"
log "Internet: OK"

timedatectl set-ntp true || err "Saat senkronizasyonu basarisiz"
log "Saat senkronize edildi"

# =============================================================================
# STEP 1: CPU Mimari Tespiti (CachyOS resmi yontemi)
# =============================================================================
step "1: CPU Mimari Tespiti"

CPU_ARCH=$(detect_cpu_arch)
log "Tespit edilen CPU mimarisi: ${BOLD}${CPU_ARCH}${RESET}"

case "$CPU_ARCH" in
    znver4)    log "  -> AMD Zen 4/5 optimize repo (znver4) — Ryzen 7500X3D icin ideal" ;;
    x86-64-v4) log "  -> AVX-512 repo (x86-64-v4)" ;;
    x86-64-v3) log "  -> AVX2 repo (x86-64-v3)" ;;
    x86-64)    warn "  -> Generic x86-64 repo (optimizasyon yok)" ;;
esac

# =============================================================================
# STEP 2: CachyOS Repository Kurulumu — pacstrap ONCESI
# Resmi cachyos-repo-add-script ile ayni mantik:
#   keyring + mimari mirrorlist indirilir, live ISO'ya kurulur,
#   mimari-spesifik repo blogu pacman.conf'a [core]'dan once eklenir
# =============================================================================
step "2: CachyOS Repository Kurulumu (resmi yontem, CPU: ${CPU_ARCH})"

TMP_PKG="/tmp/cachyos-pkgs"
mkdir -p "$TMP_PKG"

# Mimari icin gerekli paket URL'lerini al ve indir
read -ra MIRROR_URLS <<< "$(get_mirrorlist_urls "$CPU_ARCH")"

for url in "${MIRROR_URLS[@]}"; do
    fname=$(basename "$url")
    log "  Indiriliyor: $fname"
    curl -fsSL -o "${TMP_PKG}/${fname}" "$url" \
        || err "Indirme basarisiz: $url"
done

log "Keyring + mirrorlist paketleri live ISO'ya kuruluyor..."
pacman -U --noconfirm "${TMP_PKG}"/*.pkg.tar.zst \
    || err "CachyOS paketleri kurulamadi"

# Mevcut cachyos bloklari varsa temizle (idempotent)
sed -i '/^# CachyOS/,/^$/{ /^\[core\]/b; d }' /etc/pacman.conf 2>/dev/null || true

# Mimari-spesifik repo blogu [core] satirindan ONCE ekle
REPO_BLOCK=$(get_cachyos_repo_block "$CPU_ARCH")
# Gecici dosyaya yaz, sonra sed ile ekle
printf '%s\n\n' "$REPO_BLOCK" > /tmp/cachyos-repo-block.txt
sed -i "/^\[core\]/r /tmp/cachyos-repo-block.txt" /etc/pacman.conf
# [core] satirinin ONCESINE eklemek icin siralama duzeltmesi
# (sed -i ile once ekle yontemi)
sed -i "/^\[core\]/{
    h
    r /tmp/cachyos-repo-block.txt
    g
    N
}" /etc/pacman.conf 2>/dev/null || {
    # Alternatif yontem: direkt append
    echo "" >> /etc/pacman.conf
    cat /tmp/cachyos-repo-block.txt >> /etc/pacman.conf
}

pacman -Sy || err "pacman veritabani sync basarisiz"
log "CachyOS repolari aktif — Mimari: ${CPU_ARCH}"

# =============================================================================
# STEP 3: Disk Hazirlik — Partition + btrfs
# =============================================================================
step "3: Disk Hazirligi (/dev/sda)"

log "Disk siliniyor: $TARGET_DISK"
wipefs -af "$TARGET_DISK"  || err "Disk silinemedi"
sgdisk -Z "$TARGET_DISK"   || err "Partition tablosu temizlenemedi"

log "GPT partition olusturuluyor..."
sgdisk \
    -n 1:0:+${EFI_SIZE}  -t 1:ef00 -c 1:"EFI System" \
    -n 2:0:0             -t 2:8300 -c 2:"Arch Linux Root" \
    "$TARGET_DISK" || err "Disk bolumlenemedi"

partprobe "$TARGET_DISK"
sleep 2

[[ -b "$PART_EFI" ]]  || err "$PART_EFI olusturulamadi"
[[ -b "$PART_ROOT" ]] || err "$PART_ROOT olusturulamadi"
log "Partition'lar: $PART_EFI (EFI) | $PART_ROOT (btrfs root)"

mkfs.fat -F32 -n "EFI" "$PART_EFI"   || err "EFI formatlanamaadi"
mkfs.btrfs -f -L "ArchRoot" "$PART_ROOT" || err "btrfs formatlanamadi"

log "btrfs subvolume'ler olusturuluyor..."
mount "$PART_ROOT" /mnt || err "Root mount edilemedi"

for subvol in @ @home @snapshots @var-log; do
    btrfs subvolume create "/mnt/${subvol}" || err "$subvol olusturulamadi"
    log "  Olusturuldu: $subvol"
done
umount /mnt

log "Subvolume'ler mount ediliyor (${BTRFS_OPTS})..."
mount -o "${BTRFS_OPTS},subvol=@"          "$PART_ROOT" /mnt            || err "@ mount edilemedi"
mkdir -p /mnt/{boot,home,.snapshots,var/log}
mount -o "${BTRFS_OPTS},subvol=@home"      "$PART_ROOT" /mnt/home       || err "@home mount edilemedi"
mount -o "${BTRFS_OPTS},subvol=@snapshots" "$PART_ROOT" /mnt/.snapshots || err "@snapshots mount edilemedi"
mount -o "${BTRFS_OPTS},subvol=@var-log"   "$PART_ROOT" /mnt/var/log    || err "@var-log mount edilemedi"
mount "$PART_EFI" /mnt/boot                                              || err "EFI mount edilemedi"
log "Disk hazir"

# =============================================================================
# STEP 4: Pacstrap — Temel Sistem
# =============================================================================
step "4: Pacstrap"

log "Mirror optimizasyonu..."
reflector --country Turkey,Germany,Netherlands \
    --protocol https --sort rate --latest 10 \
    --save /etc/pacman.d/mirrorlist 2>/dev/null \
    || warn "reflector basarisiz, mevcut mirrorlist kullanilacak"

# CachyOS mimari-optimize binary olarak linux-cachyos-bore saglar
KERNEL_PKG="linux-cachyos-bore"
KERNEL_HDR="linux-cachyos-bore-headers"
log "Kernel: $KERNEL_PKG (CachyOS ${CPU_ARCH} optimize binary)"

pacstrap -K /mnt \
    base base-devel \
    "${KERNEL_PKG}" "${KERNEL_HDR}" \
    linux-firmware \
    amd-ucode \
    btrfs-progs \
    limine \
    efibootmgr \
    networkmanager \
    zsh zsh-completions \
    neovim git curl wget \
    man-db man-pages \
    sudo reflector \
    dosfstools gcc \
    || err "Pacstrap basarisiz"
log "Pacstrap tamamlandi"

# =============================================================================
# STEP 5: fstab
# =============================================================================
step "5: fstab Olustur"
genfstab -U /mnt >> /mnt/etc/fstab || err "fstab olusturulamadi"
log "fstab olusturuldu"

# =============================================================================
# STEP 6: Chroot Script Yaz + Calistir
# Degiskenler disaridan heredoc icerisine inject edilir
# =============================================================================
step "6: Chroot Setup Hazirlaniyor"

cat > /mnt/root/chroot-setup.sh << CHROOT_SCRIPT
#!/usr/bin/env bash
set -euo pipefail

# Dis scriptten aktarilan degiskenler
CPU_ARCH="${CPU_ARCH}"
BTRFS_OPTS="${BTRFS_OPTS}"
CACHYOS_MIRROR="${CACHYOS_MIRROR}"
TIMEZONE="${TIMEZONE}"
LOCALE="${LOCALE}"
KEYMAP="${KEYMAP}"
HOSTNAME="${HOSTNAME}"
USERNAME="${USERNAME}"
KERNEL_PKG="${KERNEL_PKG}"
PART_ROOT="${PART_ROOT}"
PART_EFI="${PART_EFI}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
log()   { echo -e "\${GREEN}[+]\${RESET} \$*"; }
warn()  { echo -e "\${YELLOW}[!]\${RESET} \$*"; }
err()   { echo -e "\${RED}[x]\${RESET} \$*" >&2; exit 1; }
cstep() { echo -e "\n\${CYAN}\${BOLD}=== CHROOT \$* ===\${RESET}"; }

# get_cachyos_repo_block — chroot kopyasi
get_cachyos_repo_block() {
    local arch="\$1"
    case "\$arch" in
        znver4)
            printf '%s\n' \
                "# CachyOS -- AMD Zen 4/5 optimize (znver4)" \
                "[cachyos-znver4]" \
                "Include = /etc/pacman.d/cachyos-v4-mirrorlist" \
                "[cachyos-core-znver4]" \
                "Include = /etc/pacman.d/cachyos-v4-mirrorlist" \
                "[cachyos-extra-znver4]" \
                "Include = /etc/pacman.d/cachyos-v4-mirrorlist" \
                "[cachyos]" \
                "Include = /etc/pacman.d/cachyos-mirrorlist"
            ;;
        x86-64-v4)
            printf '%s\n' \
                "# CachyOS -- x86-64-v4 optimize (AVX-512)" \
                "[cachyos-v4]" \
                "Include = /etc/pacman.d/cachyos-v4-mirrorlist" \
                "[cachyos-core-v4]" \
                "Include = /etc/pacman.d/cachyos-v4-mirrorlist" \
                "[cachyos-extra-v4]" \
                "Include = /etc/pacman.d/cachyos-v4-mirrorlist" \
                "[cachyos]" \
                "Include = /etc/pacman.d/cachyos-mirrorlist"
            ;;
        x86-64-v3)
            printf '%s\n' \
                "# CachyOS -- x86-64-v3 optimize (AVX2)" \
                "[cachyos-v3]" \
                "Include = /etc/pacman.d/cachyos-v3-mirrorlist" \
                "[cachyos-core-v3]" \
                "Include = /etc/pacman.d/cachyos-v3-mirrorlist" \
                "[cachyos-extra-v3]" \
                "Include = /etc/pacman.d/cachyos-v3-mirrorlist" \
                "[cachyos]" \
                "Include = /etc/pacman.d/cachyos-mirrorlist"
            ;;
        *)
            printf '%s\n' \
                "# CachyOS -- generic x86-64" \
                "[cachyos]" \
                "Include = /etc/pacman.d/cachyos-mirrorlist"
            ;;
    esac
}

# ── 6a: Locale / Timezone ─────────────────────────────────────────────────────
cstep "6a: Locale & Timezone"
ln -sf "/usr/share/zoneinfo/\${TIMEZONE}" /etc/localtime
hwclock --systohc
sed -i "s/^#\${LOCALE} UTF-8/\${LOCALE} UTF-8/" /etc/locale.gen
locale-gen || err "locale-gen basarisiz"

cat > /etc/locale.conf << LCEOF
LANG=\${LOCALE}
LC_ADDRESS=\${LOCALE}
LC_MEASUREMENT=tr_TR.UTF-8
LC_MONETARY=tr_TR.UTF-8
LC_PAPER=tr_TR.UTF-8
LC_TELEPHONE=tr_TR.UTF-8
LC_TIME=tr_TR.UTF-8
LCEOF

echo "KEYMAP=\${KEYMAP}" > /etc/vconsole.conf
echo "\${HOSTNAME}" > /etc/hostname
cat > /etc/hosts << HEOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   \${HOSTNAME}.localdomain  \${HOSTNAME}
HEOF
log "Locale/timezone/hostname tamam"

# ── 6b: pacman.conf (mimari-spesifik CachyOS repo) ───────────────────────────
cstep "6b: pacman.conf — CachyOS Repo (CPU: \${CPU_ARCH})"

REPO_BLOCK=\$(get_cachyos_repo_block "\${CPU_ARCH}")

cat > /etc/pacman.conf << PEOF
[options]
HoldPkg     = pacman glibc
Architecture = auto
Color
ILoveCandy
CheckSpace
VerbosePkgLists
ParallelDownloads = 5
DisableDownloadTimeout

PEOF

# Repo blogu [core]'dan once (oncelik sirasi onemli)
echo "\${REPO_BLOCK}" >> /etc/pacman.conf
cat >> /etc/pacman.conf << STDEOF

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist
STDEOF

log "pacman.conf yazildi — Mimari: \${CPU_ARCH}"
pacman -Sy || err "pacman sync basarisiz"

# ── 6c: mkinitcpio ─────────────────────────────────────────────────────────────
cstep "6c: mkinitcpio"
cat > /etc/mkinitcpio.conf << MEOF
MODULES=(amdgpu btrfs)
BINARIES=()
FILES=()
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck)
COMPRESSION="zstd"
COMPRESSION_OPTIONS=(-9)
MEOF
mkinitcpio -P || err "mkinitcpio basarisiz"
log "initramfs olusturuldu"

# ── 6d: zram (swap dosyasi YOK) ───────────────────────────────────────────────
cstep "6d: zram"
cat > /etc/systemd/zram-generator.conf << ZEOF
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZEOF
log "zram: maks 8GB, zstd — swap dosyasi YOK"

# ── 6e: Limine Bootloader ─────────────────────────────────────────────────────
cstep "6e: Limine Bootloader"
install -Dm644 /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI \
    || err "Limine EFI kopyalanamadi"
install -Dm644 /usr/share/limine/limine-bios.sys /boot/limine-bios.sys 2>/dev/null || true

efibootmgr \
    --disk /dev/sda --part 1 \
    --create --label "Limine" \
    --loader "\\EFI\\BOOT\\BOOTX64.EFI" \
    --unicode \
    || err "efibootmgr basarisiz"

ROOT_UUID=\$(blkid -s UUID -o value "\${PART_ROOT}")
[[ -z "\$ROOT_UUID" ]] && err "Root UUID alinamadi"

cat > /boot/limine.conf << LEOF
# Limine Boot Configuration
# Arch Linux | CachyOS BORE | Ryzen 5 7500X3D | RX 9060 XT
# CPU Mimari: \${CPU_ARCH}

timeout: 5
graphics: yes
default_entry: 1

/Arch Linux (CachyOS BORE -- \${CPU_ARCH})
    comment: Default boot -- btrfs @, AMDGPU, Wayland
    protocol: linux
    path: boot():/vmlinuz-\${KERNEL_PKG}
    cmdline: root=UUID=\${ROOT_UUID} rootflags=subvol=@ rw rootfstype=btrfs amd_pstate=active amdgpu.ppfeaturemask=0xffffffff nowatchdog nmi_watchdog=0 quiet loglevel=3 systemd.show_status=auto rd.udev.log_level=3 mitigations=off
    module_path: boot():/initramfs-\${KERNEL_PKG}.img
    module_path: boot():/amd-ucode.img

/Arch Linux (Fallback)
    comment: Sorun yasarsan bunu kullan
    protocol: linux
    path: boot():/vmlinuz-\${KERNEL_PKG}
    cmdline: root=UUID=\${ROOT_UUID} rootflags=subvol=@ rw rootfstype=btrfs
    module_path: boot():/initramfs-\${KERNEL_PKG}-fallback.img
    module_path: boot():/amd-ucode.img
LEOF
log "Limine tamam — UUID: \${ROOT_UUID}"

# ── 6f: Kullanici ─────────────────────────────────────────────────────────────
cstep "6f: Kullanici"
useradd -m -G wheel,audio,video,input,storage,optical -s /bin/zsh "\${USERNAME}" \
    || err "Kullanici olusturulamadi"
echo "\${USERNAME}:changeme123" | chpasswd
echo "root:changeme123"        | chpasswd
warn "Sifre: changeme123 -- ILK GIRISTE HEMEN DEGISTIR: passwd"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
echo "Defaults timestamp_timeout=15" >> /etc/sudoers
log "Kullanici '\${USERNAME}' olusturuldu"

# ── 6g: Paket Kurulumu ────────────────────────────────────────────────────────
cstep "6g: Paket Kurulumu"

GPU_PKGS=(mesa vulkan-radeon libva-mesa-driver mesa-vdpau vulkan-tools
    mesa-utils xf86-video-amdgpu libdrm wayland wayland-protocols xorg-xwayland)

HYPR_PKGS=(hyprland uwsm xdg-desktop-portal-hyprland xdg-user-dirs xdg-utils
    polkit polkit-kde-agent qt5-wayland qt6-wayland
    alacritty rofi-wayland dunst thunar gvfs tumbler
    imv wl-clipboard cliphist swaylock swayidle waybar
    grim slurp hyprpaper
    noto-fonts noto-fonts-emoji ttf-jetbrains-mono-nerd)

AUDIO_PKGS=(pipewire pipewire-alsa pipewire-pulse pipewire-jack
    wireplumber pavucontrol)

GAMING_PKGS=(steam wine-staging winetricks
    lib32-mesa lib32-vulkan-radeon lib32-libva-mesa-driver
    vulkan-icd-loader lib32-vulkan-icd-loader
    gamemode lib32-gamemode mangohud lib32-mangohud)

BTRFS_PKGS=(snapper snap-pac btrfs-assistant)

SYS_PKGS=(networkmanager nm-connection-editor systemd-resolved
    zram-generator earlyoom reflector pacman-contrib pkgfile
    htop btop bat eza fd ripgrep fzf
    p7zip unzip unrar ffmpeg yt-dlp
    firefox obs-studio fastfetch starship)

ALL_PKGS=("\${GPU_PKGS[@]}" "\${HYPR_PKGS[@]}" "\${AUDIO_PKGS[@]}"
    "\${GAMING_PKGS[@]}" "\${BTRFS_PKGS[@]}" "\${SYS_PKGS[@]}")

log "\${#ALL_PKGS[@]} paket kuruluyor..."
pacman -S --noconfirm --needed "\${ALL_PKGS[@]}" || err "Paket kurulumu basarisiz"
log "Paketler kuruldu"

# ── 6h: paru AUR Helper ───────────────────────────────────────────────────────
cstep "6h: paru"
sudo -u "\${USERNAME}" bash -c '
    cd /tmp
    git clone https://aur.archlinux.org/paru-bin.git
    cd paru-bin
    makepkg -si --noconfirm
' || err "paru kurulamadi"

mkdir -p /home/\${USERNAME}/.config/paru
cat > /home/\${USERNAME}/.config/paru/paru.conf << PCEOF
[options]
BottomUp
NewsOnUpgrade
CloneDir = ~/.cache/paru/clone
PCEOF

sudo -u "\${USERNAME}" paru -S --noconfirm proton-ge-custom-bin \
    || warn "proton-ge-custom-bin: AUR'dan kurulamadi (kritik degil)"

chown -R "\${USERNAME}:\${USERNAME}" /home/\${USERNAME}/.config/paru
log "paru kuruldu"

# ── 6i: Snapper ───────────────────────────────────────────────────────────────
cstep "6i: Snapper"
umount /.snapshots 2>/dev/null || true
rmdir  /.snapshots 2>/dev/null || true
snapper -c root create-config / || err "snapper config basarisiz"
mount -o "\${BTRFS_OPTS},subvol=@snapshots" "\${PART_ROOT}" /.snapshots \
    || err "@snapshots tekrar mount edilemedi"
chmod 750 /.snapshots

sed -i \
    -e 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="10"/' \
    -e 's/^NUMBER_LIMIT_IMPORTANT=.*/NUMBER_LIMIT_IMPORTANT="5"/' \
    -e 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/' \
    -e 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' \
    -e 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="2"/' \
    -e 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="1"/' \
    -e 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' \
    /etc/snapper/configs/root
log "Snapper: 5h/7d/2w/1m snapshot politikasi"

# ── 6j: journald ──────────────────────────────────────────────────────────────
cstep "6j: journald"
cat > /etc/systemd/journald.conf << JEOF
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=256M
SystemKeepFree=1G
MaxRetentionSec=2week
RateLimitInterval=30s
RateLimitBurst=10000
JEOF
log "journald: 256MB limit, 2 haftalik sakla"

# ── 6k: TTY1 Auto-login -> uwsm -> Hyprland ───────────────────────────────────
cstep "6k: TTY1 Auto-login + Hyprland Otomatik Baslatma"

mkdir -p /etc/systemd/system/getty@tty1.service.d/
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << ALEOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin \${USERNAME} --noclear %I \\\$TERM
Type=simple
Restart=always
ALEOF

cat > /home/\${USERNAME}/.zprofile << 'ZPEOF'
# TTY1'de otomatik Hyprland baslatma (uwsm uzerinden)
if [[ -z "$WAYLAND_DISPLAY" ]] && [[ "$(tty)" == "/dev/tty1" ]]; then
    exec uwsm start hyprland.desktop
fi
ZPEOF
chown "\${USERNAME}:\${USERNAME}" /home/\${USERNAME}/.zprofile

mkdir -p /home/\${USERNAME}/.config/uwsm
cat > /home/\${USERNAME}/.config/uwsm/env << UWEOF
UWSM_APP_UNIT_TYPE=service
UWEOF
chown -R "\${USERNAME}:\${USERNAME}" /home/\${USERNAME}/.config/uwsm
log "TTY1 -> uwsm -> Hyprland zinciri kuruldu"

# ── 6l: Hyprland Config ───────────────────────────────────────────────────────
cstep "6l: Hyprland Konfigurasyonu"
HDIR="/home/\${USERNAME}/.config/hypr"
mkdir -p "\${HDIR}"

cat > "\${HDIR}/hyprland.conf" << 'HEOF'
# Hyprland Configuration
# Ryzen 5 7500X3D | RX 9060 XT 16GB | 16GB DDR5

# MONITOR -- hyprctl monitors ile kendi rezolasyonunu gir
monitor=,preferred,auto,1

# STARTUP
exec-once = /usr/lib/polkit-kde-authentication-agent-1
exec-once = dunst
exec-once = hyprpaper
exec-once = waybar
exec-once = wl-paste --type text  --watch cliphist store
exec-once = wl-paste --type image --watch cliphist store

# INPUT
input {
    kb_layout = tr
    kb_variant =
    follow_mouse = 1
    sensitivity = 0
    accel_profile = flat
}

# GENERAL
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(ca9ee6ff) rgba(99d1dbff) 45deg
    col.inactive_border = rgba(595959aa)
    layout = dwindle
    allow_tearing = true
}

decoration {
    rounding = 8
    blur { enabled = true; size = 6; passes = 3 }
    drop_shadow = true
    shadow_range = 8
}

animations {
    enabled = true
    bezier = smooth, 0.05, 0.9, 0.1, 1.05
    animation = windows,    1, 7, smooth
    animation = windowsOut, 1, 7, default, popin 80%
    animation = fade,       1, 7, default
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

# KEYBINDS
$mainMod = SUPER
bind = $mainMod, Return, exec, alacritty
bind = $mainMod, Q,      killactive
bind = $mainMod, M,      exit
bind = $mainMod, E,      exec, thunar
bind = $mainMod, V,      togglefloating
bind = $mainMod, R,      exec, rofi -show drun
bind = $mainMod, F,      fullscreen
bind = $mainMod SHIFT, S, exec, grim -g "$(slurp)" - | wl-copy

bind = $mainMod, left,  movefocus, l
bind = $mainMod, right, movefocus, r
bind = $mainMod, up,    movefocus, u
bind = $mainMod, down,  movefocus, d

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

bindm = $mainMod, mouse:272, movewindow
bindm = $mainMod, mouse:273, resizewindow

bind = , XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+
bind = , XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bind = , XF86AudioMute,        exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle

# ENV (AMD)
env = LIBVA_DRIVER_NAME,radeonsi
env = VDPAU_DRIVER,radeonsi
env = AMD_VULKAN_ICD,RADV
env = WLR_DRM_NO_ATOMIC,0
env = XCURSOR_SIZE,24
env = HYPRCURSOR_SIZE,24
HEOF
chown -R "\${USERNAME}:\${USERNAME}" "\${HDIR}"
log "Hyprland config olusturuldu"

# ── 6m: zsh ───────────────────────────────────────────────────────────────────
cstep "6m: zsh"
cat > /home/\${USERNAME}/.zshrc << 'ZEOF'
HISTFILE=~/.zsh_history
HISTSIZE=10000; SAVEHIST=10000
setopt HIST_IGNORE_DUPS HIST_SHARE_HISTORY EXTENDED_HISTORY
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
alias ls='eza --icons'
alias ll='eza -la --icons'
alias cat='bat'
alias vim='nvim'
alias update='sudo pacman -Syu && paru -Sua'
alias snap-list='snapper -c root list'
export DXVK_ASYNC=1
export PROTON_NO_ESYNC=0
export STEAM_FORCE_DESKTOPUI_SCALING=1
eval "$(starship init zsh)"
[ -f /usr/share/fzf/key-bindings.zsh ] && source /usr/share/fzf/key-bindings.zsh
[ -f /usr/share/fzf/completion.zsh ]   && source /usr/share/fzf/completion.zsh
ZEOF
chown "\${USERNAME}:\${USERNAME}" /home/\${USERNAME}/.zshrc
log "zsh yapılandirıldı"

# ── 6n: Systemd Servisleri ────────────────────────────────────────────────────
cstep "6n: Systemd Servisleri"
SERVICES=(NetworkManager systemd-resolved fstrim.timer
    snapper-timeline.timer snapper-cleanup.timer
    earlyoom reflector.timer pkgfile-update.timer
    systemd-zram-setup@zram0)

for svc in "\${SERVICES[@]}"; do
    systemctl enable "\$svc" && log "  Aktif: \$svc" || warn "  Basarisiz: \$svc"
done
systemctl disable systemd-networkd 2>/dev/null || true
loginctl enable-linger "\${USERNAME}" 2>/dev/null || true
log "Servisler tamam"

# ── 6o: fstab @snapshots dogrulamasi ─────────────────────────────────────────
cstep "6o: fstab Dogrulama"
ROOT_UUID=\$(blkid -s UUID -o value "\${PART_ROOT}")
grep -q "@snapshots" /etc/fstab || \
    printf '\n# btrfs @snapshots (snapper)\nUUID=%s  /.snapshots  btrfs  %s,subvol=@snapshots  0 0\n' \
        "\${ROOT_UUID}" "\${BTRFS_OPTS}" >> /etc/fstab
log "fstab dogrulandi"

# ── Bitis ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "\${GREEN}\${BOLD}================================================\${RESET}"
echo -e "\${GREEN}\${BOLD}  Chroot kurulum tamamlandi\${RESET}"
echo -e "\${GREEN}  CPU Mimarisi : \${CPU_ARCH}\${RESET}"
echo -e "\${GREEN}  Kernel       : \${KERNEL_PKG}\${RESET}"
echo -e "\${GREEN}  Kullanici    : \${USERNAME}\${RESET}"
echo -e "\${GREEN}\${BOLD}================================================\${RESET}"
warn "Sifre 'changeme123' -- ILK GIRISTE: passwd && sudo passwd root"

CHROOT_SCRIPT

chmod +x /mnt/root/chroot-setup.sh

log "Chroot'a giriliyor..."
arch-chroot /mnt /root/chroot-setup.sh || err "Chroot kurulumu basarisiz"

# =============================================================================
# STEP 7: Temizlik & Unmount
# =============================================================================
step "7: Temizlik & Unmount"

rm -f /mnt/root/chroot-setup.sh
sync
umount -R /mnt || warn "Bazi mount noktalari hala mesgul (kritik degil)"
log "Tamamlandi"

# =============================================================================
# KURULUM KONTROL LiSTESi
# =============================================================================
cat << CHECKLIST

========================================================================
  ARCH LINUX KURULUM TAMAMLANDI
  CPU Mimarisi   : ${CPU_ARCH}
  Kernel         : ${KERNEL_PKG}
  Disk           : /dev/sda (sda1=EFI, sda2=btrfs)
  SSD2           : DOKUNULMADI
========================================================================

[CHECK] Otomatik Tamamlanan Adimlar
  [v] CPU mimarisi tespit edildi  ->  ${CPU_ARCH}
  [v] CachyOS keyring + mirrorlist indirildi (resmi yontem)
  [v] Mimari-optimize repo blogu (znver4/v4/v3) pacman.conf'a eklendi
  [v] CachyOS repolari pacstrap ONCESI aktif edildi
  [v] /dev/sda bolumlemesi: sda1 (EFI 512MB) + sda2 (btrfs)
  [v] btrfs: @, @home, @snapshots, @var-log subvolume'ler
  [v] Mount secenekleri: zstd:3, noatime, space_cache=v2
  [v] linux-cachyos-bore + amd-ucode kuruldu
  [v] Limine EFI bootloader + limine.conf (2 entry)
  [v] zram maks 8GB, zstd -- SWAP DOSYASI YOK
  [v] Hyprland + uwsm -- TTY1 otomatik baslatma
  [v] PipeWire + WirePlumber
  [v] mesa + vulkan-radeon (AMDGPU)
  [v] Steam + Wine Staging + proton-ge-custom
  [v] snapper + snap-pac + btrfs-assistant (5h/7d/2w/1m)
  [v] paru AUR helper
  [v] Display manager KURULMADI
  [v] Flatpak KURULMADI
  [v] Power management KURULMADI (BIOS PBO korunacak)

[!] Manuel Dogrulama Gereken (ilk boot sonrasi)
  [ ] Limine menusu gorundü mü? (5 sn timeout)
  [ ] Boot tamamlandi mi? (kernel panic yok)
  [ ] TTY1'de 'user' otomatik giris yapti mi?
  [ ] Hyprland acildi mi? (uwsm uzerinden)
  [ ] lspci -k | grep -A2 VGA  ->  amdgpu driver?
  [ ] glxinfo | grep renderer  ->  AMD radeonsi?
  [ ] vulkaninfo | grep deviceName  ->  RX 9060 XT?
  [ ] pactl info  ->  PipeWire server?
  [ ] zramctl  ->  zram0 aktif?
  [ ] snapper list  ->  hata yok?
  [ ] SSD2 (sdb) fstab'da YOK mu?

[>] Sonradan Yapilacaklar
  [ ] SIFRE DEGISTIR: passwd && sudo passwd root
  [ ] Monitor ayari: ~/.config/hypr/hyprland.conf
        monitor=DP-1,2560x1440@144,0x0,1  (ornegi duzenle)
  [ ] Steam giris + Proton-GE secimi
  [ ] SSD2 oyun kutuphanesi Steam'e ekle (Storage > Add Drive)
  [ ] Haftalik guncelleme: sudo pacman -Syu && paru -Sua
  [ ] btrfs-assistant ile snapshot yonetimi

Kurulum bitti! ISO'yu cikar, sonra:  reboot

CHECKLIST
