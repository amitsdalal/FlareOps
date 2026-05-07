# Contributing to FlareOps

Thanks for considering a contribution! FlareOps is built to be a long-term,
multi-module home for Cloudflare-related DevOps tooling — clean architecture
and honest tests matter more than feature throughput.

## Quick start

```bash
git clone git@github.com:amitsdalal/FlareOps.git
cd FlareOps

# Run the smoke tests (no Cloudflare API calls — safe to run anywhere).
bash purge-cache/tests/basic-test.sh

# Lint the shell scripts.
shellcheck -s bash purge-cache/scripts/*.sh purge-cache/tests/*.sh
```

## Repository layout

```
flareops/
├── purge-cache/            # First module: Cloudflare cache purge
│   ├── action.yml          # Composite action metadata
│   ├── scripts/            # Bash implementation (purge, helpers, validate)
│   ├── examples/           # Drop-in workflow examples
│   └── tests/              # Hermetic unit/smoke tests
├── .github/workflows/      # CI, release, validate, shellcheck
└── ...                     # Top-level docs (README, LICENSE, SECURITY, ...)
```

Future modules (`dns`, `workers`, `r2`, `waf`, `rulesets`, `zone-settings`,
…) follow the same shape: an `action.yml`, a `scripts/` directory, an
`examples/` directory, a `tests/` directory, and a module-level `README.md`.
This consistency is intentional — it's what makes the repo browsable.

## Development environment

You'll need:

| Tool        | Why                                          | Install                                            |
|-------------|----------------------------------------------|----------------------------------------------------|
| `bash` 3.2+ | Action targets stock macOS bash             | preinstalled everywhere                            |
| `jq` 1.6+   | All JSON building/parsing                    | `apt-get install jq` / `brew install jq`           |
| `curl`      | HTTP                                         | preinstalled                                       |
| `shellcheck`| Required to land any shell change            | `apt-get install shellcheck` / `brew install shellcheck` |
| Python 3    | Schema/YAML lint scripts in CI               | preinstalled on most systems                       |

## Coding style

Shell scripts:

- `set -Eeuo pipefail` at the top of every executable script.
- Functions are namespaced `flareops::<name>` to avoid collisions when sourced
  from user code in tests.
- Quote everything. ShellCheck must pass with the configured options (see
  `.github/workflows/shellcheck.yml`).
- Comments explain **why**, not what. If you're describing what the next line
  does, delete the comment — name the variable better instead.
- Logging goes to stderr via `flareops::info` / `warn` / `error` / `debug`.
  Stdout is reserved.

Action metadata:

- Every input and output **must** have a `description`. CI enforces this.
- Required inputs that have a sensible default (e.g. `purge_type=everything`)
  should be `required: false` with the default set, not `required: true`.

## Adding a new module

1. Create `<module>/` with `action.yml`, `scripts/`, `examples/`, `tests/`,
   and a module `README.md`.
2. Reuse `helpers.sh` if you need logging, masking, or HTTP retry — copy the
   relevant functions or, ideally, factor them into a shared `_lib/` (we'll
   take that step at module #3).
3. Add at least one example workflow per major use case.
4. Add a `tests/basic-test.sh` exercising error paths and a dry-run mode.
5. Wire the module into `.github/workflows/ci.yml` (`shellcheck` scandir,
   smoke-test step).
6. Update root `README.md` and `CHANGELOG.md`.

## Tests

- Unit/smoke tests must NOT hit the Cloudflare API. Mock by exercising the
  validation paths and `dry_run: 'true'`.
- Integration tests (against a real zone) live outside this repo for now;
  if you need them, file an issue first so we can discuss the secrets story.

## Commits & PRs

- One logical change per PR. Mechanical refactors and behavior changes don't
  belong in the same diff.
- Commit messages: imperative subject, ≤72 cols, body explains the why.
- The PR template is enforced — fill it out.
- All status checks must pass before merge. Maintainers will squash-merge
  unless the PR is a release commit.

## Releasing (maintainers)

1. Update `CHANGELOG.md`: move `Unreleased` items into a new `vX.Y.Z` section.
2. Commit and push to `main`.
3. Tag: `git tag -a v1.2.3 -m "v1.2.3" && git push origin v1.2.3`.
4. The `release.yml` workflow handles GitHub Release creation and floats the
   `v1` major tag automatically.

## Code of Conduct

By participating you agree to abide by the [Code of Conduct](./CODE_OF_CONDUCT.md).

## Security issues

Don't open a public issue for security problems. See [SECURITY.md](./SECURITY.md).
