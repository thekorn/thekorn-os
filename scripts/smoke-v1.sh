#!/usr/bin/env bash
set -uo pipefail

kernel=${1:?usage: smoke-v1.sh KERNEL}
temp_dir=$(mktemp -d)
transcript="$temp_dir/transcript"
qemu_log="$temp_dir/qemu.log"
serial_socket="$temp_dir/serial.sock"
cleanup() {
  if [[ -n ${qemu_pid:-} ]] && kill -0 "$qemu_pid" 2>/dev/null; then
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
  fi
  rm -rf "$temp_dir"
}
trap cleanup EXIT

set +e
timeout 5s qemu-system-aarch64 \
  -machine virt \
  -cpu cortex-a72 \
  -smp 1 \
  -m 128M \
  -display none \
  -monitor none \
  -chardev "socket,id=serial,path=$serial_socket,server=on,wait=on" \
  -serial chardev:serial \
  -kernel "$kernel" >"$qemu_log" 2>&1 &
qemu_pid=$!

python3 - "$serial_socket" "$transcript" <<'PY'
import socket
import sys
import time

socket_path, transcript_path = sys.argv[1:]
connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
for _ in range(500):
    try:
        connection.connect(socket_path)
        break
    except (FileNotFoundError, ConnectionRefusedError):
        time.sleep(0.01)
else:
    raise SystemExit("smoke-v1: serial socket did not become ready")

connection.settimeout(0.1)
transcript = bytearray()
sent_burst = False
sent_overflow = False
deadline = time.monotonic() + 4.5

def send_paced(data, chunk_size, delay):
    for offset in range(0, len(data), chunk_size):
        connection.sendall(data[offset:offset + chunk_size])
        time.sleep(delay)

while time.monotonic() < deadline:
    try:
        chunk = connection.recv(4096)
        if not chunk:
            break
        transcript.extend(chunk)
    except TimeoutError:
        pass
    if not sent_burst and b"V1:RX_READY\r\n" in transcript:
        send_paced(bytes(range(256)) * 16, 16, 0.0005)
        sent_burst = True
    if not sent_overflow and b"V1:OVERFLOW_READY\r\n" in transcript:
        send_paced(bytes(range(256)) * 2 + bytes(range(64)), 8, 0.001)
        sent_overflow = True
    if b"V1:INIT\r\n" in transcript:
        break

with open(transcript_path, "wb") as output:
    output.write(transcript)
if not sent_burst or not sent_overflow:
    raise SystemExit("smoke-v1: input phase did not become ready")
PY
python_status=$?
wait "$qemu_pid"
status=$?
set -e

cat "$transcript" 2>/dev/null || true
cat "$qemu_log" >&2
if [[ $python_status -ne 0 ]]; then
  exit "$python_status"
fi
if [[ $status -ne 124 ]]; then
  echo "smoke-v1: expected QEMU to be stopped by the timeout, got status $status" >&2
  exit 1
fi
previous_line=0
for marker in 'V1:LIFECYCLE_OK' 'V1:SCHEDULER_OK' 'V1:RX_READY' 'V1:RX_BURST_OK' 'V1:OVERFLOW_READY' 'V1:TERMINAL_OK' 'V1:INIT'; do
  if [[ $(grep -Ec "^${marker}" "$transcript" || true) -ne 1 ]]; then
    echo "smoke-v1: expected ${marker} exactly once" >&2
    exit 1
  fi
  line=$(grep -En -m1 "^${marker}" "$transcript" | cut -d: -f1)
  if (( line <= previous_line )); then
    echo "smoke-v1: marker appeared out of order: ${marker}" >&2
    exit 1
  fi
  previous_line=$line
done
if grep -Eq ':(FAILED|UNHANDLED)|^BOOT:OK' "$transcript"; then
  echo "smoke-v1: unexpected v0 or failure marker found" >&2
  exit 1
fi
