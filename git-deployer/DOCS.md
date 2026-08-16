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
8. **Restart when the pass touches the `rest` integration** — see below.

The first run clones and **stops** (no apply without a comparison base).

## Why a `rest` deploy triggers a restart

Reloading the `rest` integration recreates its entities **without having removed the
previous ones**: the new ones are all rejected (`ID … already exists - ignoring`) and the
**old configuration stays in service** — upstream bug closed as *not planned*
([home-assistant/core#93527](https://github.com/home-assistant/core/issues/93527)).

So a reload-only deploy of `rest.yaml` is a **silent no-op**: merged, written,
`deployed_sha` up to date, and with no effect until the next restart. The add-on therefore
calls `homeassistant/restart` when the applied files include `rest.yaml`, a `- platform:
rest` entry, or a top-level `rest:` key.

A restart costs ~1 min of downtime, so it is throttled by `restart_min_interval`. A restart
held back by that throttle is **remembered on disk and performed on a later pass** — without
that memory the throttle would recreate the very no-op it exists to prevent, since the next
pass has nothing left to deploy. Set `restart_on_rest: false` to opt out entirely (you then
own the restart yourself).

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
| `deploy.restart_on_rest` | `true` | Restart HA when the pass touches the `rest` integration (a reload does not apply it) |
| `deploy.restart_min_interval` | `3600` | Minimum seconds between two restarts; a held-back restart is remembered, not dropped |

## Authentication

The add-on talks to Home Assistant through its **Supervisor token** — you do **not**
create a long-lived token. You only provide the git read credential
(`repository.password`).

## Triggering

- **On a schedule via HA**: an automation calling `hassio.addon_start` on this
  add-on (same pattern as `git-exporter`).
- **Self-loop**: set `deploy.interval` to a number of seconds.
- **On demand, without restarting** (loop mode): turn
  `input_boolean.git_deployer_run_now` **on** — from a dashboard button, an
  automation, or `input_boolean.turn_on`. The add-on checks that flag every 15 s
  while it waits, runs a pass as soon as it sees it, and turns it back off. The
  helper is optional: create it in your config repo
  (`input_boolean:` → `git_deployer_run_now:`) and it starts working on the next
  pass; without it the loop behaves exactly as before.
- **On demand**: start the add-on manually.

> **Do not use `hassio.addon_restart` to force an early pass.** Restarting drops
> the `input_text.ha_deployed_sha` marker that `git-exporter` reads to skip a
> snapshot while a deploy is pending, which re-opens the lost-update race that
> marker closes; and a restart that starts from a fresh clone can skip the apply.
> The `run_now` flag exists so you never need to.

## Notes

- Deploys **only** `deploy.subdir` — never the repo's meta files.
- Never wipes `/config` (unlike the official *Git pull* add-on).
- Designed to run **alongside** `git-exporter` without fighting it.
