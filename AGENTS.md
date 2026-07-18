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

Before every commit, run the spell check, linter, smoke test, and unit tests:

```sh
nix develop --command codebook-lsp lint --unique -s .
nix develop --command zig build lint
nix develop --command zig build smoke-virt
nix develop --command zig build test
```

Keep `README.md` current whenever build commands, run/debug workflows, generated
artifacts, requirements, or implementation phase status change.

For the project plan see [the plan](docs/plan.html)
