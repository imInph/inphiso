#!/usr/bin/env bash
# =============================================================================
# inphiso.sh - flash Windows or Linux disk images to a USB drive
#
# Input images:
#   The picker lists .iso, .img, .raw, .dd and .usb files, plain or compressed
#   with xz / gzip / bzip2 / zstd (.img.xz and friends). Windows mode needs a
#   mountable ISO; anything that can't be loop-mounted (raw .img/.raw images
#   carry a partition table, not a filesystem, and compressed files can't be
#   mounted at all) goes down the raw dd path. Compressed images are streamed
#   through the decompressor into dd, never unpacked to disk first.
#
# Boot support:
#   Windows ISOs: works on Legacy BIOS (MBR boot flag on a single FAT32
#     partition) and on UEFI, since most firmware will load
#     EFI/BOOT/BOOTX64.EFI off a FAT32 volume on an MBR disk without needing
#     a GPT ESP. Some strict UEFI firmware wants GPT+ESP though, and for those
#     you're better off using Rufus on Windows.
#   Linux ISOs: written with dd, so boot support is whatever the ISO supports
#     (hybrid images usually do both BIOS and UEFI).
#
# Filesystems:
#   Windows: one FAT32 partition. If sources/install.wim is bigger than the
#     FAT32 4 GiB file limit, it gets split into .swm chunks with
#     wimlib-imagex. Windows Setup reads .swm files on its own, nothing extra
#     needed.
#   Linux: no filesystem, just a raw dd write to the device.
#
# Tools needed (checked + offered for install at startup):
#   parted, wipefs, partprobe  (parted)
#   mkfs.fat                   (dosfstools)
#   rsync                      (rsync)
#   lsblk, blockdev            (util-linux, usually already there)
#   wimlib-imagex              (wimtools on Debian/Ubuntu, wimlib elsewhere)
#                              only needed if install.wim is over 4 GiB
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
NC='\033[0m'
BOLD='\033[1m'

# ── Globals ───────────────────────────────────────────────────────────────────
ISO_FILE=""
USB_DEV=""
USB_PART=""
ISO_TYPE=""      # "windows" | "linux"
ISO_MOUNT=""     # set when ISO is mounted
USB_MNT=""       # set when USB partition is mounted
PROBE_MOUNT=""   # set during ISO type detection probe
WIN_FLASH_OK=""  # set to 1 only after flash_windows completes every step
COMPRESSION=""   # "" | xz | gzip | bzip2 | zstd — set in select_file()

# ── Cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
    local code=$?
    set +e   # don't abort inside cleanup
    local _mp
    for _mp in "$USB_MNT" "$ISO_MOUNT" "$PROBE_MOUNT"; do
        [[ -n "$_mp" && -d "$_mp" ]] || continue
        mountpoint -q "$_mp" 2>/dev/null && umount "$_mp" 2>/dev/null
        rmdir "$_mp" 2>/dev/null
    done
    if [[ $code -ne 0 && $code -ne 130 ]]; then
        printf '\n%b  Exited with error %d. The USB may be in an unusable state.%b\n' \
            "$RED" "$code" "$NC" >&2
    fi
}
trap cleanup EXIT INT TERM

# ── Logging helpers ───────────────────────────────────────────────────────────
die()  { printf '%b  ERROR: %s%b\n' "$RED"    "$*" "$NC" >&2; exit 1; }
info() { printf '%b  %s%b\n'        "$CYAN"   "$*" "$NC"; }
warn() { printf '%b  WARNING: %s%b\n' "$YELLOW" "$*" "$NC"; }
ok()   { printf '%b  %s%b\n'        "$GREEN"  "$*" "$NC"; }

# ── Banner ────────────────────────────────────────────────────────────────────
banner() {
    clear
    printf '%b' "${CYAN}${BOLD}"
    printf '  ╔══════════════════════════════════════════════╗\n'
    printf '  ║           inphiso  ·  USB Flasher            ║\n'
    printf '  ╚══════════════════════════════════════════════╝\n'
    printf '%b\n' "${NC}"
}

# ── Root check ────────────────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (re-run with sudo)."
}

# ── Dependency check & install ────────────────────────────────────────────────
# Format: "binary|apt-pkg|dnf-pkg|pacman-pkg|zypper-pkg"
TOOL_MAP=(
    "parted|parted|parted|parted|parted"
    "wipefs|util-linux|util-linux|util-linux|util-linux"
    "partprobe|parted|parted|parted|parted"
    "mkfs.fat|dosfstools|dosfstools|dosfstools|dosfstools"
    "lsblk|util-linux|util-linux|util-linux|util-linux"
    "blockdev|util-linux|util-linux|util-linux|util-linux"
    "rsync|rsync|rsync|rsync|rsync"
)

detect_pkg_manager() {
    if   command -v apt-get &>/dev/null; then printf 'apt'
    elif command -v dnf     &>/dev/null; then printf 'dnf'
    elif command -v pacman  &>/dev/null; then printf 'pacman'
    elif command -v zypper  &>/dev/null; then printf 'zypper'
    else printf 'unknown'
    fi
}

# Print the package name for a binary+pkgmgr combo, or "" if not found.
pkg_for_tool() {
    local tool="$1" pkgmgr="$2"
    local entry t apt_p dnf_p pac_p zpp_p
    for entry in "${TOOL_MAP[@]}"; do
        IFS='|' read -r t apt_p dnf_p pac_p zpp_p <<< "$entry"
        if [[ "$t" == "$tool" ]]; then
            case "$pkgmgr" in
                apt)    printf '%s' "$apt_p" ;;
                dnf)    printf '%s' "$dnf_p" ;;
                pacman) printf '%s' "$pac_p" ;;
                zypper) printf '%s' "$zpp_p" ;;
            esac
            return
        fi
    done
}

install_cmd_for() {
    # $1 = pkgmgr, remaining = package names
    local pkgmgr="$1"; shift
    case "$pkgmgr" in
        apt)    printf 'apt-get install -y %s' "$*" ;;
        dnf)    printf 'dnf install -y %s'     "$*" ;;
        pacman) printf 'pacman -S --noconfirm %s' "$*" ;;
        zypper) printf 'zypper install -y %s'  "$*" ;;
    esac
}

check_deps() {
    local pkgmgr missing_tools=()
    pkgmgr="$(detect_pkg_manager)"

    local entry t _r _r2 _r3 _r4
    for entry in "${TOOL_MAP[@]}"; do
        IFS='|' read -r t _r _r2 _r3 _r4 <<< "$entry"
        command -v "$t" &>/dev/null || missing_tools+=("$t")
    done

    if [[ ${#missing_tools[@]} -eq 0 ]]; then
        ok "All required tools are present."
        return
    fi

    if [[ "$pkgmgr" == "unknown" ]]; then
        die "No supported package manager found (apt/dnf/pacman/zypper).\n  Install these tools manually: ${missing_tools[*]}"
    fi

    # Collect deduplicated package list
    local missing_pkgs=()
    declare -A _seen_pkgs
    local tool pkg
    for tool in "${missing_tools[@]}"; do
        pkg="$(pkg_for_tool "$tool" "$pkgmgr")"
        if [[ -n "$pkg" && -z "${_seen_pkgs[$pkg]+_}" ]]; then
            missing_pkgs+=("$pkg")
            _seen_pkgs["$pkg"]=1
        fi
    done

    local install_cmd
    install_cmd="$(install_cmd_for "$pkgmgr" "${missing_pkgs[@]}")"

    printf '\n%b  Missing tools:%b %s\n' "$YELLOW" "$NC" "${missing_tools[*]}"
    printf '%b  Packages to install:%b %s\n' "$YELLOW" "$NC" "${missing_pkgs[*]}"
    printf '%b  Command that will run (with sudo):%b sudo %s\n\n' "$YELLOW" "$NC" "$install_cmd"
    printf '  Proceed with installation? [y/N] '
    read -r _ans
    [[ "${_ans,,}" == "y" ]] || die "Aborted. Install the missing tools and re-run."

    # shellcheck disable=SC2086  # word-split on install_cmd is intentional
    sh -c "$install_cmd" || die "Installation failed. Install missing tools manually and re-run."

    # Re-verify
    local still_missing=()
    for tool in "${missing_tools[@]}"; do
        command -v "$tool" &>/dev/null || still_missing+=("$tool")
    done
    [[ ${#still_missing[@]} -eq 0 ]] \
        || die "Still missing after install: ${still_missing[*]}"
    ok "All required tools are now present."
}

# Returns 0 if wimlib-imagex is available, 1 otherwise (prints install hint).
have_wimlib() {
    if command -v wimlib-imagex &>/dev/null; then
        return 0
    fi
    local pkgmgr
    pkgmgr="$(detect_pkg_manager)"
    local hint
    case "$pkgmgr" in
        apt)    hint="sudo apt-get install wimtools" ;;
        dnf)    hint="sudo dnf install wimlib" ;;
        pacman) hint="sudo pacman -S wimlib" ;;
        zypper) hint="sudo zypper install wimlib" ;;
        *)      hint="install wimlib-imagex via your package manager" ;;
    esac
    warn "wimlib-imagex not found. Install it with: ${hint}"
    return 1
}

# ── Compressed images ─────────────────────────────────────────────────────────
# Base extensions the picker lists. .iso is a filesystem image, so it gets
# probed and mounted; .img/.raw/.dd/.usb are usually raw whole-disk images that
# can't be mounted directly — those fall back to asking in detect_iso_type().
IMAGE_EXTS=(iso img raw dd usb)
# Compression suffixes stacked on top of those (armbian.img.xz, rpi.img.gz, ...).
# Streamed straight into dd, so the image is never unpacked to disk first.
COMPRESS_EXTS=(xz gz bz2 zst)

# Print the compression format from the file's magic bytes, or "" if it isn't
# compressed. Magic beats the extension: a mislabelled file still works.
detect_compression() {
    local magic
    magic=$(od -An -tx1 -N6 "$1" 2>/dev/null | tr -d ' \n')
    case "$magic" in
        fd377a585a00*) printf 'xz'    ;;
        1f8b*)         printf 'gzip'  ;;
        425a68*)       printf 'bzip2' ;;
        28b52ffd*)     printf 'zstd'  ;;
        *)             printf ''      ;;
    esac
}

# Print the binary that decompresses a given format.
_decomp_bin() {
    case "$1" in
        xz)    printf 'xz'    ;;
        gzip)  printf 'gzip'  ;;
        bzip2) printf 'bzip2' ;;
        zstd)  printf 'zstd'  ;;
    esac
}

# Make sure the decompressor for $1 is installed. Same offer-then-install shape
# as check_deps, but for one conditional tool, like have_wimlib.
ensure_decompressor() {
    local comp="$1" bin pkgmgr pkg install_cmd
    bin="$(_decomp_bin "$comp")"
    command -v "$bin" &>/dev/null && return 0

    pkgmgr="$(detect_pkg_manager)"
    pkg="$bin"
    [[ "$comp" == "xz" && "$pkgmgr" == "apt" ]] && pkg="xz-utils"

    if [[ "$pkgmgr" == "unknown" ]]; then
        die "Need ${bin} to decompress this image, and no supported package manager was found.\n  Install ${bin} manually and re-run."
    fi

    install_cmd="$(install_cmd_for "$pkgmgr" "$pkg")"
    printf '\n%b  %s is needed to decompress this image, and it is not installed.%b\n' \
        "$YELLOW" "$bin" "$NC"
    printf '%b  Command that will run (with sudo):%b sudo %s\n\n' "$YELLOW" "$NC" "$install_cmd"
    printf '  Proceed with installation? [y/N] '
    read -r _ans
    [[ "${_ans,,}" == "y" ]] || die "Aborted. Install ${bin} and re-run."

    sh -c "$install_cmd" || die "Installation failed. Install ${bin} manually and re-run."
    command -v "$bin" &>/dev/null || die "Still missing after install: ${bin}"
    ok "${bin} installed."
}

# Print the uncompressed size in bytes, or "" when the format doesn't record it.
# gzip only stores the size modulo 4 GiB and bzip2 stores nothing, so for those
# the size check is skipped rather than done on a number that could be wrong.
uncompressed_size() {
    case "$COMPRESSION" in
        "")  stat -c%s "$1" ;;
        xz)  xz --robot --list "$1" 2>/dev/null \
                 | awk -F'\t' '($1 == "file" || $1 == "totals") && $5 ~ /^[0-9]+$/ { print $5; exit }' ;;
        *)   printf '' ;;
    esac
}

# ── Image file selection ──────────────────────────────────────────────────────
select_file() {
    banner
    printf '%b%b  Disk images in current directory:%b\n\n' "$WHITE" "$BOLD" "$NC"

    # Build: -iname "*.iso" -o -iname "*.iso.xz" -o ... -o -iname "*.img" -o ...
    local -a _name_expr=()
    local _ext _pat
    for _ext in "${IMAGE_EXTS[@]}"; do
        # "iso" plus "iso.xz", "iso.gz", ... (prefix-expands COMPRESS_EXTS)
        for _pat in "$_ext" "${COMPRESS_EXTS[@]/#/${_ext}.}"; do
            [[ ${#_name_expr[@]} -gt 0 ]] && _name_expr+=(-o)
            _name_expr+=(-iname "*.${_pat}")
        done
    done

    local -a _all_files
    mapfile -t _all_files < <(find "$(pwd)" -maxdepth 1 -type f \( "${_name_expr[@]}" \) | sort)

    if [[ ${#_all_files[@]} -eq 0 ]]; then
        warn "No image files found (${IMAGE_EXTS[*]}, plain or ${COMPRESS_EXTS[*]}-compressed) — showing all files instead."
        mapfile -t _all_files < <(find "$(pwd)" -maxdepth 1 -type f | sort)
    fi

    [[ ${#_all_files[@]} -gt 0 ]] || die "No files found in the current directory."

    local i _sz
    for i in "${!_all_files[@]}"; do
        _sz=$(du -sh "${_all_files[$i]}" 2>/dev/null | awk '{print $1}')
        printf '  %b[%2d]%b  %-52s %b%s%b\n' \
            "$CYAN" "$((i+1))" "$NC" \
            "$(basename "${_all_files[$i]}")" \
            "$GRAY" "$_sz" "$NC"
    done

    local _exit_opt=$(( ${#_all_files[@]} + 1 ))
    printf '  %b[%2d]%b  %bExit%b\n' "$CYAN" "$_exit_opt" "$NC" "$GRAY" "$NC"

    printf '\n  %bWhich file do you want to flash?%b\n  > ' "$YELLOW" "$NC"
    read -r _choice

    if ! [[ "$_choice" =~ ^[0-9]+$ ]] \
       || [[ "$_choice" -lt 1 ]] \
       || [[ "$_choice" -gt "$_exit_opt" ]]; then
        die "Invalid selection."
    fi

    if [[ "$_choice" -eq "$_exit_opt" ]]; then
        printf '\n%b  Exiting. Nothing was written.%b\n\n' "$CYAN" "$NC"
        exit 0
    fi

    ISO_FILE="${_all_files[$(( _choice - 1 ))]}"
    [[ -f "$ISO_FILE" && -r "$ISO_FILE" ]] || die "File is not readable: ${ISO_FILE}"

    COMPRESSION="$(detect_compression "$ISO_FILE")"

    ok "Selected: $(basename "$ISO_FILE")"

    if [[ -n "$COMPRESSION" ]]; then
        info "Compressed image (${COMPRESSION}) — it gets decompressed as it's written."
        printf '%b  A Windows installer would have to be unpacked first, since Windows mode\n' "$GRAY"
        printf '  copies files out of a mounted ISO. Raw images are fine compressed.%b\n' "$NC"
        ensure_decompressor "$COMPRESSION"
    fi

    sleep 1
}

# ── Detect which disk the root filesystem lives on ────────────────────────────
get_root_disk() {
    local root_part=""
    if command -v findmnt &>/dev/null; then
        root_part=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    else
        root_part=$(awk '$2=="/" {print $1; exit}' /proc/mounts 2>/dev/null || true)
    fi
    [[ -z "$root_part" ]] && return
    lsblk -no PKNAME "$root_part" 2>/dev/null | head -1 || true
}

# ── Drive selection ───────────────────────────────────────────────────────────
select_drive() {
    banner
    printf '%b%b  Available block devices:%b\n\n' "$WHITE" "$BOLD" "$NC"

    local root_disk
    root_disk="$(get_root_disk)"

    local -a _all_names
    mapfile -t _all_names < <(lsblk -d -o NAME --noheadings | grep -v '^loop' || true)
    [[ ${#_all_names[@]} -gt 0 ]] || die "No drives detected."

    local -a eligible=()
    local name
    for name in "${_all_names[@]}"; do
        [[ -n "$root_disk" && "$name" == "$root_disk" ]] && continue
        eligible+=("$name")
    done
    [[ ${#eligible[@]} -gt 0 ]] || die "No eligible drives found (system disk excluded)."

    local i _size _model _rem _rem_tag
    for i in "${!eligible[@]}"; do
        name="${eligible[$i]}"
        _size=$(lsblk -dn -o SIZE "/dev/${name}" 2>/dev/null || printf '?')
        _model=$(lsblk -dn -o MODEL "/dev/${name}" 2>/dev/null | xargs 2>/dev/null || printf 'unknown')
        _rem=$(cat "/sys/block/${name}/removable" 2>/dev/null || printf '?')
        _rem_tag=""
        [[ "$_rem" == "1" ]] && _rem_tag="${GREEN}[removable]${NC}"
        printf '  %b[%2d]%b  /dev/%-12s  %-8s  %-30s %b\n' \
            "$CYAN" "$((i+1))" "$NC" \
            "$name" "$_size" "$_model" "$_rem_tag"
    done

    local _exit_opt=$(( ${#eligible[@]} + 1 ))
    printf '  %b[%2d]%b  %bExit%b\n' "$CYAN" "$_exit_opt" "$NC" "$GRAY" "$NC"

    printf '\n  %b%b  ! WARNING: The selected drive will be completely erased !%b\n\n' \
        "$RED" "$BOLD" "$NC"
    printf '  %bWhich drive?%b\n  > ' "$YELLOW" "$NC"
    read -r _choice

    if ! [[ "$_choice" =~ ^[0-9]+$ ]] \
       || [[ "$_choice" -lt 1 ]] \
       || [[ "$_choice" -gt "$_exit_opt" ]]; then
        die "Invalid selection."
    fi

    if [[ "$_choice" -eq "$_exit_opt" ]]; then
        printf '\n%b  Exiting. Nothing was written.%b\n\n' "$CYAN" "$NC"
        exit 0
    fi

    local chosen="${eligible[$(( _choice - 1 ))]}"

    # Belt-and-suspenders: never target root disk
    [[ -n "$root_disk" && "$chosen" == "$root_disk" ]] \
        && die "Refusing to target the system disk (/dev/${chosen})."

    USB_DEV="/dev/${chosen}"

    # nvme0n1 → nvme0n1p1; sda → sda1
    if [[ "$chosen" =~ [0-9]$ ]]; then
        USB_PART="${USB_DEV}p1"
    else
        USB_PART="${USB_DEV}1"
    fi

    ok "Selected drive: ${USB_DEV}"
    sleep 1
}

# ── Confirmation ──────────────────────────────────────────────────────────────
confirm() {
    banner
    printf '%b%b  Please review your selections:%b\n\n' "$WHITE" "$BOLD" "$NC"

    local _iso_sz _drv_sz _drv_model
    _iso_sz=$(du -sh "$ISO_FILE" 2>/dev/null | awk '{print $1}')
    _drv_sz=$(lsblk -dn -o SIZE "$USB_DEV" 2>/dev/null || printf '?')
    _drv_model=$(lsblk -dn -o MODEL "$USB_DEV" 2>/dev/null | xargs 2>/dev/null || printf 'unknown')

    local _comp_tag=""
    [[ -n "$COMPRESSION" ]] && _comp_tag=", ${COMPRESSION}-compressed"
    printf '  %bImage:%b %s  (%s%s)\n' "$CYAN" "$NC" "$(basename "$ISO_FILE")" "$_iso_sz" "$_comp_tag"
    printf '  %bDrive:%b %s  %s  %s\n\n' "$CYAN" "$NC" "$USB_DEV" "$_drv_sz" "$_drv_model"
    printf '  %bCurrent partitions on %s:%b\n' "$CYAN" "$USB_DEV" "$NC"
    lsblk "$USB_DEV" 2>/dev/null || true
    printf '\n  %b%b  ALL DATA ON %s WILL BE PERMANENTLY DESTROYED.%b\n\n' \
        "$RED" "$BOLD" "$USB_DEV" "$NC"
    printf '  %bType%b %b%bYES%b %b(all caps) to continue:%b\n  > ' \
        "$YELLOW" "$NC" "$WHITE" "$BOLD" "$NC" "$YELLOW" "$NC"
    read -r _confirm

    if [[ "$_confirm" != "YES" ]]; then
        printf '\n%b  Aborted. Nothing was written.%b\n\n' "$RED" "$NC"
        exit 0
    fi
    printf '\n'
}

# ── ISO type detection ────────────────────────────────────────────────────────
detect_iso_type() {
    # A compressed image can't be mounted, and the Windows path needs to mount
    # one, so the raw dd path is the only thing that can write it. Said so at
    # selection time, before anything was confirmed.
    if [[ -n "$COMPRESSION" ]]; then
        ISO_TYPE="linux"
        info "Compressed image (${COMPRESSION}) — writing it raw, decompressed on the fly."
        return
    fi

    info "Probing image type..."
    PROBE_MOUNT="$(mktemp -d /tmp/iso_probe.XXXXXX)"
    # Raw images (.img/.raw) hold a partition table, not a filesystem, so a loop
    # mount of the whole file fails. That's not fatal — just ask instead.
    if ! mount -o loop,ro "$ISO_FILE" "$PROBE_MOUNT" 2>/dev/null; then
        rmdir "$PROBE_MOUNT" 2>/dev/null || true
        PROBE_MOUNT=""
        warn "Can't mount this image, so its contents can't be inspected."
        printf '%b  That is normal for raw disk images (.img, .raw) — they get written\n' "$GRAY"
        printf '  raw, same as a hybrid ISO. Pick Linux/generic unless you know this is\n'
        printf '  a Windows installer image.%b\n' "$NC"
        _prompt_iso_type
        return
    fi

    local is_win=0 is_linux=0

    # Windows markers
    if [[ -f "${PROBE_MOUNT}/sources/install.wim" \
       || -f "${PROBE_MOUNT}/sources/install.esd" \
       || -f "${PROBE_MOUNT}/bootmgr" \
       || -d "${PROBE_MOUNT}/Windows" ]]; then
        is_win=1
    fi

    # Linux / hybrid markers
    if [[ -d "${PROBE_MOUNT}/isolinux" \
       || -d "${PROBE_MOUNT}/boot/grub" \
       || -d "${PROBE_MOUNT}/boot/grub2" \
       || -f "${PROBE_MOUNT}/.disk/info" ]]; then
        is_linux=1
    fi
    # EFI/BOOT alone only counts as Linux if no Windows markers were found
    # (Windows ISOs also contain EFI/BOOT)
    if [[ $is_win -eq 0 && -d "${PROBE_MOUNT}/EFI/BOOT" ]]; then
        is_linux=1
    fi

    umount "$PROBE_MOUNT" 2>/dev/null || true
    rmdir  "$PROBE_MOUNT" 2>/dev/null || true
    PROBE_MOUNT=""

    if   [[ $is_win -eq 1 && $is_linux -eq 0 ]]; then
        ISO_TYPE="windows"; info "Detected: Windows ISO"
    elif [[ $is_linux -eq 1 && $is_win -eq 0 ]]; then
        ISO_TYPE="linux";   info "Detected: Linux/hybrid ISO"
    else
        if [[ $is_win -eq 1 && $is_linux -eq 1 ]]; then
            warn "Image has markers for both Windows and Linux."
        else
            warn "Could not determine image type from contents."
        fi
        _prompt_iso_type
    fi
}

_prompt_iso_type() {
    printf '\n  %bSelect flashing mode:%b\n' "$YELLOW" "$NC"
    printf '  %b[1]%b  Windows  — mount-and-copy to FAT32 partition\n' "$CYAN" "$NC"
    printf '  %b[2]%b  Linux/generic  — dd directly to raw device\n'   "$CYAN" "$NC"
    printf '  > '
    read -r _mode
    case "$_mode" in
        1) ISO_TYPE="windows" ;;
        2) ISO_TYPE="linux" ;;
        *) die "Invalid selection." ;;
    esac
}

# ── Unmount all partitions on a device (best-effort) ─────────────────────────
_unmount_device() {
    local dev="$1"
    # Read current mountpoints from the kernel
    while IFS= read -r mp; do
        if [[ -n "$mp" ]]; then
            umount "$mp" 2>/dev/null || true
        fi
    done < <(lsblk -ln -o MOUNTPOINT "$dev" 2>/dev/null | grep -v '^$' || true)
}

# ── Flash: Windows path ───────────────────────────────────────────────────────
flash_windows() {
    local step=1 total=7

    ISO_MOUNT="$(mktemp -d /tmp/iso_mount.XXXXXX)"
    USB_MNT="$(mktemp -d /tmp/usb_mount.XXXXXX)"

    # 1 — Unmount existing USB partitions
    printf '%b[%d/%d]%b Unmounting any mounted USB partitions...\n' \
        "$CYAN" "$step" "$total" "$NC"
    _unmount_device "$USB_DEV"
    step=$(( step + 1 ))

    # 2 — Mount ISO
    printf '%b[%d/%d]%b Mounting ISO...\n' "$CYAN" "$step" "$total" "$NC"
    mount -o loop,ro "$ISO_FILE" "$ISO_MOUNT" \
        || die "Failed to mount image. Windows mode needs a mountable ISO."
    step=$(( step + 1 ))

    # 3 — Partition
    printf '%b[%d/%d]%b Wiping and repartitioning %s...\n' \
        "$CYAN" "$step" "$total" "$NC" "$USB_DEV"
    wipefs -a "$USB_DEV"
    parted -s "$USB_DEV" mklabel msdos
    parted -s "$USB_DEV" mkpart primary fat32 1MiB 100%
    parted -s "$USB_DEV" set 1 boot on
    partprobe "$USB_DEV"
    sleep 2
    step=$(( step + 1 ))

    # 4 — Format FAT32
    printf '%b[%d/%d]%b Formatting %s as FAT32...\n' \
        "$CYAN" "$step" "$total" "$NC" "$USB_PART"
    mkfs.fat -F32 -n "WINUSB" "$USB_PART"
    step=$(( step + 1 ))

    # 5 — Mount USB partition
    printf '%b[%d/%d]%b Mounting USB partition...\n' "$CYAN" "$step" "$total" "$NC"
    mount "$USB_PART" "$USB_MNT" || die "Failed to mount USB partition."
    step=$(( step + 1 ))

    # 6 — Copy files (handling FAT32 4 GiB limit for install.wim)
    printf '%b[%d/%d]%b Copying Windows files %b(this may take several minutes)%b...\n' \
        "$CYAN" "$step" "$total" "$NC" "$GRAY" "$NC"

    local wim_path="${ISO_MOUNT}/sources/install.wim"
    local fat32_limit wim_size=0
    fat32_limit=$(( 4 * 1024 * 1024 * 1024 - 1 ))
    [[ -f "$wim_path" ]] && wim_size=$(stat -c%s "$wim_path")

    if [[ $wim_size -gt $fat32_limit ]]; then
        warn "install.wim is $(( wim_size / 1024 / 1024 )) MiB — exceeds the FAT32 4 GiB limit."
        have_wimlib || die "wimlib-imagex is required to split install.wim. Install it and re-run."
        info "Copying all files except install.wim..."
        rsync -rt --no-owner --no-group --no-perms --progress --exclude='/sources/install.wim' "${ISO_MOUNT}/" "${USB_MNT}/"

        local dest_src="${USB_MNT}/sources"
        mkdir -p "$dest_src"
        info "Splitting install.wim into .swm chunks (3800 MiB each)..."
        # Windows Setup discovers .swm files automatically alongside install.swm
        wimlib-imagex split "$wim_path" "${dest_src}/install.swm" 3800
        ok "install.wim split successfully."
    else
        rsync -rt --no-owner --no-group --no-perms --progress "${ISO_MOUNT}/" "${USB_MNT}/"
    fi
    step=$(( step + 1 ))

    # 7 — Sync and unmount
    printf '%b[%d/%d]%b Syncing and unmounting...\n' "$CYAN" "$step" "$total" "$NC"
    sync
    umount "$USB_MNT";  rmdir "$USB_MNT";  USB_MNT=""
    umount "$ISO_MOUNT"; rmdir "$ISO_MOUNT"; ISO_MOUNT=""
    WIN_FLASH_OK=1
}

# ── Flash: Linux / hybrid ISO path ───────────────────────────────────────────
flash_linux() {
    local iso_bytes drv_bytes
    iso_bytes="$(uncompressed_size "$ISO_FILE")"
    drv_bytes=$(blockdev --getsize64 "$USB_DEV")

    if [[ -z "$iso_bytes" ]]; then
        warn "A ${COMPRESSION} file doesn't record its uncompressed size, so it can't be checked against the drive up front."
        printf '%b  If it turns out to be too big, the write fails partway through and the\n' "$GRAY"
        printf '  drive is left unbootable — nothing is lost except the time.%b\n' "$NC"
    elif [[ $iso_bytes -gt $drv_bytes ]]; then
        die "Image ($(( iso_bytes / 1024 / 1024 )) MiB) is larger than the target drive" \
            "($(( drv_bytes / 1024 / 1024 )) MiB)."
    fi

    _unmount_device "$USB_DEV"

    local _what="image"
    [[ -n "$COMPRESSION" ]] && _what="decompressed image"
    printf '%b[1/2]%b Writing %s to %s %b(this may take several minutes)%b...\n' \
        "$CYAN" "$NC" "$_what" "$USB_DEV" "$GRAY" "$NC"

    local -a dd_opts=(bs=4M conv=fsync)
    # status=progress is available in GNU coreutils dd >= 8.24
    if dd if=/dev/null of=/dev/null status=progress 2>/dev/null; then
        dd_opts+=(status=progress)
    fi

    if [[ -n "$COMPRESSION" ]]; then
        # pipefail (set at the top) makes a failing decompressor fail the write
        "$(_decomp_bin "$COMPRESSION")" -dc "$ISO_FILE" | dd of="$USB_DEV" "${dd_opts[@]}"
    else
        dd if="$ISO_FILE" of="$USB_DEV" "${dd_opts[@]}"
    fi

    printf '%b[2/2]%b Syncing...\n' "$CYAN" "$NC"
    sync

    printf '\n%b%b  Done! Linux USB is ready.%b\n' "$GREEN" "$BOLD" "$NC"
    printf '%b  Boot mode: depends on the ISO (hybrid images typically support BIOS and UEFI).%b\n' \
        "$GRAY" "$NC"
    printf '%b  Safely remove the drive.%b\n\n' "$GRAY" "$NC"
}

# ── Entry point ───────────────────────────────────────────────────────────────
require_root
check_deps
banner
select_file
select_drive
confirm
detect_iso_type

case "$ISO_TYPE" in
    windows)
        flash_windows
        [[ "${WIN_FLASH_OK}" == "1" ]] || die "Internal error: flash_windows returned without setting WIN_FLASH_OK."
        printf '\n%b%b  Done! Windows USB is ready.%b\n' "$GREEN" "$BOLD" "$NC"
        printf '%b  Boot modes: Legacy BIOS (MBR) + UEFI (EFI/BOOT on FAT32 — firmware-dependent).%b\n' \
            "$GRAY" "$NC"
        printf '%b  Safely remove the drive.%b\n\n' "$GRAY" "$NC"
        ;;
    linux)   flash_linux   ;;
    *)       die "Internal error: unknown ISO type '${ISO_TYPE}'." ;;
esac
