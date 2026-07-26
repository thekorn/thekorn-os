#!/usr/bin/env bash
set -euo pipefail

kernel=$1
disk=$2
output=$(mktemp)
trap 'rm -f "$output"' EXIT

timeout --signal=TERM 30s qemu-system-aarch64 \
  -machine virt -cpu cortex-a72 -smp 1 -m 128M \
  -display none -monitor none -serial stdio \
  -global virtio-mmio.force-legacy=false -kernel "$kernel" \
  -drive "file=$disk,format=raw,if=none,readonly=on,id=users" \
  -device virtio-blk-device,drive=users -device virtio-gpu-device \
  >"$output" 2>&1 || status=$?

if [[ ${status:-0} -ne 0 && ${status:-0} -ne 124 ]]; then
  cat "$output"
  exit "$status"
fi
if [[ ${status:-0} -ne 124 ]]; then
  cat "$output"
  echo "graphics smoke: expected timeout status 124, got ${status:-0}" >&2
  exit 1
fi
if grep -Eq ':(FAILED|UNHANDLED)' "$output"; then
  cat "$output"
  echo 'graphics smoke: failure marker found' >&2
  exit 1
fi
init_line=$(grep -n -m1 '^GRAPHICS:INIT' "$output" | cut -d: -f1 || true)
ok_line=$(grep -n -m1 '^GRAPHICS:QEMU_OK' "$output" | cut -d: -f1 || true)
boot_line=$(grep -n -m1 '^BOOT:OK' "$output" | cut -d: -f1 || true)
terminal_count=$(grep -Ec '^GRAPHICS:(QEMU_OK|FAILED)' "$output" || true)
if [[ -z "$init_line" || -z "$ok_line" || -z "$boot_line" ||
      "$init_line" -ge "$ok_line" || "$ok_line" -ge "$boot_line" ||
      "$terminal_count" -ne 1 ]]; then
  cat "$output"
  echo 'graphics smoke: ordered markers missing' >&2
  exit 1
fi
echo 'graphics smoke: GRAPHICS:INIT then GRAPHICS:QEMU_OK'
