#!/usr/bin/env bash
set -euo pipefail

kernel=$1
config=$2
start4=$3
fixup4=$4
firmware_license=$5
dtb=$6
user_disk=$7
firmware_revision=$8
image=$9
readonly image_size=$((64 * 1024 * 1024))
readonly partition_offset=$((1024 * 1024))
readonly partition_start=2048
readonly user_partition_start=122880
readonly user_partition_sectors=8192
readonly boot_partition_sectors=$((user_partition_start - partition_start))

mkdir -p "$(dirname "$image")"
truncate -s 0 "$image"
truncate -s "$image_size" "$image"
export SOURCE_DATE_EPOCH=315532800
export TZ=UTC

python3 - "$image" <<'PY'
import struct
import sys

path = sys.argv[1]
boot_start = 2048
user_start = 122880
boot_count = user_start - boot_start
user_count = 8192
boot_entry = bytes((0x80, 0xFE, 0xFF, 0xFF, 0x0C, 0xFE, 0xFF, 0xFF))
boot_entry += struct.pack("<II", boot_start, boot_count)
user_entry = bytes((0x00, 0xFE, 0xFF, 0xFF, 0x0E, 0xFE, 0xFF, 0xFF))
user_entry += struct.pack("<II", user_start, user_count)
mbr = bytearray(512)
mbr[446:462] = boot_entry
mbr[462:478] = user_entry
mbr[510:512] = b"\x55\xaa"
with open(path, "r+b") as disk:
    disk.write(mbr)
PY

drive="$image@@$partition_offset"
mformat -i "$drive" -F -T "$boot_partition_sectors" -H "$partition_start" -N 54484b4f -v THEKORN ::
mcopy -i "$drive" "$kernel" ::kernel8.img
mcopy -i "$drive" "$config" ::config.txt
mcopy -i "$drive" "$start4" ::start4.elf
mcopy -i "$drive" "$fixup4" ::fixup4.dat
mcopy -i "$drive" "$firmware_license" ::LICENCE.broadcom
mcopy -i "$drive" "$dtb" ::bcm2711-rpi-4-b.dtb

if [[ $(stat -c %s "$user_disk") -ne $((user_partition_sectors * 512)) ]]; then
  echo "user FAT image must contain exactly $user_partition_sectors sectors" >&2
  exit 1
fi
dd if="$user_disk" of="$image" bs=512 seek="$user_partition_start" conv=notrunc status=none

manifest=$(mktemp)
trap 'rm -f "$manifest"' EXIT
{
  echo "Raspberry Pi firmware release: $firmware_revision"
  echo "Kernel: kernel8.img"
  echo "Device tree: bcm2711-rpi-4-b.dtb"
  echo "User filesystem: FAT16 partition 2"
  echo "Target: Raspberry Pi 4 Model B (BCM2711)"
} >"$manifest"
mcopy -i "$drive" "$manifest" ::MANIFEST.txt
