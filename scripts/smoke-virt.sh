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
  '^MEMORY:OK' \
  '^MMU:ENABLED' \
  '^MMU:HIGH_PC=0xffff' \
  '^MMU:HIGH_SP=0xffff' \
  '^MMU:HIGH_VBAR=0xffff' \
  '^MMU:HIGH_HALF' \
  '^MMU:LOW_ALIAS_UNMAPPED' \
  '^MMU:TEXT_RO' \
  '^MMU:RODATA_NX' \
  '^MMU:DATA_NX' \
  '^MMU:UNMAPPED' \
  '^MMU:OK' \
  '^EXCEPTION:VECTOR=0x0000000000000004' \
  '^EXCEPTION:EC=0x000000000000003c' \
  '^EXCEPTION:BRK' \
  '^EXCEPTION:RETURNED' \
  '^FP:TRAP' \
  '^SCHED:START' \
  '^SCHED:COOPERATIVE_SWITCHES=0x000000000000005f' \
  '^SCHED:COOPERATIVE_OK' \
  '^TIMER:TICKS=0x00000000000003e8' \
  '^TIMER:MONOTONIC' \
  '^IRQ:OK' \
  '^SCHED:TASK0_PROGRESS=0x0000000000002710' \
  '^SCHED:TASK1_PROGRESS=0x0000000000002710' \
  '^SCHED:TASK2_PROGRESS=0x0000000000002710' \
  '^SCHED:PREEMPTIONS=0x00000000000003e8' \
  '^SCHED:PREEMPTIVE_OK' \
  '^SCHED:OK' \
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
