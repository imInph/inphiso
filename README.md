# inphiso

A single Bash script that flashes Windows and Linux disk images to USB drives.
It
handles the stuff that usually breaks: Windows ISOs from Linux, oversized
`install.wim` files, and the FAT32 4 GiB limit that trips up `dd` and plain
file copies.

## Why this exists

Flashing a Windows ISO from Linux is a pain. `dd` won't give you a bootable UEFI
stick, Ventoy works right up until it doesn't, and copying files to FAT32 falls
over the second `install.wim` goes past 4 GiB, which it does on basically every
Windows 11 ISO. inphiso gets around that by splitting the image into `.swm`
chunks that Windows Setup stitches back together on its own. Linux ISOs are
different (they're hybrid images), so those just get written raw.

## What it does

- Lists `.iso`, `.img`, `.raw`, `.dd` and `.usb` files in the current directory,
  plain or compressed (`.img.xz`, `.img.gz`, `.img.bz2`, `.img.zst`), with an
  `Exit` option at the end of the file and drive pickers if you change your mind.
- Streams compressed images through `xz` / `gzip` / `bzip2` / `zstd` straight
  into `dd`, so nothing gets unpacked to your disk first.
- Figures out if the image is Windows or Linux and picks the right method. If it
  genuinely can't tell — including raw `.img` files, which can't be mounted and
  inspected at all — it asks instead of guessing.
- Splits `install.wim` into `.swm` files with `wimlib-imagex` when it's too big
  for FAT32.
- Checks for the tools it needs up front, works out your package manager
  (apt / dnf / pacman / zypper), shows you the exact install command, and waits
  for a yes before running it.
- Shows you the target drive's size, model, and partitions, and makes you type
  `YES` before writing anything. The system disk isn't even in the list.
- Cleans up after itself if something goes wrong, so no leftover mounts.

## Boot support

| ISO type | Legacy BIOS | UEFI |
|---|---|---|
| Windows | Yes (MBR boot flag) | Yes on most firmware* |
| Linux / hybrid | Depends on the ISO | Depends on the ISO |

*The Windows UEFI path leans on firmware loading `EFI/BOOT/BOOTX64.EFI` from a
FAT32 partition on an MBR disk. Works on the big majority of modern machines,
but it's not guaranteed everywhere. If your firmware is strict and wants
GPT + a dedicated ESP, grab [Rufus](https://rufus.ie) on Windows instead.

## Requirements

It checks for these and offers to install whatever's missing:

`parted`, `partprobe`, `wipefs`, `mkfs.fat`, `rsync`, `lsblk`, `blockdev`, from
`parted` / `util-linux` / `dosfstools` / `rsync` depending on the tool.

`wimlib-imagex` only gets pulled in if a Windows ISO's `install.wim` is over
4 GiB. It's `wimtools` on Debian/Ubuntu, `wimlib` on Arch/Fedora/openSUSE.

## Usage

```bash
chmod +x inphiso.sh
sudo ./inphiso.sh
```

From there it's interactive: pick an image, pick the drive, check the summary,
type `YES`. Both pickers have an `Exit` entry as the last option.

Raw images (`.img`, `.raw`) are written with `dd`, same as a hybrid ISO. The
Windows path needs a real, uncompressed ISO, since it mounts the image and
copies files out of it.

Compressed images are detected by their magic bytes, not their filename, and
decompressed on the fly as they're written. If the decompressor isn't installed
it offers to install it, same as the other tools. One caveat: `xz` records the
uncompressed size, so it can check the image against the drive before writing,
but `gzip`, `bzip2` and `zstd` don't — with those, a too-big image isn't caught
until `dd` runs out of room partway through.

## Heads-up

- Run it as root.
- The system-disk exclusion finds the disk your root filesystem is on. On LVM or
  LUKS setups it might not catch it, so **eyeball the drive in the summary
  yourself** before typing `YES`. Don't lean on the auto-exclusion alone.
- Windows UEFI boot depends on your firmware (see above).
- Linux boot support is down to the ISO; inphiso just writes it faithfully.

## License

MIT, see [LICENSE](LICENSE).

## Notes

I'm a student who knows some Bash, enough to read this script but not enough to
write it all myself. Built it with Claude Code to fix a problem I kept running
into: flashing Windows ISOs from Linux. I directed and tested it, but a lot of
the code is AI-assisted. Sharing it in case it saves someone else the headache.
