# mcp-update-plus

MCP server maintenance for the [pi coding agent](https://github.com/earendil-works/pi): a weekly
update sweep that runs itself in the background, plus a `/mcp-update-plus` command for manual control.

## What it does

- **Weekly sweep** — the `mcp-updater` extension launches `scripts/update-mcp.ps1` in the background
  90 s after each session starts (detached, never blocks pi). Each server is checked at most once every
  7 days (state stamps), and only when a newer version actually exists upstream.
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

Sweep state lives in `~/.pi/agent/mcp-servers/state/` (`update.log`, `stamps\<name>.stamp`).
Turn the startup sweep off without uninstalling: create an empty file
`mcp-servers\state\updates-disabled`.
