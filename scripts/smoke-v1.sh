#!/usr/bin/env bash
set -uo pipefail

kernel=${1:?usage: smoke-v1.sh KERNEL}
transcript=$(mktemp)
qemu_log=$(mktemp)
trap 'rm -f "$transcript" "$qemu_log"' EXIT

set +e
timeout 5s qemu-system-aarch64 \
  -machine virt \
  -cpu cortex-a72 \
  -smp 1 \
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
  echo "smoke-v1: expected QEMU to be stopped by the timeout, got status $status" >&2
  exit 1
fi
if [[ $(grep -Ec '^V1:INIT' "$transcript" || true) -ne 1 ]]; then
  echo "smoke-v1: expected V1:INIT exactly once" >&2
  exit 1
fi
if grep -Eq ':(FAILED|UNHANDLED)|^BOOT:OK' "$transcript"; then
  echo "smoke-v1: unexpected v0 or failure marker found" >&2
  exit 1
fi
