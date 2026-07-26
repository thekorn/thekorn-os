# Development Workflow

This is a Zig project whose development environment is managed with Nix flakes.

Run all Zig commands inside the Nix development shell. Prefer the one-shot form:

```sh
nix develop --command zig build
nix develop --command zig build run
nix develop --command zig build lint
nix develop --command zig build test
```

Do not invoke `zig` directly from the host environment. When adding or changing
verification commands, keep them reproducible through `nix develop --command`.

Before every commit, run the spell check, linter, all host-runnable smoke tests,
and unit tests:

```sh
nix develop --command codebook-lsp lint --unique -s .
nix develop --command zig build lint
nix develop --command zig build smoke-virt
nix develop --command zig build smoke-raspi4b
nix develop --command zig build smoke-virt-graphics
nix develop --command zig build test
```

The physical `scripts/smoke-rpi4-serial.sh` gate requires a connected Pi and
serial adapter, so run it when explicitly performing hardware verification
rather than before every commit.

Keep `README.md` current whenever build commands, run/debug workflows, generated
artifacts, requirements, or implementation phase status change.

To write the generated Raspberry Pi 4 image to a removable SD card, use:

```sh
nix develop --command bash scripts/flash-rpi4-sd.sh DEVICE
```

This is a destructive hardware operation. Never run the flashing script unless
the user explicitly asks you to write a card and confirms the target device.

For the project plan see [the plan](docs/plan.html)
