# FlareOps

> Production-grade Cloudflare automation for GitHub Actions, CI/CD pipelines,
> and DevOps workflows.

[![CI](https://github.com/amitsdalal/FlareOps/actions/workflows/ci.yml/badge.svg)](https://github.com/amitsdalal/FlareOps/actions/workflows/ci.yml)
[![ShellCheck](https://github.com/amitsdalal/FlareOps/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/amitsdalal/FlareOps/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

FlareOps is an open-source toolkit of GitHub Actions and reusable workflows for
operating Cloudflare. It is designed to look and behave like a serious DevOps
toolkit — strict bash, real tests, structured logging, secret masking,
exponential backoff with jitter, multi-zone support, and per-zone partial
failure reporting.

The repository hosts one module per Cloudflare concern. Today the only module
is **purge-cache**; modules for DNS, Workers, WAF, Rulesets, R2, and zone
settings are on the roadmap and slot into the same shape.

---

## Modules

| Module                                | Status   | What it does                                     |
|---------------------------------------|----------|--------------------------------------------------|
| [`purge-cache`](./purge-cache/)       | Stable   | Cache purge: everything, files, hostnames, tags, prefixes; multi-zone. |
| `dns`                                 | Planned  | Idempotent DNS record reconciliation             |
| `workers`                             | Planned  | Workers script + binding deployment              |
| `waf`                                 | Planned  | Custom rule + managed-rule deployment            |
| `rulesets`                            | Planned  | Ruleset (cache-rules, redirect-rules) deployment |
| `r2`                                  | Planned  | R2 bucket sync / lifecycle management            |
| `zone-settings`                       | Planned  | Drift-free zone-setting reconciliation           |

---

## Quick start — purge-cache

```yaml
- name: Purge Cloudflare cache
  uses: amitsdalal/FlareOps/purge-cache@v1
  with:
    zone_id: ${{ secrets.CLOUDFLARE_ZONE_ID }}
    purge_type: everything
    bearer_token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

That's the simplest case. The action also handles per-file purges, cache-tag
purges, hostname purges, prefix purges, and multi-zone fan-out — see the
[purge-cache README](./purge-cache/README.md) for the full input/output
reference.

### Authentication

| Method                  | When to use                                              |
|-------------------------|----------------------------------------------------------|
| API Token (recommended) | Always preferred. Scope to `Zone:Cache Purge` only.      |
| Global API Key + Email  | Legacy / where tokens aren't yet available.              |

```yaml
# Token (recommended)
with:
  bearer_token: ${{ secrets.CLOUDFLARE_API_TOKEN }}

# Global API Key
with:
  email: ${{ secrets.CLOUDFLARE_EMAIL }}
  api_key: ${{ secrets.CLOUDFLARE_API_KEY }}
```

---

## Installation

FlareOps is consumed directly from this GitHub repository — there is nothing
to install. Reference the module path you need:

```yaml
uses: amitsdalal/FlareOps/<module>@<version>
```

Where `<version>` can be:

- `@v1` — floating major tag, automatic patch updates within `v1.x.x`
  (recommended for most projects).
- `@v1.0.0` — pinned to a specific release.
- `@<sha>` — pinned to an immutable commit SHA (recommended for compliance
  / regulated workloads).

---

## Versioning & release strategy

FlareOps follows [Semantic Versioning](https://semver.org/). All modules in
the repo share a version (a `v1.2.3` tag applies to every module). On every
release we also force-update a floating major tag (`v1`, `v2`, …) so
consumers using `@v1` automatically pick up the latest patch in that major
series. Prereleases (`v1.2.0-rc1`) do **not** move the major tag.

See [CHANGELOG.md](./CHANGELOG.md) for the human-readable release log.

---

## Why a toolkit, not single-purpose actions

A handful of single-purpose Cloudflare actions exist on the marketplace, but
they tend to:

- duplicate the same auth/retry/masking boilerplate per repo,
- diverge on input naming conventions,
- ship without proper tests, dry-run, or structured logs,
- and abandon as the Cloudflare API evolves.

FlareOps is structured so that the next module reuses the same conventions:
input names, output names, retry behavior, debug/dry-run flags, and CI
treatment. New modules cost a fraction of what they would as standalone
repos, and consumers learn the patterns once.

---

## Examples

The [`purge-cache/examples/`](./purge-cache/examples/) directory has
copy-pasteable workflows for:

- `purge-everything.yml` — full-zone purge after a deploy.
- `purge-files.yml` — granular per-URL purges from a list or workflow_dispatch input.
- `purge-tags.yml` — cache-tag purges driven by a CMS webhook (Enterprise).
- `purge-hostnames.yml` — hostname purges (Enterprise).
- `multi-zone.yml` — fan out across regions/brands; partial-failure aware.

### Reusable workflow

If your org wants to standardize cache-purges across many repos, wrap the
action in a [reusable workflow](https://docs.github.com/en/actions/using-workflows/reusing-workflows):

```yaml
# .github/workflows/cf-purge.yml in a central repo
on:
  workflow_call:
    inputs:
      zone_id: { required: true, type: string }
      purge_type: { required: false, type: string, default: everything }
      files: { required: false, type: string, default: '' }
    secrets:
      CLOUDFLARE_API_TOKEN: { required: true }

jobs:
  purge:
    runs-on: ubuntu-latest
    steps:
      - uses: amitsdalal/FlareOps/purge-cache@v1
        with:
          zone_id: ${{ inputs.zone_id }}
          purge_type: ${{ inputs.purge_type }}
          files: ${{ inputs.files }}
          bearer_token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

Then call it from any repo:

```yaml
jobs:
  purge:
    uses: my-org/cf-shared/.github/workflows/cf-purge.yml@v1
    with:
      zone_id: ${{ vars.CF_ZONE_ID }}
    secrets:
      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

### Self-hosted runners

The action only requires `bash 3.2+`, `curl`, and `jq` — all of which are
already on most container/VM images. If you're on a stripped-down image:

```yaml
- name: Install dependencies
  run: |
    if command -v apt-get >/dev/null; then sudo apt-get update && sudo apt-get install -y curl jq; fi
    if command -v apk     >/dev/null; then apk add --no-cache curl jq bash; fi
- uses: amitsdalal/FlareOps/purge-cache@v1
  with: { ... }
```

### Monorepos

In a monorepo where only a subset of paths affects a given Cloudflare zone,
combine the action with `dorny/paths-filter` to scope purges:

```yaml
jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      docs: ${{ steps.filter.outputs.docs }}
      app: ${{ steps.filter.outputs.app }}
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v3
        id: filter
        with:
          filters: |
            docs:
              - 'docs/**'
            app:
              - 'app/**'
  purge-docs:
    needs: changes
    if: needs.changes.outputs.docs == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: amitsdalal/FlareOps/purge-cache@v1
        with:
          zone_id: ${{ secrets.CF_ZONE_DOCS }}
          purge_type: prefixes
          prefixes: |
            docs.example.com/
          bearer_token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

---

## Security

We treat credential handling as the load-bearing requirement, not a
checkbox. See [SECURITY.md](./SECURITY.md) for our threat model and the
[purge-cache security section](./purge-cache/README.md#security) for
action-specific recommendations.

If you find a vulnerability, **do not open a public issue** — file a private
[GitHub Security Advisory](https://github.com/amitsdalal/FlareOps/security/advisories/new).

---

## Contributing

PRs welcome. Read [CONTRIBUTING.md](./CONTRIBUTING.md) first — it covers the
repo layout, test commands, coding style, and how to add a new module.

By participating you agree to the [Code of Conduct](./CODE_OF_CONDUCT.md).

---

## License

[MIT](./LICENSE)
