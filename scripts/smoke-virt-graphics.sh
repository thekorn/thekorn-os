#!/usr/bin/env bash
set -euo pipefail

kernel=$1
disk=$2
capture=$3
temporary=$(mktemp -d)
serial="$temporary/serial.log"
qemu_log="$temporary/qemu.log"
qmp="$temporary/qmp.sock"
cleanup() {
  if [[ -n ${qemu_pid:-} ]] && kill -0 "$qemu_pid" 2>/dev/null; then
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
  fi
  rm -rf "$temporary"
}
trap cleanup EXIT

timeout --signal=TERM 30s qemu-system-aarch64 \
  -machine virt -cpu cortex-a72 -smp 1 -m 128M \
  -display none -monitor none -serial "file:$serial" \
  -qmp "unix:$qmp,server=on,wait=off" \
  -global virtio-mmio.force-legacy=false -kernel "$kernel" \
  -drive "file=$disk,format=raw,if=none,readonly=on,id=users" \
  -device virtio-blk-device,drive=users -device virtio-gpu-device \
  >"$qemu_log" 2>&1 &
qemu_pid=$!

for _ in $(seq 1 300); do
  if grep -q '^BOOT:OK' "$serial" 2>/dev/null; then break; fi
  if ! kill -0 "$qemu_pid" 2>/dev/null; then break; fi
  sleep 0.1
done

cat "$serial"
cat "$qemu_log" >&2
if grep -Eq ':(FAILED|UNHANDLED)' "$serial"; then
  echo 'graphics smoke: failure marker found' >&2
  exit 1
fi
init_line=$(grep -n -m1 '^GRAPHICS:INIT' "$serial" | cut -d: -f1 || true)
ok_line=$(grep -n -m1 '^GRAPHICS:QEMU_OK' "$serial" | cut -d: -f1 || true)
boot_line=$(grep -n -m1 '^BOOT:OK' "$serial" | cut -d: -f1 || true)
terminal_count=$(grep -Ec '^GRAPHICS:(QEMU_OK|FAILED)' "$serial" || true)
if [[ -z "$init_line" || -z "$ok_line" || -z "$boot_line" ||
      "$init_line" -ge "$ok_line" || "$ok_line" -ge "$boot_line" ||
      "$terminal_count" -ne 1 ]]; then
  echo 'graphics smoke: ordered markers missing' >&2
  exit 1
fi

python3 - "$qmp" "$capture" <<'PY'
import json
import socket
import sys
import time

socket_path, capture_path = sys.argv[1:]
deadline = time.monotonic() + 5
while True:
    try:
        connection = socket.socket(socket.AF_UNIX)
        connection.connect(socket_path)
        break
    except (FileNotFoundError, ConnectionRefusedError):
        if time.monotonic() >= deadline:
            raise
        time.sleep(0.05)

stream = connection.makefile("rwb", buffering=0)

def receive():
    while True:
        message = json.loads(stream.readline())
        if "event" not in message:
            return message

def execute(command, arguments=None):
    request = {"execute": command}
    if arguments is not None:
        request["arguments"] = arguments
    stream.write(json.dumps(request).encode() + b"\r\n")
    response = receive()
    if "error" in response:
        raise RuntimeError(response["error"])

receive()
execute("qmp_capabilities")
execute("screendump", {"filename": capture_path})
execute("quit")
PY

wait "$qemu_pid"

python3 - "$capture" <<'PY'
import sys

path = sys.argv[1]
with open(path, "rb") as image:
    if image.readline().strip() != b"P6":
        raise SystemExit("graphics smoke: screenshot is not a binary PPM")
    line = image.readline()
    while line.startswith(b"#"):
        line = image.readline()
    width, height = map(int, line.split())
    maximum = int(image.readline())
    pixels = image.read()

if (width, height, maximum) != (800, 600, 255):
    raise SystemExit(f"graphics smoke: unexpected PPM geometry {(width, height, maximum)}")
if len(pixels) != width * height * 3:
    raise SystemExit("graphics smoke: truncated PPM pixels")

def pixel(x, y):
    offset = (y * width + x) * 3
    return tuple(pixels[offset:offset + 3])

expected = {
    (0, 0): (0x12, 0x18, 0x20),
    (100, 200): (0x24, 0x34, 0x48),
    (100, 125): (0xE0, 0x9F, 0x3E),
    (113, 160): (0xF4, 0xF1, 0xE8),
}
for point, color in expected.items():
    actual = pixel(*point)
    if actual != color:
        raise SystemExit(f"graphics smoke: pixel {point} is {actual}, expected {color}")
PY

echo "graphics smoke: verified 800x600 visible pixels in $capture"

fallback_serial="$temporary/fallback-serial.log"
fallback_log="$temporary/fallback-qemu.log"
set +e
timeout --signal=TERM 5s qemu-system-aarch64 \
  -machine virt -cpu cortex-a72 -smp 1 -m 128M \
  -display none -monitor none -serial "file:$fallback_serial" \
  -global virtio-mmio.force-legacy=false -kernel "$kernel" \
  -drive "file=$disk,format=raw,if=none,readonly=on,id=users" \
  -device virtio-blk-device,drive=users >"$fallback_log" 2>&1
fallback_status=$?
set -e

cat "$fallback_serial"
cat "$fallback_log" >&2
if [[ $fallback_status -ne 124 ]]; then
  echo "graphics smoke: expected fallback timeout status 124, got $fallback_status" >&2
  exit 1
fi
if grep -Eq ':(UNHANDLED|PANIC)' "$fallback_serial"; then
  echo 'graphics smoke: fatal fallback marker found' >&2
  exit 1
fi
fallback_init=$(grep -n -m1 '^GRAPHICS:INIT' "$fallback_serial" | cut -d: -f1 || true)
fallback_failed=$(grep -n -m1 '^GRAPHICS:FAILED' "$fallback_serial" | cut -d: -f1 || true)
fallback_boot=$(grep -n -m1 '^BOOT:OK' "$fallback_serial" | cut -d: -f1 || true)
if [[ -z "$fallback_init" || -z "$fallback_failed" || -z "$fallback_boot" ||
      "$fallback_init" -ge "$fallback_failed" || "$fallback_failed" -ge "$fallback_boot" ]] ||
   grep -q '^GRAPHICS:QEMU_OK' "$fallback_serial"; then
  echo 'graphics smoke: unavailable display did not fall back cleanly' >&2
  exit 1
fi
echo 'graphics smoke: unavailable display reported GRAPHICS:FAILED and boot continued'
