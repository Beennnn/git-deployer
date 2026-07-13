# Home Assistant Git Deployer (git → HA)

> **The missing "deploy" half of GitOps for Home Assistant.**
> `git-exporter` pushes your `/config` **to** git. `git-deployer` applies a git
> branch **back to** `/config` — safely, on the machine, so a change reviewed in
> the cloud lands on a LAN-only Home Assistant without exposing it to the internet.

![Addon Stage: experimental](https://img.shields.io/badge/stage-experimental-orange)
![Supports aarch64](https://img.shields.io/badge/aarch64-yes-brightgreen)
![Supports amd64](https://img.shields.io/badge/amd64-yes-brightgreen)

## What it does

Runs **inside** Home Assistant (it has `git` + network), pulls a branch from your
config repository and applies its `config/**` files to `/config`, then reloads —
with real safety rails, not a blind overwrite:

- **Deploys only a chosen subfolder** (`config/` by default) — never the repo's
  meta files (`README`, `docs/`, `bin/`).
- **Anti-clobber guard** — a file is applied **only if** the live version in
  `/config` equals the *previous* git version. If it was hand-edited in the HA UI
  and not yet captured, that's a **conflict** → nothing is written (all-or-nothing)
  and you get a notification. **No silent loss of a live edit.**
- **Full HA backup before** any write.
- **`check_config` after** writing → **automatic rollback** if the result is invalid.
- **Targeted reload** (`automation` / `script` / `scene`); a restart is only
  suggested when a structural file changed (`configuration.yaml`, `packages/`).
- **First run clones and stops** (no apply without a comparison base).
- Talks to Home Assistant through the **add-on's Supervisor token** — no
  long-lived token to create by hand.

## Why this add-on

Home Assistant usually lives on the **home LAN**, unreachable from the cloud. So a
config change reviewed in a Pull Request can't be *pushed* to it from CI. The HA has
to **pull**. Existing tools each solve only one direction — and the one that pulls
was built for a model that forbids editing in the UI. `git-deployer` fills the gap:
it lets you keep **full live editing in the HA UI** *and* deploy cloud-reviewed
changes back, by treating the live box as a first-class writer (the anti-clobber
guard) instead of something to be overwritten.

It is designed to run **alongside** `git-exporter`, forming a **"live-primary
GitOps"** loop: you edit live → a snapshot captures it to git (via a validated PR)
→ cloud edits come back via `git-deployer`. `main` stays the reviewed source of
truth, fed both ways but reconciled at the PR, never in silence.

## How it compares to the existing add-ons

| | **Official "Git pull"** (git → HA) | **git-exporter** (HA → git) | **git-deployer** (this) |
|---|---|---|---|
| Direction | git → `/config` | `/config` → git | **git → `/config`** |
| Assumed source of truth | **git only** (no live UI editing) | HA (`/config`) | **either** — coexists with live editing |
| Repo layout | requires `/config` == **repo root** | any | **subfolder mapping** (`config/` → `/config`) |
| First-run behaviour | **deletes** non-matching `/config` content | n/a | clones & **stops**, applies nothing |
| Protects un-committed live edits | ✗ (git wins, overwrites) | n/a | ✅ **per-file anti-clobber guard** |
| Backup before applying | ✗ | n/a | ✅ full HA backup |
| Invalid config after apply | leaves files, just skips restart | n/a | ✅ **rolls back** the applied files |
| Reload granularity | full restart | n/a | ✅ targeted reload, restart only if structural |
| Runs beside a snapshot flow | conflicts (both own `/config`) | — | ✅ **built to complement** git-exporter |

**In short:** the official *Git pull* add-on implements pure GitOps (git owns
everything, the UI is off-limits, and it will wipe `/config` to enforce that).
`git-deployer` implements *live-primary* GitOps — the UI stays fully usable, and
the deploy is non-destructive, validated, and reversible.

## Configuration

```yaml
repository:
  url: "https://github.com/you/your-ha-config.git"
  username: "your-github-user"
  password: "ghp_xxx"          # PAT with READ access to the (private) repo
  branch: "main"
deploy:
  subdir: "config"             # repo subfolder that maps to /config
  dry_run: false               # true = show the plan, write nothing
  allow_partial: false         # true = apply non-conflicting files even if others conflict
  backup_before: true          # full HA backup before writing
  interval: 0                  # 0 = one pass then stop; >0 = loop every N seconds
```

Trigger it on a schedule the same way `git-exporter` is triggered — an HA
automation calling `hassio.addon_start` on this add-on — or set `interval` to run
its own loop.

## Installation

1. Add this repository to the add-on store (three-dot menu → *Repositories*):
   `https://github.com/Beennnn/git-deployer`
2. Install **Git Deployer**, fill in the configuration, start it.
3. First start clones and stops — inspect, then merge a small test PR and start
   again to see the incremental, validated deploy.


## Instant install (pre-built images)

By default HA **builds the image locally** on install (1–3 min). To offer a
**1-click instant install**, images are published to GHCR by
`.github/workflows/build.yml` on each release. To switch this add-on to pull the
pre-built image instead of building locally, add to `git-deployer/config.yaml`:

```yaml
image: "ghcr.io/beennnn/git-deployer-{arch}"
```

…and make the GHCR packages **public** (Settings → Packages). Do this only once
images for the current version are confirmed published, otherwise installs/updates
would fail to pull.

## Status

**Alpha / experimental.** The deploy algorithm (change detection, anti-clobber
guard, rollback, no-op) is covered by functional tests; treat production use as
supervised until you've watched a full real cycle end-to-end.

## Companion project

- [git-exporter (patched fork)](https://github.com/Beennnn/git-exporter) — the
  other half: snapshots `/config` to git.

## License

MIT — see [LICENSE](LICENSE).
