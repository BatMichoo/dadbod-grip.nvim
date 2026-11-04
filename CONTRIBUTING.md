# Contributing to Dadbod Grip

Dadbod Grip welcomes focused bug fixes, documentation corrections, and features that can be exercised against a real database client.

## Prepare a checkout

Install the repository tools pinned by Mise:

```sh
mise install
```

Install LuaCheck if it is not already available:

```sh
luarocks --lua-version=5.1 --local install luacheck
```

The deterministic suite requires Neovim 0.10 or newer and `sqlite3`. Tests for a specific adapter also require that adapter's command-line client.

Use a short, purpose-based branch name such as `fix/mysql-null-values` or `docs/connection-setup`. Do not add an agent or tool prefix.

## Run the local gates

Run the focused spec while developing, then run the local CI gates:

```sh
just spec data
just check
```

Use `NVIM=/path/to/nvim just test` for a specific supported Neovim. For an
already-running database, set `GRIP_TEST_LIVE_URL` and run `just test-live
postgresql-16`, `mysql-8.4`, `mariadb-11.8`, `sqlserver-2025`, or `sqlite`.

`tests/spec/neo_tree_spec.lua` drives a real neo-tree.nvim. It looks for
`neo-tree.nvim`, `nui.nvim` and `plenary.nvim` side by side in
`GRIP_NEO_TREE_DIR` (default: lazy.nvim's `~/.local/share/nvim/lazy`) and
skips when they are missing; CI pins all three.

Run `just e2e-visual` when a change can affect window creation, sidebar sizing, the query pad, grid rendering, or resize behavior. It opens a real tmux-backed Neovim UI at 100, 80, and 160 columns.

Live PostgreSQL, MySQL, MariaDB, and SQL Server jobs run in GitHub Actions.

### Live databases in Docker

`docker/compose.yaml` runs the same database versions as CI, seeded from
`tests/seed_*.sql`, plus a runner image with Neovim, every database client, and
DuckDB. Only Docker with the Compose plugin is needed on the host (x86_64; the
SQL Server image has no arm64 build).

```sh
just test-docker mysql-8.4        # or postgresql-16, mariadb-11.8, sqlserver-2025
just test-docker-all              # every database
just db-up postgres               # start and seed databases without running tests
just db-down                      # stop them and discard their data
```

Without `just`, run `docker/test-live.sh mysql-8.4` (or `all`) directly. Data
lives in tmpfs, so `just db-down` followed by `just db-up` starts again from the
seed files. Starting SQL Server accepts its developer edition EULA, as CI does.

The databases also listen on localhost for trying grip by hand:

| Database | URL |
|---|---|
| PostgreSQL 16 | `postgresql://postgres:grip@127.0.0.1:15432/grip_test` |
| MySQL 8.4 | `mysql://root:grip@127.0.0.1:13306/grip_test` |
| MariaDB 11.8 | `mariadb://root:grip@127.0.0.1:13307/grip_test` |
| SQL Server 2025 | `sqlserver://sa:Grip-ci-2025!@127.0.0.1:11433/grip_test?encrypt=optional&trust_server_certificate=true` |

## Scan for secrets

Enable the repository's optional native Git hook:

```sh
git config core.hooksPath .githooks
```

Run the complete redacted history scan at any time:

```sh
mise exec -- gitleaks git --redact --verbose
```

Never commit a credential, a Gitleaks report, or a broad allowlist. If a real secret is found, revoke or rotate it before discussing history cleanup.

## Prepare a pull request

Keep each pull request focused on one behavior. Add the smallest regression that fails without the change, and use existing helpers before introducing another abstraction or dependency.

Update `CHANGELOG.md` under `Unreleased` when user-visible behavior changes. Update `:help dadbod-grip` when a command, keymap, option, or workflow changes; the README should remain an onboarding guide rather than a second reference manual.

Describe the problem, the chosen fix, and the commands you ran. Do not include database URLs, credentials, private schema text, or production output in the pull request.

Report suspected vulnerabilities through the private channel in [SECURITY.md](SECURITY.md), not through a public issue.
