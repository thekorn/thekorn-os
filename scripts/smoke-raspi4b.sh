#!/usr/bin/env bash
set -euo pipefail

kernel=${1:?usage: smoke-raspi4b.sh KERNEL_IMAGE CARD_IMAGE}
card=${2:?usage: smoke-raspi4b.sh KERNEL_IMAGE CARD_IMAGE}
temp_dir=$(mktemp -d)
working_card="$temp_dir/card.img"
dtb="$temp_dir/bcm2711-rpi-4-b.dtb"
transcript="$temp_dir/transcript"
qemu_log="$temp_dir/qemu.log"
trap 'rm -rf "$temp_dir"' EXIT

# QEMU does not emulate the VideoCore boot firmware, so direct boot uses the
# kernel and DTB stored in the generated card image. QEMU 11 also attaches
# if=sd to the legacy controller rather than BCM2711 EMMC2. The expected
# storage failure therefore marks the current emulator boundary; physical
# hardware remains the EMMC2 end-to-end gate.
cp "$card" "$working_card"
mcopy -i "$working_card@@1048576" ::bcm2711-rpi-4-b.dtb "$dtb"

set +e
timeout 8s qemu-system-aarch64 \
  -machine raspi4b \
  -smp 4 \
  -m 2G \
  -display none \
  -monitor none \
  -serial "file:$transcript" \
  -kernel "$kernel" \
  -dtb "$dtb" \
  -drive "file=$working_card,format=raw,if=sd" >"$qemu_log" 2>&1
status=$?
set -e

cat "$transcript"
cat "$qemu_log" >&2
if [[ $status -ne 124 ]]; then
  echo "smoke-raspi4b: expected QEMU to be stopped by the timeout, got status $status" >&2
  exit 1
fi

require_once() {
  local marker=$1
  local count
  count=$(grep -Ec "$marker" "$transcript" || true)
  if [[ $count -ne 1 ]]; then
    echo "smoke-raspi4b: expected marker exactly once, observed $count: $marker" >&2
    exit 1
  fi
}

marker_line() {
  grep -En -m1 "$1" "$transcript" | cut -d: -f1 || true
}

require_ordered() {
  local previous_line=0
  local marker
  local line
  for marker in "$@"; do
    require_once "$marker"
    line=$(marker_line "$marker")
    if (( line <= previous_line )); then
      echo "smoke-raspi4b: marker appeared out of order: $marker" >&2
      exit 1
    fi
    previous_line=$line
  done
}

boot_count=$(grep -Ec '^BOOT:START' "$transcript" || true)
if [[ $boot_count -ne 1 ]]; then
  echo "smoke-raspi4b: expected exactly one boot core, observed $boot_count" >&2
  exit 1
fi
if grep -Eq ':(UNHANDLED|PANIC)' "$transcript"; then
  echo "smoke-raspi4b: unexpected fatal marker found in serial transcript" >&2
  exit 1
fi

require_ordered \
  '^BOOT:CURRENT_EL=2' \
  '^BOOT:DTB=0x0*[1-9a-f][0-9a-f]*' \
  '^MEMORY:RAM_RANGES=0x0000000000000001' \
  '^MEMORY:OK' \
  '^INITRAMFS:FILES=0x0000000000000002' \
  '^INITRAMFS:OK' \
  '^STORAGE:FAILED'

if grep -Eq '^(MMU:ENABLED|BOOT:OK)' "$transcript"; then
  echo "smoke-raspi4b: execution crossed the expected QEMU EMMC2 boundary" >&2
  exit 1
fi
