#!/usr/bin/env bash
set -uo pipefail

kernel=${1:?usage: smoke-virt.sh KERNEL_ELF}
transcript=$(mktemp)
trap 'rm -f "$transcript"' EXIT

set +e
timeout 5s qemu-system-aarch64 \
  -machine virt \
  -cpu cortex-a72 \
  -smp 1 \
  -m 128M \
  -nographic \
  -kernel "$kernel" >"$transcript" 2>&1
status=$?
set -e

cat "$transcript"
if ! grep -q '^BOOT:OK' "$transcript"; then
  echo "smoke-virt: BOOT:OK marker not found" >&2
  exit "${status:-1}"
fi
if ! grep -q '^PANIC:phase 1 deliberate panic' "$transcript"; then
  echo "smoke-virt: deliberate panic marker not found" >&2
  exit 1
fi
