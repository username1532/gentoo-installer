#!/usr/bin/env bash
#
# gentoo-installer.sh
# A dialog(1)-driven TUI installer for Gentoo Linux, modeled on Void's
# void-installer: a single portable script, a main menu of independent
# steps each showing its current value/status, and a final commit step
# that runs the whole install non-interactively from the gathered config.
#
# Run as root from a Gentoo (or any) live environment with network access.
# Requires: dialog, parted, curl, gawk, coreutils. Nothing else.
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Globals / config store
# ---------------------------------------------------------------------------

SCRIPT_NAME="gentoo-installer"
LOG_FILE="/var/log/${SCRIPT_NAME}.log"
TARGET="/mnt/gentoo"
BACKTITLE="Gentoo TUI Installer"

declare -A CONFIG=(
  [KEYMAP]="us"
  [HOSTNAME]="gentoo"
  [TIMEZONE]="UTC"
  [LOCALE]="en_US.UTF-8 UTF-8"
  [MIRROR]="https://distfiles.gentoo.org"
  [DISK]=""
  [DISK_MODE]="guided"          # guided | manual
  [ROOT_FS]="ext4"              # ext4 | btrfs | xfs
  [USE_LUKS]="no"
  [BOOT_MODE]=""                # efi | bios  (auto-detected)
  [PROFILE_LIBC]="glibc"        # glibc | musl
  [PROFILE_INIT]="openrc"       # openrc | systemd
  [PROFILE_VARIANT]="desktop"   # desktop | hardened | nomultilib | minimal
  [STAGE3_FILE]=""
  [MAKEOPTS_JOBS]="$(nproc 2>/dev/null || echo 2)"
  [KERNEL_METHOD]="dist-kernel" # dist-kernel | genkernel | manual
  [BOOTLOADER]="grub"           # grub | systemd-boot | limine
  [USERNAME]=""
  [DESKTOP]="none"              # none | gnome | kde | sway | hyprland
  [SYNC_TREE]="yes"
  [WORLD_UPDATE]="no"
)

STEP_ORDER=(keymap network mirror disk profile stage3 hostname locale
            kernel bootloader user desktop review)

# ---------------------------------------------------------------------------
# Low-level helpers
# ---------------------------------------------------------------------------

log() { echo "[$(date '+%H:%M:%S')] $*" >>"$LOG_FILE"; }

die() {
  dialog --backtitle "$BACKTITLE" --title "Fatal error" --msgbox "$1" 10 60
  clear
  exit 1
}

run_cmd() {
  # run_cmd <description> <cmd...>
  local desc="$1"; shift
  log "RUN: $desc :: $*"
  if ! "$@" >>"$LOG_FILE" 2>&1; then
    dialog --backtitle "$BACKTITLE" --title "Command failed" \
      --yesno "Step failed: $desc\n\nCommand: $*\n\nSee $LOG_FILE for details.\n\nContinue anyway?" 14 70
    [[ $? -eq 0 ]] || die "Aborted after failure: $desc"
  fi
}

d_menu() {
  # d_menu <title> <text> <height> <width> <menu-height> "tag" "item" ...
  dialog --backtitle "$BACKTITLE" --clear --title "$1" \
    --menu "$2" "$3" "$4" "$5" "${@:6}" 3>&1 1>&2 2>&3
}

d_input() {
  dialog --backtitle "$BACKTITLE" --clear --title "$1" \
    --inputbox "$2" 10 60 "$3" 3>&1 1>&2 2>&3
}

d_password() {
  dialog --backtitle "$BACKTITLE" --clear --title "$1" \
    --insecure --passwordbox "$2" 10 60 3>&1 1>&2 2>&3
}

d_yesno() {
  dialog --backtitle "$BACKTITLE" --clear --title "$1" --yesno "$2" 10 60
}

d_msgbox() {
  dialog --backtitle "$BACKTITLE" --clear --title "$1" --msgbox "$2" "${3:-12}" "${4:-65}"
}

d_checklist() {
  dialog --backtitle "$BACKTITLE" --clear --title "$1" \
    --checklist "$2" "$3" "$4" "$5" "${@:6}" 3>&1 1>&2 2>&3
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

preflight() {
  [[ $EUID -eq 0 ]] || { echo "Must run as root." >&2; exit 1; }
  command -v dialog >/dev/null || { echo "Install 'dialog' first." >&2; exit 1; }
  for bin in parted curl gawk lsblk blkid mkfs.ext4 chroot; do
    command -v "$bin" >/dev/null || echo "Warning: $bin not found in PATH" >>"$LOG_FILE"
  done
  [[ -d /sys/firmware/efi ]] && CONFIG[BOOT_MODE]=efi || CONFIG[BOOT_MODE]=bios
  : >"$LOG_FILE"
  log "Preflight complete. Boot mode: ${CONFIG[BOOT_MODE]}"
}

# ---------------------------------------------------------------------------
# Step: keymap
# ---------------------------------------------------------------------------

step_keymap() {
  local choice
  choice=$(d_menu "Keymap" "Select console keymap" 15 50 6 \
    us "US English" \
    uk "UK English" \
    de "German" \
    fr "French" \
    ca "Canadian (French)" \
    dvorak "Dvorak")
  [[ -n "$choice" ]] || return
  CONFIG[KEYMAP]="$choice"
  loadkeys "$choice" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Step: network
# ---------------------------------------------------------------------------

step_network() {
  if ping -c1 -W2 gentoo.org >/dev/null 2>&1; then
    d_msgbox "Network" "Already connected to the internet."
    return
  fi
  local method
  method=$(d_menu "Network" "No connectivity detected. Choose method:" 12 55 2 \
    dhcp "DHCP on a wired interface" \
    wifi "Wireless via wpa_supplicant")
  case "$method" in
    dhcp)
      local iface
      iface=$(d_input "Network" "Interface name (see 'ip link'):" "eth0")
      [[ -n "$iface" ]] && run_cmd "dhcpcd $iface" dhcpcd "$iface"
      ;;
    wifi)
      d_msgbox "Network" "Run 'wpa_supplicant -B -i <iface> -c <(wpa_passphrase SSID PSK)' then 'dhcpcd <iface>' in another TTY, then return here and re-run this step." 12 65
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Step: mirror
# ---------------------------------------------------------------------------

step_mirror() {
  local mirror
  mirror=$(d_menu "Mirror" "Choose a Gentoo distfiles mirror" 15 60 4 \
    "https://distfiles.gentoo.org" "Official (geo-balanced)" \
    "https://mirror.leaseweb.com/gentoo" "Leaseweb (EU/global)" \
    "https://gentoo.osuosl.org" "OSU Open Source Lab (US)" \
    custom "Enter a custom mirror URL")
  if [[ "$mirror" == "custom" ]]; then
    mirror=$(d_input "Mirror" "Enter mirror base URL:" "${CONFIG[MIRROR]}")
  fi
  [[ -n "$mirror" ]] && CONFIG[MIRROR]="$mirror"
}

# ---------------------------------------------------------------------------
# Step: disk
# ---------------------------------------------------------------------------

list_disks() {
  lsblk -dno NAME,SIZE,MODEL -e7,11 | awk '{printf "%s \"%s %s\"\n", "/dev/"$1, $2, substr($0, index($0,$3))}'
}

step_disk() {
  local items disk
  items=$(list_disks)
  [[ -n "$items" ]] || { d_msgbox "Disk" "No block devices found."; return; }
  disk=$(eval dialog --backtitle \"\$BACKTITLE\" --title Disk --menu \
    \"Select target disk \(ALL DATA WILL BE ERASED\)\" 18 60 8 $items \
    3\>\&1 1\>\&2 2\>\&3)
  [[ -n "$disk" ]] || return
  CONFIG[DISK]="$disk"

  local mode
  mode=$(d_menu "Partitioning" "Guided creates ESP+swap+root automatically.\nManual drops you into cfdisk." 12 60 2 \
    guided "Guided (recommended)" \
    manual "Manual (cfdisk)")
  [[ -n "$mode" ]] && CONFIG[DISK_MODE]="$mode"

  if [[ "$mode" == "manual" ]]; then
    command -v cfdisk >/dev/null && cfdisk "${CONFIG[DISK]}"
  fi

  local fs
  fs=$(d_menu "Filesystem" "Root filesystem" 12 50 3 \
    ext4 "ext4 (safe default)" \
    btrfs "btrfs (snapshots, subvolumes)" \
    xfs "xfs (large files, servers)")
  [[ -n "$fs" ]] && CONFIG[ROOT_FS]="$fs"

  d_yesno "Encryption" "Encrypt root partition with LUKS?"
  [[ $? -eq 0 ]] && CONFIG[USE_LUKS]="yes" || CONFIG[USE_LUKS]="no"
}

partition_and_format() {
  local disk="${CONFIG[DISK]}"
  [[ -n "$disk" ]] || die "No disk selected."
  local p1="${disk}1" p2="${disk}2" p3="${disk}3"
  [[ "$disk" == *nvme* ]] && { p1="${disk}p1"; p2="${disk}p2"; p3="${disk}p3"; }

  if [[ "${CONFIG[DISK_MODE]}" == "guided" ]]; then
    run_cmd "create GPT label" parted -s "$disk" mklabel gpt
    if [[ "${CONFIG[BOOT_MODE]}" == "efi" ]]; then
      run_cmd "create ESP" parted -s "$disk" mkpart ESP fat32 1MiB 513MiB
      run_cmd "set esp flag" parted -s "$disk" set 1 esp on
    else
      run_cmd "create BIOS boot" parted -s "$disk" mkpart biosboot 1MiB 3MiB
      run_cmd "set bios_grub flag" parted -s "$disk" set 1 bios_grub on
      # re-use p1 slot as a small non-fs partition; ESP formatting skipped below
    fi
    run_cmd "create swap" parted -s "$disk" mkpart swap linux-swap 513MiB 4609MiB
    run_cmd "create root" parted -s "$disk" mkpart root "${CONFIG[ROOT_FS]}" 4609MiB 100%
    partprobe "$disk" 2>/dev/null || true
    sleep 1

    if [[ "${CONFIG[BOOT_MODE]}" == "efi" ]]; then
      run_cmd "mkfs ESP" mkfs.fat -F32 "$p1"
    fi
    run_cmd "mkswap" mkswap "$p2"
    run_cmd "swapon" swapon "$p2"

    local root_part="$p3"
    if [[ "${CONFIG[USE_LUKS]}" == "yes" ]]; then
      dialog --backtitle "$BACKTITLE" --title "LUKS" --insecure --passwordbox \
        "Enter LUKS passphrase:" 10 55 2>/tmp/luks_pass
      run_cmd "luksFormat" bash -c "cryptsetup luksFormat '$p3' < /tmp/luks_pass"
      run_cmd "luksOpen" bash -c "cryptsetup luksOpen '$p3' cryptroot < /tmp/luks_pass"
      shred -u /tmp/luks_pass 2>/dev/null || rm -f /tmp/luks_pass
      root_part="/dev/mapper/cryptroot"
    fi

    case "${CONFIG[ROOT_FS]}" in
      ext4)  run_cmd "mkfs root" mkfs.ext4 -F "$root_part" ;;
      btrfs) run_cmd "mkfs root" mkfs.btrfs -f "$root_part" ;;
      xfs)   run_cmd "mkfs root" mkfs.xfs -f "$root_part" ;;
    esac

    mkdir -p "$TARGET"
    run_cmd "mount root" mount "$root_part" "$TARGET"
    if [[ "${CONFIG[BOOT_MODE]}" == "efi" ]]; then
      mkdir -p "$TARGET/efi"
      run_cmd "mount ESP" mount "$p1" "$TARGET/efi"
    fi
    CONFIG[ROOT_PART]="$root_part"
    CONFIG[ESP_PART]="$p1"
  else
    d_msgbox "Manual partitioning" "Since you partitioned manually, mount your target root at $TARGET (and ESP at $TARGET/efi) now, then press OK to continue." 12 65
    mountpoint -q "$TARGET" || die "$TARGET is not mounted."
  fi
}

# ---------------------------------------------------------------------------
# Step: profile (libc / init / variant -> determines stage3 name)
# ---------------------------------------------------------------------------

step_profile() {
  local libc init variant
  libc=$(d_menu "Profile: libc" "C library" 10 50 2 glibc "glibc (default)" musl "musl (smaller, stricter)")
  [[ -n "$libc" ]] && CONFIG[PROFILE_LIBC]="$libc"

  init=$(d_menu "Profile: init" "Init system" 10 50 2 openrc "OpenRC (Gentoo default)" systemd "systemd")
  [[ -n "$init" ]] && CONFIG[PROFILE_INIT]="$init"

  variant=$(d_menu "Profile: variant" "Stage3 variant" 14 60 4 \
    desktop "desktop (recommended for daily driver)" \
    hardened "hardened (extra security defaults)" \
    nomultilib "nomultilib (pure 64-bit, no 32-bit compat)" \
    minimal "minimal / server, no desktop bits")
  [[ -n "$variant" ]] && CONFIG[PROFILE_VARIANT]="$variant"
}

# ---------------------------------------------------------------------------
# Step: stage3 fetch + extract
# ---------------------------------------------------------------------------

stage3_subdir() {
  # Builds the releases/amd64/autobuilds path segment based on profile choices.
  local libc="${CONFIG[PROFILE_LIBC]}" init="${CONFIG[PROFILE_INIT]}" variant="${CONFIG[PROFILE_VARIANT]}"
  local tag="stage3-amd64"
  [[ "$libc" == "musl" ]] && tag="stage3-amd64-musl"
  [[ "$init" == "systemd" && "$libc" == "glibc" ]] && tag="stage3-amd64-systemd"
  case "$variant" in
    hardened)   tag="${tag}-hardened" ;;
    nomultilib) tag="${tag}-nomultilib" ;;
    desktop)    tag="${tag}-desktop-openrc"; [[ "$init" == "systemd" ]] && tag="stage3-amd64-desktop-systemd" ;;
  esac
  echo "$tag"
}

step_stage3() {
  local tag latest_txt latest_path fname url
  tag="$(stage3_subdir)"
  latest_txt="${CONFIG[MIRROR]}/releases/amd64/autobuilds/latest-${tag}.txt"

  log "Fetching stage3 manifest: $latest_txt"
  latest_path=$(curl -fsSL "$latest_txt" 2>>"$LOG_FILE" | grep -v '^#' | awk '{print $1}' | head -n1)

  if [[ -z "$latest_path" ]]; then
    d_msgbox "Stage3" "Could not auto-resolve latest stage3 for tag '$tag'.\nYou can enter the path manually (relative to releases/amd64/autobuilds/), e.g.\n20260701T170154Z/${tag}-20260701T170154Z.tar.xz" 14 70
    latest_path=$(d_input "Stage3 path" "Relative path under autobuilds/:" "")
    [[ -n "$latest_path" ]] || die "No stage3 path provided."
  fi

  fname="$(basename "$latest_path")"
  url="${CONFIG[MIRROR]}/releases/amd64/autobuilds/${latest_path}"
  CONFIG[STAGE3_FILE]="$fname"

  mkdir -p /tmp/stage3
  run_cmd "download stage3" curl -fL --progress-bar -o "/tmp/stage3/$fname" "$url"
  run_cmd "download DIGESTS" curl -fsSL -o "/tmp/stage3/${fname}.DIGESTS" "${url}.DIGESTS" || true

  if [[ -f "/tmp/stage3/${fname}.DIGESTS" ]]; then
    local expected actual
    expected=$(grep -A1 'SHA512' "/tmp/stage3/${fname}.DIGESTS" | grep "$fname" | awk '{print $1}')
    actual=$(sha512sum "/tmp/stage3/$fname" | awk '{print $1}')
    if [[ -n "$expected" && "$expected" != "$actual" ]]; then
      die "Stage3 checksum mismatch! Refusing to continue."
    fi
  fi

  mountpoint -q "$TARGET" || die "$TARGET not mounted; run the disk step first."
  run_cmd "extract stage3" tar xpf "/tmp/stage3/$fname" --xattrs-include='*.*' \
    --numeric-owner -C "$TARGET"
}

# ---------------------------------------------------------------------------
# Step: hostname
# ---------------------------------------------------------------------------

step_hostname() {
  local h
  h=$(d_input "Hostname" "System hostname:" "${CONFIG[HOSTNAME]}")
  [[ -n "$h" ]] && CONFIG[HOSTNAME]="$h"
}

# ---------------------------------------------------------------------------
# Step: locale / timezone
# ---------------------------------------------------------------------------

step_locale() {
  local loc tz region
  loc=$(d_menu "Locale" "Primary locale" 15 55 5 \
    "en_US.UTF-8 UTF-8" "English (US)" \
    "en_GB.UTF-8 UTF-8" "English (UK)" \
    "en_CA.UTF-8 UTF-8" "English (Canada)" \
    "fr_CA.UTF-8 UTF-8" "French (Canada)" \
    "de_DE.UTF-8 UTF-8" "German")
  [[ -n "$loc" ]] && CONFIG[LOCALE]="$loc"

  region=$(d_menu "Timezone" "Region" 15 50 5 \
    America "America" Europe "Europe" Asia "Asia" Africa "Africa" Australia "Australia")
  [[ -n "$region" ]] || return
  tz=$(d_input "Timezone" "Full zoneinfo name (e.g. ${region}/Winnipeg):" "${region}/")
  [[ -n "$tz" ]] && CONFIG[TIMEZONE]="$tz"
}

# ---------------------------------------------------------------------------
# Step: kernel
# ---------------------------------------------------------------------------

step_kernel() {
  local method jobs
  method=$(d_menu "Kernel" "How should the kernel be built/installed?" 16 65 3 \
    dist-kernel "sys-kernel/gentoo-kernel-bin (fastest, prebuilt)" \
    genkernel "genkernel (auto-config, built from source)" \
    manual "Manual: gentoo-sources + menuconfig (full control)")
  [[ -n "$method" ]] && CONFIG[KERNEL_METHOD]="$method"

  jobs=$(d_input "Build jobs" "MAKEOPTS -j value (detected $(nproc 2>/dev/null || echo 2) cores):" "${CONFIG[MAKEOPTS_JOBS]}")
  [[ -n "$jobs" ]] && CONFIG[MAKEOPTS_JOBS]="$jobs"
}

# ---------------------------------------------------------------------------
# Step: bootloader
# ---------------------------------------------------------------------------

step_bootloader() {
  local opts=(grub "GRUB (BIOS + UEFI)")
  opts+=(limine "Limine (BIOS + UEFI, fast, simple config)")
  if [[ "${CONFIG[BOOT_MODE]}" == "efi" ]]; then
    opts+=(refind "rEFInd (UEFI, auto-detects kernels, boot menu GUI)")
    [[ "${CONFIG[PROFILE_INIT]}" == "systemd" ]] && opts+=(systemd-boot "systemd-boot (UEFI only, systemd-managed)")
  fi
  local choice
  choice=$(d_menu "Bootloader" "Choose bootloader" 15 65 4 "${opts[@]}")
  [[ -n "$choice" ]] && CONFIG[BOOTLOADER]="$choice"
}

# ---------------------------------------------------------------------------
# Step: user accounts
# ---------------------------------------------------------------------------

step_user() {
  local uname
  uname=$(d_input "User account" "Username for the primary non-root user:" "${CONFIG[USERNAME]}")
  [[ -n "$uname" ]] && CONFIG[USERNAME]="$uname"
  d_msgbox "Passwords" "You'll be prompted for the root password and then ${CONFIG[USERNAME]:-the user}'s password during the final install step, so they aren't held in memory here longer than needed." 10 60
}

# ---------------------------------------------------------------------------
# Step: desktop
# ---------------------------------------------------------------------------

step_desktop() {
  local d
  d=$(d_menu "Desktop" "Optional desktop environment / WM" 14 55 5 \
    none "None (server / CLI only)" \
    gnome "GNOME" \
    kde "KDE Plasma" \
    sway "Sway (wlroots, tiling)" \
    hyprland "Hyprland (wlroots, tiling)")
  [[ -n "$d" ]] && CONFIG[DESKTOP]="$d"
}

# ---------------------------------------------------------------------------
# Step: review
# ---------------------------------------------------------------------------

step_review() {
  local summary=""
  for k in "${!CONFIG[@]}"; do summary+="$k = ${CONFIG[$k]}\n"; done
  d_msgbox "Review configuration" "$summary" 24 70
}

# ---------------------------------------------------------------------------
# Chroot install script generation + execution
# ---------------------------------------------------------------------------

write_make_conf() {
  cat >"$TARGET/etc/portage/make.conf" <<EOF
COMMON_FLAGS="-O2 -pipe -march=native"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="-j${CONFIG[MAKEOPTS_JOBS]}"
EMERGE_DEFAULT_OPTS="--jobs=2 --load-average=$(( ${CONFIG[MAKEOPTS_JOBS]} + 1 ))"
ACCEPT_LICENSE="*"
GENTOO_MIRRORS="${CONFIG[MIRROR]}"
USE="X wayland pipewire elogind -systemd"
$( [[ "${CONFIG[PROFILE_INIT]}" == "systemd" ]] && echo 'USE="X wayland pipewire"' )
L10N="en"
VIDEO_CARDS="amdgpu radeonsi"
EOF
}

write_fstab() {
  local root_part="${CONFIG[ROOT_PART]:-}" esp_part="${CONFIG[ESP_PART]:-}"
  {
    echo "# <fs>            <mountpoint>  <type>  <opts>       <dump/pass>"
    if [[ -n "$root_part" ]]; then
      local uuid; uuid=$(blkid -s UUID -o value "$root_part")
      echo "UUID=$uuid   /             ${CONFIG[ROOT_FS]}   noatime      0 1"
    fi
    if [[ -n "$esp_part" && "${CONFIG[BOOT_MODE]}" == "efi" ]]; then
      local euuid; euuid=$(blkid -s UUID -o value "$esp_part")
      echo "UUID=$euuid   /efi          vfat    defaults     0 2"
    fi
  } >"$TARGET/etc/fstab"
}

desktop_packages() {
  case "${CONFIG[DESKTOP]}" in
    gnome)    echo "gnome-base/gnome gui-libs/display-manager-init" ;;
    kde)      echo "kde-plasma/plasma-meta" ;;
    sway)     echo "gui-wm/sway x11-terminals/foot" ;;
    hyprland) echo "gui-wm/hyprland x11-terminals/foot" ;;
    *)        echo "" ;;
  esac
}

kernel_commands() {
  case "${CONFIG[KERNEL_METHOD]}" in
    dist-kernel)
      echo "emerge --quiet sys-kernel/gentoo-kernel-bin"
      ;;
    genkernel)
      echo "emerge --quiet sys-kernel/gentoo-sources sys-kernel/genkernel"
      echo "genkernel --makeopts=-j${CONFIG[MAKEOPTS_JOBS]} all"
      ;;
    manual)
      echo "emerge --quiet sys-kernel/gentoo-sources"
      echo "eselect kernel set 1"
      echo "echo 'Manual kernel selected: run \`make menuconfig\` in /usr/src/linux, then make && make modules_install && make install'"
      ;;
  esac
}

bootloader_commands() {
  case "${CONFIG[BOOTLOADER]}" in
    grub)
      if [[ "${CONFIG[BOOT_MODE]}" == "efi" ]]; then
        echo "emerge --quiet sys-boot/grub"
        echo "grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GENTOO"
      else
        echo "emerge --quiet sys-boot/grub"
        echo "grub-install ${CONFIG[DISK]}"
      fi
      echo "grub-mkconfig -o /boot/grub/grub.cfg"
      ;;
    limine)
      echo "emerge --quiet sys-boot/limine"
      if [[ "${CONFIG[BOOT_MODE]}" == "efi" ]]; then
        echo "mkdir -p /efi/EFI/BOOT"
        echo "cp /usr/share/limine/BOOTX64.EFI /efi/EFI/BOOT/ || true"
      else
        echo "mkdir -p /boot/limine"
        echo "cp /usr/share/limine/limine-bios.sys /boot/limine/ || true"
        echo "limine bios-install ${CONFIG[DISK]}"
      fi
      echo "echo 'Remember to write /boot/limine/limine.cfg with your kernel entry.'"
      ;;
    refind)
      # refind-install auto-generates entries for EFI-stub kernels, but
      # gentoo-kernel-bin / genkernel builds need root= passed explicitly
      # via refind_linux.conf sitting next to the kernel in /boot. Build
      # that cmdline now (values are baked in at chroot-script generation
      # time, since blkid needs the partitions to already exist).
      local root_part="${CONFIG[ROOT_PART]:-${CONFIG[DISK]}3}"
      local cmdline="root=UUID=$(blkid -s UUID -o value "$root_part" 2>/dev/null) rw"
      if [[ "${CONFIG[USE_LUKS]}" == "yes" ]]; then
        local luks_uuid; luks_uuid=$(blkid -s UUID -o value "${CONFIG[DISK]}3" 2>/dev/null)
        cmdline="rd.luks.uuid=${luks_uuid} root=/dev/mapper/cryptroot rw"
      fi
      echo "emerge --quiet sys-boot/refind"
      echo "refind-install"
      printf '%s\n' "printf '\"Boot Gentoo\" \"${cmdline}\"\\n' > /boot/refind_linux.conf"
      ;;
    systemd-boot)
      echo "bootctl install"
      ;;
  esac
}

build_chroot_script() {
  local pkgs; pkgs="$(desktop_packages)"
  cat >"$TARGET/root/chroot-install.sh" <<CHROOT
#!/usr/bin/env bash
set -euo pipefail
source /etc/profile

echo "--- syncing portage tree ---"
$( [[ "${CONFIG[SYNC_TREE]}" == "yes" ]] && echo "emerge-webrsync" )

echo "--- selecting profile ---"
eselect profile list | grep -i "${CONFIG[PROFILE_VARIANT]}" | head -n1 | \\
  awk '{print \$1}' | tr -d '[]' | xargs -r eselect profile set || true

echo "--- timezone / locale ---"
echo "${CONFIG[TIMEZONE]}" > /etc/timezone
emerge --config sys-libs/timezone-data 2>/dev/null || true
echo "${CONFIG[LOCALE]}" >> /etc/locale.gen
locale-gen
eselect locale set "$(echo "${CONFIG[LOCALE]}" | awk '{print $1}')" || true
env-update && source /etc/profile

echo "--- hostname ---"
echo "${CONFIG[HOSTNAME]}" > /etc/hostname

echo "--- kernel ---"
$(kernel_commands)

echo "--- bootloader ---"
$(bootloader_commands)

echo "--- base system packages ---"
emerge --quiet app-admin/sudo net-misc/dhcpcd app-editors/vim

$( [[ -n "$pkgs" ]] && echo "echo '--- desktop packages ---'; emerge --quiet $pkgs" )

echo "--- users ---"
echo "Set the root password:"
passwd
$( [[ -n "${CONFIG[USERNAME]}" ]] && cat <<USR
useradd -m -G users,wheel,audio,video,plugdev -s /bin/bash "${CONFIG[USERNAME]}"
echo "Set password for ${CONFIG[USERNAME]}:"
passwd "${CONFIG[USERNAME]}"
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers
USR
)

echo "--- init services ---"
$( [[ "${CONFIG[PROFILE_INIT]}" == "openrc" ]] && echo "rc-update add dhcpcd default" || echo "systemctl enable dhcpcd" )

echo "--- chroot install complete ---"
CHROOT
  chmod +x "$TARGET/root/chroot-install.sh"
}

do_install() {
  d_yesno "Confirm" "This will ERASE ${CONFIG[DISK]:-the selected disk} and install Gentoo.\n\nContinue?"
  [[ $? -eq 0 ]] || return

  ( 
    echo 10; echo "# Partitioning and formatting..."
    partition_and_format
    echo 30; echo "# Fetching and extracting stage3..."
    step_stage3
    echo 55; echo "# Writing base config (make.conf, fstab)..."
    write_make_conf
    write_fstab
    cp --dereference /etc/resolv.conf "$TARGET/etc/" 2>/dev/null || true
    echo 65; echo "# Binding kernel filesystems..."
    for fs in proc sys dev; do mount --rbind "/$fs" "$TARGET/$fs"; mount --make-rslave "$TARGET/$fs"; done
    echo 75; echo "# Building chroot install script..."
    build_chroot_script
    echo 85; echo "# Entering chroot (interactive: passwords, builds)..."
  ) | dialog --backtitle "$BACKTITLE" --title "Installing" --gauge "Starting..." 10 65 0

  clear
  echo "Entering chroot — you'll be prompted for passwords and will see build output live."
  chroot "$TARGET" /bin/bash /root/chroot-install.sh 2>&1 | tee -a "$LOG_FILE"

  for fs in dev sys proc; do umount -R "$TARGET/$fs" 2>/dev/null || true; done
  [[ "${CONFIG[BOOT_MODE]}" == "efi" ]] && umount "$TARGET/efi" 2>/dev/null || true
  umount "$TARGET" 2>/dev/null || true
  [[ "${CONFIG[USE_LUKS]}" == "yes" ]] && cryptsetup luksClose cryptroot 2>/dev/null || true

  d_msgbox "Done" "Install finished. Log at $LOG_FILE.\n\nReboot when ready." 10 55
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------

step_label() {
  case "$1" in
    keymap)     echo "Keymap [${CONFIG[KEYMAP]}]" ;;
    network)    echo "Network" ;;
    mirror)     echo "Mirror [${CONFIG[MIRROR]}]" ;;
    disk)       echo "Disk [${CONFIG[DISK]:-not set}]" ;;
    profile)    echo "Profile [${CONFIG[PROFILE_LIBC]}/${CONFIG[PROFILE_INIT]}/${CONFIG[PROFILE_VARIANT]}]" ;;
    stage3)     echo "Stage3 [${CONFIG[STAGE3_FILE]:-not fetched}]" ;;
    hostname)   echo "Hostname [${CONFIG[HOSTNAME]}]" ;;
    locale)     echo "Locale/Timezone [${CONFIG[TIMEZONE]}]" ;;
    kernel)     echo "Kernel [${CONFIG[KERNEL_METHOD]}]" ;;
    bootloader) echo "Bootloader [${CONFIG[BOOTLOADER]}]" ;;
    user)       echo "User [${CONFIG[USERNAME]:-not set}]" ;;
    desktop)    echo "Desktop [${CONFIG[DESKTOP]}]" ;;
    review)     echo "Review configuration" ;;
  esac
}

main_menu() {
  while true; do
    local items=() step
    for step in "${STEP_ORDER[@]}"; do
      items+=("$step" "$(step_label "$step")")
    done
    items+=("install" ">>> Run installation <<<")
    items+=("quit" "Exit")

    local choice
    choice=$(d_menu "Main menu" "Configure each step, then run installation." 22 70 14 "${items[@]}")
    [[ -n "$choice" ]] || continue

    case "$choice" in
      keymap)     step_keymap ;;
      network)    step_network ;;
      mirror)     step_mirror ;;
      disk)       step_disk ;;
      profile)    step_profile ;;
      stage3)     step_stage3 ;;
      hostname)   step_hostname ;;
      locale)     step_locale ;;
      kernel)     step_kernel ;;
      bootloader) step_bootloader ;;
      user)       step_user ;;
      desktop)    step_desktop ;;
      review)     step_review ;;
      install)    do_install ;;
      quit)       clear; exit 0 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

preflight
main_menu
