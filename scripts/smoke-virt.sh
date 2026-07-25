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

require_once() {
  local marker=$1
  local count
  count=$(grep -Ec "$marker" "$transcript" || true)
  if [[ $count -ne 1 ]]; then
    echo "smoke-virt: expected marker exactly once, observed $count: $marker" >&2
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
      echo "smoke-virt: marker appeared out of order: $marker" >&2
      exit 1
    fi
    previous_line=$line
  done
}

if grep -Eq ':(FAILED|UNHANDLED)' "$transcript"; then
  echo "smoke-virt: failure marker found in serial transcript" >&2
  exit 1
fi

require_ordered \
  '^MEMORY:OK' \
  '^MMU:ENABLED' \
  '^MMU:HIGH_PC=0xffff' \
  '^MMU:HIGH_SP=0xffff' \
  '^MMU:HIGH_VBAR=0xffff' \
  '^ELF:LOADED' \
  '^ELF:IMAGES=0x0000000000000002' \
  '^PROCESS:VIRTUAL_ENTRY=0x0000000000400000' \
  '^PROCESS:VIRTUAL_DATA=0x0000000000420000' \
  '^PROCESS:DISTINCT_ROOTS' \
  '^PROCESS:DISTINCT_BACKING' \
  '^PROCESS:ADDRESS_SPACES_OK' \
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
  '^USER:ABI_VERSION=0x0000000000000001' \
  '^SCHED:START' \
  '^SCHED:COOPERATIVE_SWITCHES=0x000000000000005f' \
  '^SCHED:COOPERATIVE_OK'

for process_id in 1 2; do
  hex_id="0x000000000000000${process_id}"
  require_ordered \
    "^PROCESS:ENTER_EL0=${hex_id}" \
    "^PROCESS${process_id}:HELLO" \
    "^PROCESS:BAD_POINTER_REJECTED=${hex_id}" \
    "^PROCESS:BAD_SYSCALL_REJECTED=${hex_id}" \
    "^PROCESS:GROW=${hex_id}" \
    "^PROCESS:HEAP_LIMIT_ENFORCED=${hex_id}" \
    "^PROCESS:YIELD=${hex_id}" \
    "^PROCESS${process_id}:STACK_OK" \
    "^PROCESS:UART_DENIED=${hex_id}" \
    "^PROCESS:KERNEL_DENIED=${hex_id}" \
    "^PROCESS${process_id}:OK" \
    "^PROCESS:EXIT=${hex_id}"
  require_once "^PROCESS${process_id}:PREEMPTIONS=0x0*[1-9a-f][0-9a-f]*"
done

heap_page_markers=$(grep -Ec '^PROCESS:HEAP_PAGES=0x0000000000000001' "$transcript" || true)
if [[ $heap_page_markers -ne 2 ]]; then
  echo "smoke-virt: expected one committed heap page in each process, observed $heap_page_markers markers" >&2
  exit 1
fi

require_ordered \
  '^TIMER:TICKS=0x00000000000003e8' \
  '^TIMER:MONOTONIC' \
  '^IRQ:OK' \
  '^SCHED:TASK0_PROGRESS=0x0000000000002710' \
  '^SCHED:TASK1_PROGRESS=0x0000000000002710' \
  '^SCHED:TASK2_PROGRESS=0x0000000000002710' \
  '^PROCESS1:PREEMPTIONS=0x0*[1-9a-f][0-9a-f]*' \
  '^PROCESS2:PREEMPTIONS=0x0*[1-9a-f][0-9a-f]*' \
  '^SCHED:PREEMPTIONS=0x00000000000003e8' \
  '^SCHED:PREEMPTIVE_OK' \
  '^PROCESS:ISOLATION_OK' \
  '^ELF:OK' \
  '^USER:SYSCALLS_OK' \
  '^USER:OK' \
  '^SCHED:OK' \
  '^BOOT:OK'
