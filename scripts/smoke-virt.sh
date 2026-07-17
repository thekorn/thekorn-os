#!/usr/bin/env bash
set -uo pipefail

kernel=${1:?usage: smoke-virt.sh KERNEL_ELF}
transcript=$(mktemp)
qemu_log=$(mktemp)
trap 'rm -f "$transcript" "$qemu_log"' EXIT

set +e
timeout 5s qemu-system-aarch64 \
  -machine virt \
  -cpu cortex-a72 \
  -smp 2 \
  -m 128M \
  -display none \
  -monitor none \
  -serial "file:$transcript" \
  -kernel "$kernel" >"$qemu_log" 2>&1
status=$?
set -e

cat "$transcript"
cat "$qemu_log" >&2
if [[ $status -ne 124 ]]; then
  echo "smoke-virt: expected QEMU to be stopped by the timeout, got status $status" >&2
  exit 1
fi
boot_count=$(awk '{ count += gsub(/BOOT:START/, "") } END { print count + 0 }' "$transcript")
if [[ $boot_count -ne 1 ]]; then
  echo "smoke-virt: expected exactly one boot core, observed $boot_count" >&2
  exit 1
fi

previous_line=0
for marker in \
  '^EXCEPTION:VECTOR=0x0000000000000004' \
  '^EXCEPTION:EC=0x000000000000003c' \
  '^EXCEPTION:BRK' \
  '^EXCEPTION:RETURNED' \
  '^BOOT:OK'
do
  line=$(grep -n -m1 "$marker" "$transcript" | cut -d: -f1 || true)
  if [[ -z $line ]]; then
    echo "smoke-virt: expected marker not found: $marker" >&2
    exit 1
  fi
  if (( line <= previous_line )); then
    echo "smoke-virt: marker appeared out of order: $marker" >&2
    exit 1
  fi
  previous_line=$line
done
