#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: flash-rpi4-sd.sh DEVICE [IMAGE]" >&2
  echo "       IMAGE defaults to zig-out/thekorn-os-rpi4.img" >&2
  exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage

device=$1
image=${2:-zig-out/thekorn-os-rpi4.img}

if [[ ! -f "$image" ]]; then
  echo "flash-rpi4-sd: image not found: $image" >&2
  echo "flash-rpi4-sd: build it with: nix develop --command zig build" >&2
  exit 1
fi

case "$(uname -s)" in
  Darwin)
    device=${device/\/dev\/rdisk/\/dev\/disk}
    info=$(diskutil info "$device" 2>/dev/null) || {
      echo "flash-rpi4-sd: diskutil cannot inspect: $device" >&2
      exit 1
    }
    if ! grep -Eq '^[[:space:]]*Whole:[[:space:]]+Yes' <<<"$info"; then
      echo "flash-rpi4-sd: target must be a whole disk such as /dev/disk4, not a partition" >&2
      exit 1
    fi
    if ! grep -Eq '^[[:space:]]*Internal:[[:space:]]+No' <<<"$info" ||
       ! grep -Eq '^[[:space:]]*Removable Media:[[:space:]]+Removable' <<<"$info"; then
      echo "flash-rpi4-sd: refusing a disk that is not reported as removable and external: $device" >&2
      exit 1
    fi
    raw_device=${device/\/dev\/disk/\/dev\/rdisk}
    echo "$info" | awk -F: '/Device Node|Media Name|Disk Size|Removable Media/ { sub(/^[[:space:]]+/, "", $1); sub(/^[[:space:]]+/, "", $2); print "  " $1 ": " $2 }'
    ;;
  Linux)
    if [[ ! -b "$device" ]]; then
      echo "flash-rpi4-sd: target is not a block device: $device" >&2
      exit 1
    fi
    if [[ $(lsblk -dnro TYPE "$device") != disk ]]; then
      echo "flash-rpi4-sd: target must be a whole disk such as /dev/sdb, not a partition" >&2
      exit 1
    fi
    if [[ $(lsblk -dnro RM "$device") != 1 ]]; then
      echo "flash-rpi4-sd: refusing a device that is not reported as removable: $device" >&2
      exit 1
    fi
    raw_device=$device
    lsblk -dn -o NAME,MODEL,SIZE,TRAN,RM "$device"
    ;;
  *)
    echo "flash-rpi4-sd: only macOS and Linux are supported" >&2
    exit 1
    ;;
esac

image_size=$(wc -c <"$image" | tr -d ' ')
echo >&2
echo "WARNING: this will overwrite all data on $device with $image ($image_size bytes)." >&2
printf "Type 'flash %s' to continue: " "$device" >&2
IFS= read -r confirmation </dev/tty
if [[ $confirmation != "flash $device" ]]; then
  echo "flash-rpi4-sd: cancelled" >&2
  exit 1
fi

sudo -v

case "$(uname -s)" in
  Darwin)
    diskutil unmountDisk "$device"
    sudo dd if="$image" of="$raw_device" bs=4m
    sync
    echo "flash-rpi4-sd: verifying written image..." >&2
    sudo cmp -n "$image_size" "$image" "$raw_device"
    diskutil eject "$device"
    ;;
  Linux)
    while IFS= read -r node; do
      while IFS= read -r mountpoint; do
        [[ -n $mountpoint ]] && sudo umount "$mountpoint"
      done < <(findmnt -rn -S "$node" -o TARGET)
    done < <(lsblk -lnpo NAME "$device")
    sudo dd if="$image" of="$raw_device" bs=4M conv=fsync status=progress
    echo "flash-rpi4-sd: verifying written image..." >&2
    sudo cmp -n "$image_size" "$image" "$raw_device"
    sync
    ;;
esac

echo "flash-rpi4-sd: write and verification passed; the card is safe to remove" >&2
