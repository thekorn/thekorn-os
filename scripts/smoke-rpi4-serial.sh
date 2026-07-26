#!/usr/bin/env bash
set -euo pipefail

device=${1:?usage: smoke-rpi4-serial.sh SERIAL_DEVICE [TRANSCRIPT] [TIMEOUT_SECONDS]}
transcript=${2:-zig-out/rpi4-serial.log}
timeout_seconds=${3:-120}

if [[ ! -c "$device" ]]; then
  echo "smoke-rpi4-serial: not a character device: $device" >&2
  exit 1
fi
if [[ ! $timeout_seconds =~ ^[1-9][0-9]*$ ]]; then
  echo "smoke-rpi4-serial: timeout must be a positive whole number of seconds" >&2
  exit 1
fi
mkdir -p "$(dirname "$transcript")"

echo "smoke-rpi4-serial: listening on $device at 115200 8N1" >&2
echo "smoke-rpi4-serial: power-cycle the Pi now; flashing and power control remain manual" >&2

set +e
python3 - "$device" "$transcript" "$timeout_seconds" <<'PY'
import os
import select
import sys
import termios
import time

device, transcript, timeout_text = sys.argv[1:]
timeout = int(timeout_text)
fd = os.open(device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
original = termios.tcgetattr(fd)
configured = termios.tcgetattr(fd)
configured[0] = 0
configured[1] = 0
configured[2] &= ~(termios.PARENB | termios.CSTOPB | termios.CSIZE)
if hasattr(termios, "CRTSCTS"):
    configured[2] &= ~termios.CRTSCTS
configured[2] |= termios.CS8 | termios.CREAD | termios.CLOCAL
configured[3] = 0
configured[4] = termios.B115200
configured[5] = termios.B115200
configured[6][termios.VMIN] = 0
configured[6][termios.VTIME] = 0
termios.tcsetattr(fd, termios.TCSANOW, configured)
termios.tcflush(fd, termios.TCIFLUSH)

deadline = time.monotonic() + timeout
captured = bytearray()
status = 124
try:
    with open(transcript, "wb") as output:
        while time.monotonic() < deadline:
            readable, _, _ = select.select([fd], [], [], min(0.25, deadline - time.monotonic()))
            if not readable:
                continue
            try:
                chunk = os.read(fd, 4096)
            except BlockingIOError:
                continue
            if not chunk:
                continue
            output.write(chunk)
            output.flush()
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
            captured.extend(chunk)
            normalized = captured.replace(b"\r", b"")
            if b"\nBOOT:OK\n" in b"\n" + normalized:
                status = 0
                break
            if any(marker in normalized for marker in (b":FAILED", b":UNHANDLED", b"PANIC:")):
                status = 2
                break
finally:
    termios.tcsetattr(fd, termios.TCSANOW, original)
    os.close(fd)

raise SystemExit(status)
PY
capture_status=$?
set -e

if [[ $capture_status -ne 0 ]]; then
  if [[ $capture_status -eq 124 ]]; then
    echo "smoke-rpi4-serial: timed out after $timeout_seconds seconds" >&2
  else
    echo "smoke-rpi4-serial: capture stopped on a fatal kernel marker" >&2
  fi
  echo "smoke-rpi4-serial: transcript saved to $transcript" >&2
  exit 1
fi

require_once() {
  local marker=$1
  local count
  count=$(grep -Ec "$marker" "$transcript" || true)
  if [[ $count -ne 1 ]]; then
    echo "smoke-rpi4-serial: expected marker exactly once, observed $count: $marker" >&2
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
      echo "smoke-rpi4-serial: marker appeared out of order: $marker" >&2
      exit 1
    fi
    previous_line=$line
  done
}

if grep -Eq ':(FAILED|UNHANDLED)|PANIC:' "$transcript"; then
  echo "smoke-rpi4-serial: fatal marker found in serial transcript" >&2
  exit 1
fi

require_ordered \
  '^BOOT:START' \
  '^BOOT:CURRENT_EL=2' \
  '^BOOT:DTB=0x0*[1-9a-f][0-9a-f]*' \
  '^MEMORY:RAM_RANGES=0x0*[1-9a-f][0-9a-f]*' \
  '^MEMORY:OK' \
  '^INITRAMFS:FILES=0x0000000000000002' \
  '^INITRAMFS:OK' \
  '^BLOCK:SECTORS=0x0000000000002000' \
  '^EMMC2:OK' \
  '^FAT:FILES=0x0000000000000002' \
  '^FAT:IMAGES_MATCH' \
  '^FAT:OK' \
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
  echo "smoke-rpi4-serial: expected one committed heap page in each process, observed $heap_page_markers markers" >&2
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
  '^PHASE9:OK' \
  '^BOOT:OK'

echo "smoke-rpi4-serial: Phase 10 hardware gate passed" >&2
echo "smoke-rpi4-serial: transcript saved to $transcript" >&2
