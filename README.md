# thekorn-os

`thekorn-os` is a small AArch64 learning operating system written in Zig. The
project is developed QEMU-first and will progressively port the same kernel to
the Raspberry Pi 4 (BCM2711).

The current implementation boots a freestanding kernel in writable QEMU
`virt` RAM at `0x40080000` and produces a separately linked Raspberry Pi image
for firmware loading at `0x80000`. It enters EL1h, installs a complete AArch64
exception vector table, initializes the QEMU PL011 UART, and reports boot and
exception facts over serial. See [the implementation plan](docs/plan.html) for
the roadmap and current phase status.

## Requirements

- Nix with flakes enabled
- A platform supported by `flake.nix` (`aarch64-darwin`, `aarch64-linux`, or
  `x86_64-linux`)

Zig, QEMU, and the other development tools are pinned by the Nix flake. Run Zig
commands through `nix develop`; do not rely on a host Zig installation.

## Build

```sh
nix develop --command zig build
```

The default build uses `ReleaseSmall` code generation while retaining symbols
and debug information in the ELF. It creates:

- `zig-out/bin/thekorn_os` — symbol-rich QEMU `virt` ELF linked at `0x40080000`
- `zig-out/kernel8.img` — raw Raspberry Pi kernel image linked at `0x80000`

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

The current Phase 2 QEMU checkpoint emits `BOOT:OK`, handles a deliberate
`brk` through the EL1h synchronous vector, reports ESR/ELR/SPSR/FAR, resumes
after the trapped instruction, and then halts. QEMU is terminated automatically
by the smoke-test timeout.

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
- Phase 2: in progress — QEMU EL1 exception handling is implemented; the
  Raspberry Pi 4 serial/exception hardware checkpoint remains
