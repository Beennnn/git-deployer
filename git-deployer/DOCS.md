# Git Deployer

Applies a git branch back to `/config`, safely. The "deploy" counterpart of
`git-exporter`. See the [repository README](https://github.com/Beennnn/git-deployer)
for the full rationale and comparison with other add-ons.

## How it works (safety model)

1. Clone/fetch the repo to `origin/<branch>` (persistent clone in `/data`).
2. Diff the chosen subfolder (`config/` by default) between the previous and new commit.
3. **Anti-clobber guard**: apply a file only if the live `/config` version equals
   the *previous* git version. Otherwise it's a **conflict** → nothing is written
   (unless `allow_partial`) and you're notified.
4. **Full HA backup** before writing.
5. Write the safe files (deletions handled).
6. **`check_config`** → **rollback** if invalid.
7. **Targeted reload** (`automation`/`script`/`scene`); restart suggested only for
   structural files (`configuration.yaml`, `packages/`).

The first run clones and **stops** (no apply without a comparison base).

## Options

| Option | Default | Meaning |
|---|---|---|
| `repository.url` | — | HTTPS clone URL of your config repo |
| `repository.username` | — | GitHub username |
| `repository.password` | — | PAT with **read** access to the repo |
| `repository.branch` | `main` | Branch to deploy |
| `deploy.subdir` | `config` | Repo subfolder that maps to `/config` |
| `deploy.dry_run` | `false` | Show the plan, write nothing |
| `deploy.allow_partial` | `false` | Apply non-conflicting files even if others conflict |
| `deploy.backup_before` | `true` | Full HA backup before writing |
| `deploy.interval` | `0` | `0` = one pass then stop; `>0` = loop every N seconds |

## Authentication

The add-on talks to Home Assistant through its **Supervisor token** — you do **not**
create a long-lived token. You only provide the git read credential
(`repository.password`).

## Triggering

- **On a schedule via HA**: an automation calling `hassio.addon_start` on this
  add-on (same pattern as `git-exporter`).
- **Self-loop**: set `deploy.interval` to a number of seconds.
- **On demand**: start the add-on manually.

## Notes

- Deploys **only** `deploy.subdir` — never the repo's meta files.
- Never wipes `/config` (unlike the official *Git pull* add-on).
- Designed to run **alongside** `git-exporter` without fighting it.
