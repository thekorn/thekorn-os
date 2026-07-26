# thekorn-os

`thekorn-os` is a small AArch64 learning operating system written in Zig. The
project is developed QEMU-first and will progressively port the same kernel to
the Raspberry Pi 4 (BCM2711).

The current implementation boots a freestanding kernel in writable QEMU
`virt` RAM at `0x40080000` and produces a separately linked, flashable
Raspberry Pi 4 image whose kernel loads at `0x80000`. Both targets enter EL1h,
install a complete AArch64 exception vector table, initialize their platform's
PL011 UART, and report boot and exception facts over serial. On QEMU, the
kernel also handles generic physical timer interrupts through a GICv2. See [the
implementation plan](docs/plan.html) for the roadmap and current phase status.
Both targets consume the firmware-provided device tree to discover RAM and
reserved ranges and initialize a 4 KiB bitmap physical-frame allocator.
The Phase 2 baseline is verified on a physical Pi 4 through the deliberate
exception return and final `BOOT:OK` marker. The current image builds a sparse
four-level identity map, enables the EL1 MMU and caches, then moves the kernel,
stack, and exception vectors into a protected `TTBR1_EL1` high-half mapping.
The low kernel alias is removed while device mappings remain available through
the active `TTBR0_EL1` root. QEMU verifies this transition and page-granular
W^X permissions; the updated image still needs a physical-board rerun.

The Phase 9 QEMU gate first loads two AArch64 ELF programs from a deterministic
embedded `newc` initramfs, then reloads them from a deterministic 4 MiB FAT16
image through a polling virtio-mmio block device. The kernel verifies that both
sources contain identical programs before starting three tasks on separate
kernel stacks. After the cooperative round-robin checkpoint, task 0 remains an
EL1 progress witness while tasks 1 and 2 become independently mapped Zig EL0
processes. Their ELF images use identical entry, data, heap, and stack virtual
addresses backed by separate memory and `TTBR0_EL1` roots. Each process uses
the versioned project ABI for `write`, `yield`, `exit`, and bounded memory
growth and is preempted during the same 1,000-tick timer run.

## Requirements

- Nix with flakes enabled
- A platform supported by `flake.nix` (`aarch64-darwin`, `aarch64-linux`, or
  `x86_64-linux`)

The Nix flake supplies the pinned compiler and host tools on
`aarch64-darwin`, `aarch64-linux`, and `x86_64-linux`. Zig fetches packaged
project inputs from `build.zig.zon` into `zig-pkg/`; the Pi image build also
downloads the matching board DTB from the pinned firmware tag and verifies its
SHA-256 digest before use.

## Build

```sh
nix develop --command zig build
```

The default build uses `ReleaseSmall` code generation while retaining symbols
and debug information in the ELF. It creates:

- `zig-out/bin/thekorn_os` — symbol-rich QEMU `virt` ELF linked at `0x40080000`
- `zig-out/users-fat16.img` — deterministic, read-only FAT16 image containing
  both Zig user programs for the QEMU virtio block device
- `zig-out/kernel8.img` — raw Raspberry Pi 4 kernel linked at `0x80000`
- `zig-out/thekorn-os-rpi4.img` — 64 MiB Pi-ready SD-card image with an MBR,
  FAT32 boot partition, the pinned Raspberry Pi firmware release, and the Pi
  kernel and BCM2711 device tree

Write `zig-out/thekorn-os-rpi4.img` to a spare microSD card with the **Use
custom** action in Raspberry Pi Imager or an equivalent image writer. This
overwrites the selected card. The build never selects or writes a device automatically.
Connect a 3.3 V serial adapter to GPIO 14/15 at 115200 8N1 before powering the
Pi. See the [Pi 4 hardware guide](docs/rpi4.html) for wiring and recovery steps.

An optimization mode can be selected explicitly, for example:

```sh
nix develop --command zig build -Doptimize=ReleaseSmall
```

## Run and verify

Lint the Zig source:

```sh
nix develop --command zig build lint
```

Run the kernel interactively on QEMU `virt`:

```sh
nix develop --command zig build run-virt
```

To show the serial output in the QEMU graphical virtual console instead, run:

```sh
nix develop --command zig build run-virt-gui
```

Switch to the serial console with Ctrl+Alt+2 (Ctrl+Option+2 on macOS).

Run the timeout-bounded serial smoke test:

```sh
nix develop --command zig build smoke-virt
```

Run host-native tests:

```sh
nix develop --command zig build test
```

Collect host-native test coverage with kcov:

```sh
nix develop --command zig build test -Dcoverage
```

The command prints overall and per-file coverage, including uncovered line
numbers, and writes an HTML report to `zig-out/coverage/index.html`. The Nix
shell provides kcov on Linux; on macOS, install it separately with
`brew install kcov`.

The custom test runner prints each test's status and duration, followed by a
summary and the five slowest tests. Set `TEST_VERBOSE=false` for compact output,
`TEST_FAIL_FIRST=true` to stop at the first failure, or `TEST_FILTER=<text>` to
run matching named tests. Tests named `tests:beforeAll` and `tests:afterAll` are
run as suite setup and teardown hooks.

The current QEMU checkpoint handles a deliberate `brk` through the EL1h
synchronous vector, reports ESR/ELR/SPSR/FAR, and resumes after the trapped
instruction. It disables FP/SIMD and proves an accidental floating-point
instruction traps visibly. Three tasks then make bounded progress on separate
16 KiB kernel stacks: first through 95 cooperative round-robin switches, then
through exactly 1,000 timer preemptions. Before enabling the MMU, the kernel
parses both ELF64 images from its embedded initramfs, discovers the modern QEMU
virtio-mmio block transport, and reads the same files through the read-only
FAT16/32 implementation. It emits `INITRAMFS:OK`, `VIRTIO_BLK:OK`, and `FAT:OK`
after validating this storage path. During the preemptive gate, both programs
run from the same virtual addresses, retain private data and heap identities,
preserve separate `SP_EL0` values across a yield, and receive timer preemption
while task 0 continues at EL1. Each process proves versioned syscall decoding,
checked user pointers, on-demand growth within a four-page heap window, clean
exit, and direct-access faults for UART and removed kernel mappings. The
checkpoint emits `PROCESS:ISOLATION_OK`, `USER:OK`, `SCHED:OK`, `PHASE9:OK`, and
`BOOT:OK` before QEMU is terminated by the smoke-test timeout.
Before exception testing, it parses the QEMU DTB, reserves firmware, DTB, and
kernel-owned memory, sweeps all allocatable frames, and emits `MEMORY:OK`.
It then enables a protected identity map, installs the kernel's high-half
`TTBR1_EL1` map, moves the PC, stack, and exception vectors high, and removes
the low kernel alias. It emits `MMU:OK` after observing the expected faults for
the removed alias, a text write, execution from rodata and data, and a write to
an unmapped address. The console, exception path, and timer continue through
the transition.

## Debug

Start QEMU paused with a GDB-compatible server on TCP port `1234`:

```sh
nix develop --command zig build debug-virt
```

Then connect an AArch64-capable debugger to `localhost:1234` and load
`zig-out/bin/thekorn_os`. The ELF retains symbols for `_start`, `kernelMain`,
and Zig source locations.

## Project status

- Phase 0: complete — freestanding build, linker layout, boot assembly, ELF,
  raw image, QEMU run/debug steps
- Phase 1: complete — QEMU PL011 serial output, boot facts, panic marker, and
  automated smoke test
- Phase 2: complete — EL1 exception handling and the Raspberry Pi 4 GPIO/PL011
  image are verified on physical hardware
- Phase 3: complete — QEMU GICv2 routing, generic physical timer interrupts,
  monotonic tick accounting, and the 1,000-tick smoke-test gate
- Phase 4: complete — DTB RAM/reservation discovery, 4 KiB bitmap frame
  allocation, host tests, and the QEMU allocation-sweep gate
- Phase 5: in progress — the protected identity map, high-half `TTBR1_EL1`
  transition, low-alias removal, W^X fault probes, and QEMU gate are
  implemented; physical-board validation remains
- Phase 6: complete on QEMU — three separate kernel stacks, cooperative yields,
  exception-return context switching, FP/SIMD trapping, and timer preemption
  are enforced by the smoke gate
- Phase 7: complete on QEMU — task 2 enters EL0, uses the versioned
  `write`/`yield`/`exit`/bounded-growth ABI, is timer-preempted, and cannot
  directly access UART or kernel memory
- Phase 8: complete on QEMU — two embedded Zig ELF processes run at identical
  virtual addresses with independent backing, `TTBR0_EL1` roots, user stacks,
  data, and bounded heaps; physical-board validation remains deferred
- Phase 9: complete on QEMU — deterministic initramfs and FAT16 images, a
  polling modern virtio-mmio block driver, a read-only block-device contract,
  and host-tested FAT16/32 parsing feed the isolated two-process smoke gate
