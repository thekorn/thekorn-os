# Development Workflow

This is a Zig project whose development environment is managed with devenv.

Run all Zig commands inside devenv. Prefer the one-shot form:

```sh
devenv shell -- zig build
devenv shell -- zig build run
devenv shell -- zig build lint
devenv shell -- zig build test
```

Do not invoke `zig` directly from the host environment. When adding or changing
verification commands, keep them reproducible through `devenv shell --`.

Before every commit, run the spell check, linter, all host-runnable smoke tests,
and unit tests:

```sh
devenv shell -- codebook-lsp lint --unique -s .
devenv shell -- zig build lint
devenv shell -- zig build smoke-virt
devenv shell -- zig build smoke-raspi4b
devenv shell -- zig build smoke-virt-graphics
devenv shell -- zig build test
```

The physical `scripts/smoke-rpi4-serial.sh` gate requires a connected Pi and
serial adapter, so run it when explicitly performing hardware verification
rather than before every commit.

Keep `README.md` current whenever build commands, run/debug workflows, generated
artifacts, requirements, or implementation phase status change.

To write the generated Raspberry Pi 4 image to a removable SD card, use:

```sh
devenv shell -- bash scripts/flash-rpi4-sd.sh DEVICE
```

This is a destructive hardware operation. Never run the flashing script unless
the user explicitly asks you to write a card and confirms the target device.

For the project plan see [the plan](docs/plan.html)
