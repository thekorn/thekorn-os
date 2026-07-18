#!/usr/bin/env bash
set -euo pipefail

kernel=$1
config=$2
start4=$3
fixup4=$4
firmware_license=$5
firmware_revision=$6
image=$7
readonly image_size=$((64 * 1024 * 1024))
readonly partition_offset=$((1024 * 1024))

mkdir -p "$(dirname "$image")"
truncate -s 0 "$image"
truncate -s "$image_size" "$image"
export SOURCE_DATE_EPOCH=315532800
export TZ=UTC

python3 - "$image" <<'PY'
import struct
import sys

path = sys.argv[1]
start_lba = 2048
sector_count = (64 * 1024 * 1024 // 512) - start_lba
entry = bytes((0x80, 0xFE, 0xFF, 0xFF, 0x0C, 0xFE, 0xFF, 0xFF))
entry += struct.pack("<II", start_lba, sector_count)
mbr = bytearray(512)
mbr[446:462] = entry
mbr[510:512] = b"\x55\xaa"
with open(path, "r+b") as disk:
    disk.write(mbr)
PY

drive="$image@@$partition_offset"
mformat -i "$drive" -F -H 2048 -N 54484b4f -v THEKORN ::
mcopy -i "$drive" "$kernel" ::kernel8.img
mcopy -i "$drive" "$config" ::config.txt
mcopy -i "$drive" "$start4" ::start4.elf
mcopy -i "$drive" "$fixup4" ::fixup4.dat
mcopy -i "$drive" "$firmware_license" ::LICENCE.broadcom

manifest=$(mktemp)
trap 'rm -f "$manifest"' EXIT
{
  echo "Raspberry Pi firmware release: $firmware_revision"
  echo "Kernel: kernel8.img"
  echo "Target: Raspberry Pi 4 Model B (BCM2711)"
} >"$manifest"
mcopy -i "$drive" "$manifest" ::MANIFEST.txt
