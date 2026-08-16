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
4. **Full HA backup** before writing — throttled by `backup_min_interval` (24 h by
   default), see [Why the backup is throttled](#why-the-backup-is-throttled).
5. Write the safe files (deletions handled). Each file is written beside its target
   and renamed into place, and the whole set is **all-or-nothing**: a failed write —
   or the add-on being stopped mid-pass — restores every file already touched.
6. **`check_config`** → **rollback** if invalid.
7. Publish `deployed_sha` and the `.deploy/last-run.yaml` report, **then**
   **reload only the domains the pass touched** — see [Targeted reload, and why it
   matters](#targeted-reload-and-why-it-matters). The report is written *before* the
   reload on purpose: a reload refreshes the `command_line` sensor that reads it, so
   writing after would make that sensor publish the **previous** result until its next
   poll (5 min by default).
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

## Targeted reload, and why it matters

`homeassistant.reload_all` reloads **every** reloadable integration at once, including
the ones the pass never touched. On a well-stocked instance that is not a detail:
measured on 2026-08-16, a single `reload_all` call **blocked Home Assistant's event loop
for 77 seconds**. During that block the MQTT client loses its connection, so **every MQTT
entity — the whole Zigbee2MQTT fleet — goes `unavailable` at once**. That day it happened
20 times, 19 of them with no network fault whatsoever; covers and the gate stopped
answering during each hole. The tell that it is a freeze and not a network outage: the
LAN, the internet *and* the Supervisor (which runs on the same machine) all time out in
the same second.

The MQTT drop shows up **45-90 s after** the freeze starts, not during it — that is the
client's keepalive taking one period to notice. That lag is what made the network look
guilty for two days.

So the add-on reloads **only the domains the pass actually touched**. Deploying
`automations.yaml` calls `automation.reload` and nothing else — it returns in a fraction
of a second and never wakes `rest`, `command_line` or go2rtc.

| Deployed file | Reload |
|---|---|
| `automations.yaml`, `scripts.yaml`, `scenes.yaml`, `template.yaml` | that domain's `reload` |
| `input_*.yaml`, `timer.yaml`, `schedule.yaml`, `counter.yaml`, `group.yaml`, `person.yaml`, `zone.yaml` | that domain's `reload` |
| `command_line.yaml`, `rest_command.yaml`, `shell_command.yaml` | that domain's `reload` |
| `themes/**` | `frontend.reload_themes` |
| `dashboards/**`, `www/**`, images, `*.md` | **nothing** — YAML-mode Lovelace re-reads on demand |
| `configuration.yaml`, `packages/**`, `secrets.yaml`, `customize*.yaml` | `reload_core_config` + `reload_all` |
| anything else (`sensor.yaml`, `rest.yaml`, custom components, …) | `reload_core_config` + `reload_all` |

**The fallback is wide, not narrow.** Any file the table cannot name falls back to the
old whole-instance reload, and one such file widens the whole pass. A needless reload
costs a freeze; a *missed* reload produces a deploy with no effect and no error — the
worst failure mode a deployer has. Between the two, we pay the freeze. Extend the table
only on certainty.

`sensor.yaml` and `binary_sensor.yaml` are deliberately absent: their platform cannot be
told from the filename. `rest.yaml` is absent too — reloading it is broken upstream, and
it gets a restart instead (see above).

## Why the backup is throttled

`hassio.backup_full` archives **everything** — config, add-on volumes, share, media. On a
real instance that is ~1.6 GB and close to **4 minutes** of heavy disk I/O per call.
Measured across 41 passes on 2026-08-16: **144 cumulative minutes** of disk thrash in one
day, to protect the writing of a handful of YAML files. Core visibly struggles inside
those windows, and two passes had `check_config` become unreachable — producing a
`ROLLBACK` on a configuration that was in fact valid.

A pass's reversibility does **not** rest on that archive: every touched file is copied
aside before writing, `check_config` validates afterwards, and any doubt restores the lot.
The full backup covers a different, more distant risk — *"HA is broken, take me back to
yesterday"* — and one restore point per day covers that. Set `backup_min_interval: 0` to
get one backup per pass again.

## Options

| Option | Default | Meaning |
|---|---|---|
| `repository.url` | — | HTTPS clone URL of your config repo |
| `repository.username` | — | GitHub username |
| `repository.password` | — | PAT with **read** access to the repo, or `secret://<key>` — see [Keeping the token out of the options](#keeping-the-token-out-of-the-options) |
| `repository.branch` | `main` | Branch to deploy |
| `deploy.subdir` | `config` | Repo subfolder that maps to `/config` |
| `deploy.dry_run` | `false` | Show the plan, write nothing |
| `deploy.allow_partial` | `false` | Apply non-conflicting files even if others conflict |
| `deploy.backup_before` | `true` | Full HA backup before writing |
| `deploy.backup_min_interval` | `86400` | Minimum seconds between two full backups; `0` = one per pass (see [why](#why-the-backup-is-throttled)) |
| `deploy.interval` | `0` | `0` = one pass then stop; `>0` = loop every N seconds |
| `deploy.restart_on_rest` | `true` | Restart HA when the pass touches the `rest` integration (a reload does not apply it) |
| `deploy.restart_min_interval` | `3600` | Minimum seconds between two restarts; a held-back restart is remembered, not dropped |

## Authentication

The add-on talks to Home Assistant through its **Supervisor token** — you do **not**
create a long-lived token. You only provide the git read credential
(`repository.password`).

### Keeping the token out of the options

Supervisor stores add-on options **in clear text**, and hands them back in clear text
to *any* API call — `ha apps info <slug> --raw-json` and the REST endpoint behind it.
The `password:` schema type only masks the field in the UI; it protects nothing on the
API side. So a routine diagnostic is enough to copy your PAT into a log, a screenshot
or a chat transcript, after which the token has to be revoked. That is not a
hypothetical: it happened here on 2026-08-16.

Point the option at a key instead of pasting the token:

```yaml
# /config/secrets.yaml — never leaves the machine, and is git-ignored
github_pat_deployer: github_pat_11ABCDEF…
```

```yaml
# add-on options — this is all the API can ever hand back now
repository:
  password: "secret://github_pat_deployer"
```

Anything starting with `secret://` is read from `/config/secrets.yaml` at startup;
anything else is used as-is, so **existing setups keep working untouched** and you can
switch one option at a time. The resolved value is never logged, not even on failure —
errors name the *key*, which is what tells a typo apart from a revoked token.

#### Why `secret://` and not Home Assistant's own `!secret`

Supervisor understands `!secret <key>` in add-on options — but it **resolves the value
before answering the API**. Measured on Supervisor 2026.08 (2026-08-16): the stored
option does keep the literal (the error raised on an unknown key proves it), yet
`GET /addons/<slug>/info` returns the *resolved* credential, in clear text. Confirmed by
cross-check: pointing this add-on at the other add-on's key made the API hand back the
other add-on's token. So `!secret` alone does **not** close this leak — the diagnostic
prints the credential exactly as before.

`secret://` means nothing to Supervisor, which passes the string through untouched. The
add-on resolves it itself, and the API can only ever return the key name. `!secret` is
still accepted here as a safety net, but in practice the add-on never sees that form.

Two more things worth knowing:

- **Upgrade first, switch the option second.** This add-on is the one that deploys, so
  an option pointing at a key on a version that cannot read it would break the very
  loop you would need to fix it.
- `secrets.yaml` is only readable because the add-on already mounts `/config`. Nothing
  new is exposed, and Supervisor never serves that file over its API.

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
