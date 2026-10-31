# mcp-update-plus

MCP server maintenance for the [pi coding agent](https://github.com/earendil-works/pi): a weekly
update sweep that runs itself in the background, plus a `/mcp-update-plus` command for manual control.

## What it does

- **Weekly sweep** — the `mcp-updater` extension hands `scripts/update-mcp.ps1` to a hidden background
  process at every session start (never blocks pi, survives pi closing). The process first waits 90 s so
  this session's servers finish connecting, then checks each server at most once every 7 days (state
  stamps) and updates it only when a newer version actually exists upstream. It runs with `-All`, so
  servers that are installed but currently switched off in `mcp.json` (`enabled: false`) stay current too
  - otherwise they would silently never be visited.
- **`/mcp-update-plus`** (in-session command):
  - no args — forced check + update of every manifest server now (ignores stamps), then restarts
    updated servers (pi respawns them on the next tool call)
  - `check` — check-only: installed vs latest table, changes nothing
  - `/mcp-update-plus arxiv github` — forced update of the named servers only

## Update kinds (per server, from `update-manifest.json`)

| kind | checks | updates by |
|---|---|---|
| `uv` | PyPI latest vs installed venv | `uv tool install --force` (per-server upgrade command) |
| `npm` | npm registry vs global install | `npm install -g pkg@latest` |
| `release` | GitHub latest release tag vs exe version | download the release asset, keep the previous exe as `.bak` |
| `git` | local clone vs upstream | `git pull --ff-only` + optional post-update build command |
| `remote` | hosted servers (nothing to check) | — |
| `dataset` | the dataset version pinned in the repo's code vs the local zip | download the pinned zip, verify its SHA-256 against the publisher's `.sha256`, keep the old zip as `.bak`, rebuild the DB |

## Running-server guard

An update never mutates the files of a **running** server: `uv` reinstalls remove the venv before they
can fail on a locked directory (this once left a half-deleted venv), and release swaps move a locked
exe. Running servers are either **deferred** (stamp reset, retried at the next startup) or — when
`-Restart` is passed (every forced `/mcp-update-plus` run passes it) — stopped first, updated, and pi
reconnects them on the next tool call, now from the new code.

## Install

```bash
pi install git:github.com/sbsamarski/mcp-update-plus
```

or copy the folder into `~/.pi/agent/extensions/` and run `/reload`.

The extension points at `scripts/update-mcp.ps1` inside its own folder. The script reads its machine
layout from absolute paths at the top of the file — edit `$Root`, `$ConfigF`, `$Manifest`, `$Log`,
`$Stamps` and the manifest's server entries when moving to another machine. It expects `uv`, `node`,
`npm` and `git` on PATH (it prepends common locations itself).

## Files

```
extensions/mcp-updater.ts   pi extension: background sweep hook + /mcp-update-plus command
scripts/update-mcp.ps1      the updater itself (kinds, guards, stamps, logging)
```

Handy runs for a terminal:

```powershell
$s = "$HOME\.pi\agent\extensions\mcp-update-plus\scripts\update-mcp.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File $s -CheckOnly -All   # table, changes nothing
powershell -NoProfile -ExecutionPolicy Bypass -File $s -Force -All       # update everything now
```

Sweep state lives in `~/.pi/agent/mcp-servers/state/` (`update.log`, `stamps\<name>.stamp`).
Turn the startup sweep off without uninstalling: create an empty file
`mcp-servers\state\updates-disabled`.

## Reading the log

Every run writes a `sweep  start` line and a `sweep  finished` line to `update.log`, plus one line per
thing it actually did, and the extension writes a `launch` line when it hands a sweep to the background.
So "nothing happened" and "nobody ever got here" are visibly different. If the log has no `start` line
for a day you had pi open, the hook is not firing - check the extension, not the servers.

### Two sweeps at once

Only one sweep may install things at a time (a named mutex), so two pi sessions opened together cannot
reinstall the same tool box twice. The rules:

- the lock is taken **after** the 90 s settle wait, because a background sweep that is merely waiting
  must not block a command you ran yourself
- a read-only table (`check`, `-CheckOnly`, `-Status`) takes no lock and is never blocked
- a run you asked for waits up to `-LockWaitSeconds` (default 120) for a sweep that is genuinely working;
  a background sweep gives up immediately instead of queueing
- when it gives up, it says so on screen and in the log - never a silent "finished OK"

The last line the script prints is a `Summary:` line, and that is what the `/mcp-update-plus`
notification shows, so a run that changed nothing says "nothing to update" rather than just "OK".

## Windows pitfall: never spawn PowerShell with `detached: true`

The startup hook must not use Node's `detached: true`. On Windows libuv turns that into the
`DETACHED_PROCESS` create flag, which gives the child no console at all, and Windows PowerShell 5.1 then
exits within about 70 ms - having run none of the script, printing nothing, and reporting exit code 0.
The old hook looked healthy for exactly that reason: a notification claimed the sweep had started, and
nothing ever reached the log. The hook now starts a short-lived helper PowerShell (which does get a
console, just no window) that hands the real work to an independent grandchild with `Start-Process`.
That keeps the fire-and-forget behaviour and it keeps working when pi closes a few seconds later.

> **Note on `tsconfig.json`:** it exists only for optional type-checking on the maintainer's machine
> (its `paths` entries point at the maintainer's global pi install). It is never used at runtime and
> does not affect loading, running, or installing this extension on another computer.
