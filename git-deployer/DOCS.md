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
   **Exception — resumed files**: if the live content is byte-for-byte the version
   from another commit reachable from the branch tip, it was written by an earlier
   pass that stopped halfway, not by a person. Such a file is applied and reported
   as `REPRISE` in the log; nothing is lost, since the replaced content is still
   retrievable from the commit named in that log line.
4. **Full HA backup** before writing.
5. Write the safe files (deletions handled). Each file is written beside its target
   and renamed into place, and the whole set is **all-or-nothing**: a failed write —
   or the add-on being stopped mid-pass — restores every file already touched.
6. **`check_config`** → **rollback** if invalid.
7. Publish `deployed_sha` and the `.deploy/last-run.yaml` report, **then**
   **targeted reload** (`automation`/`script`/`scene`); restart suggested only for
   structural files (`configuration.yaml`, `packages/`). The report is written
   *before* the reload on purpose: `reload_all` refreshes the `command_line` sensor
   that reads it, so writing after would make that sensor publish the **previous**
   result until its next poll (5 min by default).

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
