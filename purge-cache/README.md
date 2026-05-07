# FlareOps – Cloudflare Cache Purge

A composite GitHub Action that purges Cloudflare cache from a CI/CD pipeline.
It supports every purge mode the Cloudflare API exposes — full-zone,
per-file, hostname, cache-tag, and prefix — plus multi-zone fan-out, with
production-grade retries, structured logging, secret masking, and dry-run.

- **Marketplace category:** Deployment / DevOps
- **Runs on:** `ubuntu-*`, `macos-*`, `windows-*` (with bash), self-hosted Linux
- **Dependencies:** `bash 3.2+` (works on stock macOS), `curl`, `jq` (all preinstalled on GitHub-hosted runners)

---

## Usage

```yaml
- uses: amitsdalal/FlareOps/purge-cache@v1
  with:
    zone_id: ${{ secrets.CLOUDFLARE_ZONE_ID }}
    purge_type: everything
    bearer_token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

See [`./examples/`](./examples/) for end-to-end workflows for each purge type.

---

## Inputs

| Name           | Required | Default                                  | Description |
|----------------|----------|------------------------------------------|-------------|
| `zone_id`      | one of   | —                                        | Single zone ID. |
| `zone_ids`     | one of   | —                                        | Newline/comma list of zone IDs (multi-zone). Takes precedence over `zone_id`. |
| `purge_type`   | yes      | `everything`                             | One of `everything`, `files`, `hostnames`, `tags`, `prefixes`. |
| `files`        | cond.    | —                                        | Required when `purge_type=files`. Newline/comma list of URLs or JSON file-with-headers objects. |
| `hostnames`    | cond.    | —                                        | Required when `purge_type=hostnames`. Newline/comma list. |
| `cache_tags`   | cond.    | —                                        | Required when `purge_type=tags`. Newline/comma list. |
| `prefixes`     | cond.    | —                                        | Required when `purge_type=prefixes`. Newline/comma list. |
| `bearer_token` | one of   | —                                        | Cloudflare API Token (preferred). |
| `email`        | one of   | —                                        | Cloudflare account email (with `api_key` as fallback auth). |
| `api_key`      | one of   | —                                        | Cloudflare Global API Key (with `email` as fallback auth). |
| `dry_run`      | no       | `false`                                  | Print the request without sending it. |
| `debug`        | no       | `false`                                  | Verbose logging including HTTP codes and (truncated) responses. |
| `timeout`      | no       | `30`                                     | Per-request timeout in seconds. |
| `retries`      | no       | `3`                                      | Retry attempts on transient errors (5xx, 429, 408, network). |
| `retry_delay`  | no       | `2`                                      | Base delay (s); exponential backoff with jitter. |
| `api_endpoint` | no       | `https://api.cloudflare.com/client/v4`   | API base URL override (testing only). |

### Authentication rules

- If `bearer_token` is set → Bearer auth is used. `email`/`api_key` are ignored.
- Otherwise → both `email` and `api_key` are required. The action fails fast
  with a clear error if either is missing.

### Zone rules

- Either `zone_id` (single) or `zone_ids` (multi) must be set.
- If both are set, `zone_ids` wins.
- Zone IDs are validated against `^[a-f0-9]{32}$` before any API call —
  catches accidental zone-name pastes.

### Input parsing

List inputs (`files`, `hostnames`, `cache_tags`, `prefixes`, `zone_ids`)
accept either commas or newlines as separators, and any combination thereof.
Whitespace is trimmed; empty entries are dropped.

For `files`, individual entries may also be JSON objects matching
Cloudflare's [files-with-headers](https://developers.cloudflare.com/api/operations/zone-purge#purge-cached-content-by-url) shape:

```yaml
files: |
  https://example.com/plain.css
  {"url": "https://example.com/varied.html", "headers": {"Origin": "https://app.example.com"}}
```

> **Note:** the `files` input is split on **newlines only**, not commas,
> because JSON object entries legitimately contain commas. Use newlines to
> separate file entries.

---

## Outputs

| Name              | Description |
|-------------------|-------------|
| `success`         | `true` if all targeted zones succeeded, `false` otherwise. |
| `response_code`   | HTTP status of the last (or only) API response. |
| `request_id`      | Cloudflare `cf-ray` ID — share with Cloudflare support. |
| `purge_type`      | The resolved purge type that was executed. |
| `zones_processed` | Comma-separated list of zone IDs that succeeded. |
| `failed_zones`    | Comma-separated list of zone IDs that failed (empty on full success). |

The action also writes a markdown summary to `$GITHUB_STEP_SUMMARY` so the
result is visible from the run's summary page without opening logs.

---

## Cloudflare permissions

Use the [API Tokens UI](https://dash.cloudflare.com/profile/api-tokens) and
create a token with **only**:

- Permission: **Zone › Cache Purge › Purge**
- Zone resources: limited to the specific zone(s) you purge from CI

This is a least-privilege scope. A leaked token can purge cache (annoying
but not catastrophic), but cannot read/modify DNS, billing, account
settings, or anything else.

If you must use the Global API Key, treat it as a **root credential** —
anyone with it can do anything to your account. Rotate it immediately if
it ever leaves a secret manager.

> Cache-tag, hostname, and prefix purges require a Cloudflare **Enterprise**
> plan. The action will surface the plan-limit error from Cloudflare with
> the original message and `cf-ray` ID so it's easy to triage.

---

## Examples

| File                                         | Pattern                                                  |
|----------------------------------------------|----------------------------------------------------------|
| [`examples/purge-everything.yml`](./examples/purge-everything.yml) | Full-zone purge after a `push` to `main`.       |
| [`examples/purge-files.yml`](./examples/purge-files.yml)           | Per-URL purges from `workflow_dispatch` input.  |
| [`examples/purge-tags.yml`](./examples/purge-tags.yml)             | Cache-tag purges driven by a CMS webhook.       |
| [`examples/purge-hostnames.yml`](./examples/purge-hostnames.yml)   | Hostname purges (Enterprise).                   |
| [`examples/multi-zone.yml`](./examples/multi-zone.yml)             | Multi-zone fan-out with partial-failure alerting. |

---

## Reliability

### Retries

Transient failures (HTTP `408`, `429`, `5xx`, network/DNS errors) are
retried up to `retries` times (default 3). The schedule is
`base * 2^attempt` seconds plus jitter, with `base = retry_delay`. On a
`429` response, the action honors the `Retry-After` header instead of
applying its own backoff — it does what Cloudflare asked for.

Non-retryable failures (4xx other than 408/429, plus `success: false` in a
2xx body) bail out immediately with a clear error.

### Multi-zone partial failure

When `zone_ids` is set, zones are purged sequentially. The action exits
non-zero if **any** zone fails, but it always emits both
`zones_processed` and `failed_zones` so a follow-up step (Slack, PagerDuty)
can inspect what happened. Sequential — not parallel — execution is a
deliberate trade-off: it gives clean logs, predictable retry behavior, and
keeps you well clear of Cloudflare's per-account rate limits.

### Idempotency

Cloudflare's purge endpoints are idempotent for our use cases — purging the
same URL twice has the same observable effect as purging it once. So
retrying after a transient failure is safe, even if the original request
actually succeeded but the response was lost.

---

## Rate limits

Cloudflare publishes per-token and per-zone rate limits for the purge API.
At time of writing (verify against the [official docs](https://developers.cloudflare.com/cache/how-to/purge-cache/purge-rate-limits/)):

- 1,000 purge API calls / 24 hours / zone (free / pro / business).
- 30 URL/file purges per request.
- 30 cache-tag purges per request.

If you need higher throughput, batch URLs into the same request (the action
sends one request per zone with up to 30 entries — Cloudflare rejects
larger batches with a clear error).

---

## Troubleshooting

**`Authentication required.`**
Neither `bearer_token` nor (`email` + `api_key`) is set. Wire up at least
one of those; double-check the secret name in your workflow file.

**`Zone ID … does not look like a valid Cloudflare zone ID`**
You probably pasted the zone *name* (e.g. `example.com`). Find the 32-char
hex zone ID on the Cloudflare dashboard's zone overview page.

**HTTP 403 with `Authentication error` from Cloudflare.**
Token doesn't have `Zone:Cache Purge` for this zone, or it expired.
Recreate the token; old tokens can't be edited.

**HTTP 429.**
You've hit the per-zone purge rate limit. The action honors `Retry-After`
automatically, but if you keep hitting it, batch your purges or move to a
plan with higher limits.

**HTTP 200 but `success: false` with `cache.api.request_invalid`.**
Almost always a malformed body — usually because cache-tags or hostnames
require Enterprise. Run with `debug: 'true'` to see the request body and
the full Cloudflare error array.

**Action runs forever.**
Reduce `timeout`. The default is 30s per request, but a misconfigured
network egress will hang each retry until the timeout.

---

## Security

- Credentials are masked via `::add-mask::` at startup so they cannot leak
  into logs even if a downstream tool prints them.
- Auth is passed via headers, not URL params or `--user`, so it never
  appears in `ps(1)` output on shared self-hosted runners.
- The request body is sent on stdin, not the command line.
- Tempfiles are cleaned up via a `trap`, including on error.
- The action requests no GitHub permissions — set
  `permissions: contents: read` at the workflow level for least privilege.

For the full threat model, see the repo-level [SECURITY.md](../SECURITY.md).

---

## Versioning

Pin to whichever stability level you need:

- `@v1` — floating major (recommended)
- `@v1.0.0` — pinned release
- `@<sha>` — pinned commit (regulated workloads)

The repo follows SemVer. Release notes live in [`CHANGELOG.md`](../CHANGELOG.md).
