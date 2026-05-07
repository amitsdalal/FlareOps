# Security Policy

## Reporting a Vulnerability

If you believe you've found a security issue in FlareOps — for example, a way
to leak Cloudflare credentials from logs, a command-injection path, or an
authentication-bypass — **please do not open a public GitHub issue**.

Use one of the following private channels:

1. **GitHub Security Advisories (preferred)** — open a private advisory at
   <https://github.com/amitsdalal/FlareOps/security/advisories/new>. This
   lets us discuss, fix, and coordinate disclosure without exposing the issue
   to attackers.
2. Email: open a GitHub Security Advisory; we'll surface a contact address
   from there if needed.

We aim to acknowledge reports within 72 hours and to ship a fix or mitigation
within 14 days of triage for high-severity issues. We'll credit reporters in
release notes unless you'd prefer to remain anonymous.

## Supported Versions

| Version  | Supported |
|----------|-----------|
| `v1.x`   | Yes       |
| `< v1.0` | No        |

Older majors stop receiving security fixes once a new major has been out for
six months. Pin to the floating major tag (e.g. `@v1`) to receive patches
automatically.

## Threat Model

FlareOps actions run inside GitHub Actions runners and call the Cloudflare
API. The trust boundaries we worry about, in priority order:

1. **Workflow logs.** Cloudflare API tokens, Global API Keys, and email
   addresses must never appear in plaintext in `runs/<id>` logs. The action
   emits `::add-mask::` workflow commands for every credential at startup.
2. **Process arguments.** On shared runners, `ps(1)` can disclose command
   lines. We pass auth via headers (not URL params, not `--user`), and bodies
   via stdin, so credentials are never in `argv`.
3. **Tempfiles.** Response bodies and headers go to `mktemp(1)` files which
   are cleaned up on exit (including on error, via a `trap`).
4. **Compromised dependencies.** The action depends only on `bash`, `curl`,
   and `jq` from the runner image — no third-party packages are installed at
   runtime. CI workflows pin third-party actions by major version; consumers
   who want stricter guarantees should pin by SHA.
5. **Replayed requests.** Cloudflare's purge API is idempotent for our use
   cases, so retry-on-transient-failure is safe.

We do **not** consider the following part of FlareOps' threat model — they're
the workflow author's responsibility:

- Storing the Cloudflare token securely (use repository or environment
  secrets, never commit them).
- Restricting who can dispatch the workflow (use environments + required
  reviewers for production zones).
- Configuring the API token with least-privilege scope (see the
  [purge-cache README](./purge-cache/README.md#cloudflare-permissions)).

## Hardening Recommendations

- **Use API Tokens, not Global API Keys.** The Global API Key has full
  account access and cannot be scoped. Tokens can be limited to
  `Zone:Cache Purge` on a single zone.
- **Pin the action by SHA** for production:
  `uses: amitsdalal/FlareOps/purge-cache@<sha>`. Floating tags are
  convenient but mutable.
- **Use GitHub Environments** for production zones — set the secret on the
  environment, not the repo, and require a reviewer to approve the run.
- **Set `permissions: contents: read`** at the workflow or job level. The
  action does not need write permissions to the repository.
