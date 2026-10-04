<#
.SYNOPSIS
  Weekly, check-before-update maintenance for every MCP server in
  C:\Users\serge\.pi\agent\mcp.json.

.DESCRIPTION
  For each server listed in scripts\update-manifest.json:
    * ask the upstream registry (PyPI / npm / GitHub release tag / git upstream)
      whether a newer version exists,
    * touch the install ONLY when it is actually newer,
    * do this at most once every 7 days per server (state\stamps\<name>.stamp),
    * append everything it decides to state\update.log.
  Servers marked "enabled": false in mcp.json are skipped (use -All to include).
  Runs automatically on pi startup through the mcp-updater extension
  (~\.pi\agent\extensions\mcp-updater.ts), detached and in the background, so it
  never blocks a session.

.USAGE
  powershell -NoProfile -ExecutionPolicy Bypass -File update-mcp.ps1              # weekly sweep (quiet if nothing to do)
  powershell -NoProfile -ExecutionPolicy Bypass -File update-mcp.ps1 -Status      # installed vs latest table, changes nothing
  powershell -NoProfile -ExecutionPolicy Bypass -File update-mcp.ps1 -CheckOnly   # same as -Status but includes disabled
  powershell -NoProfile -ExecutionPolicy Bypass -File update-mcp.ps1 -Force       # ignore the 7-day stamps
  powershell -NoProfile -ExecutionPolicy Bypass -File update-mcp.ps1 -Name arxiv,github -Force
  powershell -NoProfile -ExecutionPolicy Bypass -File update-mcp.ps1 -Restart     # kill procs of servers it updated
  powershell -NoProfile -ExecutionPolicy Bypass -File update-mcp.ps1 -RepairData  # rebuild OpenNutrition 330MB food DB
.LINK
  mcp-reload.ps1 (D:\Sergey\Development) to restart / enable / disable servers in a live session.
#>
param(
  [string[]]$Name = @(),
  [switch]$All,
  [switch]$Force,
  [switch]$CheckOnly,
  [switch]$Status,
  [switch]$Restart,
  [switch]$RepairData,
  [int]$IntervalDays = 7
)

$ErrorActionPreference = 'Continue'
$Root     = 'C:\Users\serge\.pi\agent\mcp-servers'
$ConfigF  = 'C:\Users\serge\.pi\agent\mcp.json'
$Manifest = Join-Path $Root 'scripts\update-manifest.json'
$Log      = Join-Path $Root 'state\update.log'
$Stamps   = Join-Path $Root 'state\stamps'
$env:UV_TOOL_DIR = Join-Path $Root 'tools\uv'   # PyPI MCP servers live here
$env:Path = "C:\Users\serge\.local/bin;C:\Program Files\nodejs;$env:Path"

if (-not (Test-Path $Stamps)) { New-Item -ItemType Directory -Path $Stamps -Force | Out-Null }

function Log([string]$name, [string]$msg) {
  Add-Content -Path $Log -Value ("[{0}] {1,-14} {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $name, $msg)
}

# --- JSONC reader (mcp.json is allowed to contain // and /* */ comments) ----
function Read-Jsonc([string]$path) {
  $t = Get-Content -LiteralPath $path -Raw -Encoding UTF8
  $sb = New-Object System.Text.StringBuilder
  $i = 0; $n = $t.Length; $inStr = $false
  while ($i -lt $n) {
    $c = $t[$i]
    if ($inStr) {
      [void]$sb.Append($c)
      if ($c -eq '\') { if ($i + 1 -lt $n) { [void]$sb.Append($t[$i+1]); $i += 2; continue } }
      elseif ($c -eq '"') { $inStr = $false }
      $i++; continue
    }
    if ($c -eq '"') { $inStr = $true; [void]$sb.Append($c); $i++; continue }
    if ($c -eq '/' -and $i + 1 -lt $n) {
      if ($t[$i+1] -eq '/') { $k = $t.IndexOf("`n", $i); if ($k -lt 0) { $i = $n } else { $i = $k }; continue }
      if ($t[$i+1] -eq '*') { $k = $t.IndexOf('*/', $i + 2); if ($k -lt 0) { $i = $n } else { $i = $k + 2 }; continue }
    }
    [void]$sb.Append($c); $i++
  }
  # drop trailing commas (JSONC allows them, ConvertFrom-Json in PS 5.1 does not)
  $clean = [regex]::Replace($sb.ToString(), ',(\s*[}\]])', '$1')
  return ConvertFrom-Json $clean
}

function Run-Bounded([scriptblock]$sb, [int]$timeoutSec, $jobArgs = @()) {
  $j = Start-Job -ScriptBlock $sb -ArgumentList $jobArgs
  if (Wait-Job $j -Timeout $timeoutSec) {
    $out = (Receive-Job $j) -join "`n"; $st = $j.State; Remove-Job $j -Force
    return @{ ok = ($st -eq 'Completed'); out = "$out" }
  }
  Stop-Job $j -ErrorAction SilentlyContinue; Remove-Job $j -Force
  return @{ ok = $false; out = "TIMEOUT after ${timeoutSec}s" }
}

function Short([string]$s, [int]$max) {
  if (-not $s) { return '' }
  $s = (($s -replace 'System\.Management\.Automation\.RemoteException', ' ') -replace '\s+', ' ').Trim()
  if ($s.Length -gt $max) { return $s.Substring(0, $max) + '...' }
  return $s
}

# --- version probes (return '' when unknown) -------------------------------
function Get-UvVersion([string]$pkg) {
  $r = Run-Bounded { (& uv tool list 2>$null) -join "`n" } 120
  foreach ($line in ($r.out -split "`n")) {
    if ($line -match ('^\s*{0} v(\S+)' -f [regex]::Escape($pkg))) { return $Matches[1] }
  }
  return ''
}
function Get-PypiLatest([string]$pkg) {
  try { return (Invoke-RestMethod "https://pypi.org/pypi/$pkg/json" -TimeoutSec 25).info.version } catch { return '' }
}
function Get-NpmInstalled([string]$pkg) {
  $r = Run-Bounded { param($p) (& npm ls -g --depth=0 $p 2>$null) -join "`n" } 120 $pkg
  foreach ($line in ($r.out -split "`n")) {
    if ($line -match ('{0}@(\d[^\s]*)' -f [regex]::Escape($pkg))) { return $Matches[1] }
  }
  return ''
}
function Get-NpmLatest([string]$pkg) {
  $r = Run-Bounded { param($p) (& npm view $p version 2>$null) -join "`n" } 90 $pkg
  $v = "$($r.out)".Trim()
  if ($v -match '^\d') { return $v } else { return '' }
}
function Get-GitState([string]$repo) {
  $null = Run-Bounded { param($r) (& git -C $r fetch origin --tags --quiet 2>&1) -join "`n" } 180 $repo
  $b = Run-Bounded { param($r) (& git -C $r rev-list --count 'HEAD..@{upstream}' 2>&1) -join "`n" } 60 $repo
  $behind = 0; [void][int]::TryParse(($b.out -replace '\D', ''), [ref]$behind)
  $h = Run-Bounded { param($r) (& git -C $r log -1 --format='%h %s' 2>&1) -join "`n" } 30 $repo
  return @{ behind = $behind; head = (Short $h.out 60) }
}
function Get-ExeVersion([string]$exe) {
  if (-not (Test-Path $exe)) { return '' }
  $r = Run-Bounded { param($e) (& $e --version 2>&1) -join "`n" } 60 $exe
  foreach ($line in ($r.out -split "`n")) {
    if ($line -match '(?i)version[ :]+v?(\d+\.\d+[.\d]*)') { return $Matches[1] }
  }
  return ''
}
function Get-LatestRelease([string]$repo, [string]$assetMatch) {
  try {
    $rel = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -TimeoutSec 25 -Headers @{
      'User-Agent' = 'mcp-updater'; 'Accept' = 'application/vnd.github+json' }
    $asset = $rel.assets | Where-Object { $_.name -like "*$assetMatch*" } | Select-Object -First 1
    return @{ tag = ($rel.tag_name -replace '^v', ''); asset = $asset }
  } catch { return @{ tag = ''; asset = $null } }
}

# --- dataset freshness check (data pinned by repo code, e.g. opennutrition) --
# The repo code pins the dataset filename it needs (its own script). Flow:
# read pinned version from code -> compare with the local zip -> if they differ,
# download the pinned zip (+ .sha256 verify), keep the old zip as .bak, rebuild the DB.
function Update-Dataset([string]$name, $ds, [bool]$checkOnly) {
  $pinned = ''
  if (Test-Path $ds.codeFile) {
    $src = Get-Content -LiteralPath $ds.codeFile -Raw
    if ($src -match $ds.codePattern) { $pinned = $Matches[1] }
  }
  if (-not $pinned) { return 'check failed (pinned version not found in repo code)' }
  $local = ''
  if (Test-Path $ds.zipDir) {
    $z = Get-ChildItem -LiteralPath $ds.zipDir -Filter ($ds.zipPrefix + '*.zip') | Select-Object -First 1
    if ($z -and $z.Name -match ([regex]::Escape($ds.zipPrefix) + '([0-9][0-9.]*)' + [regex]::Escape('.zip') + '$')) { $local = $Matches[1] }
  }
  if (-not $local) { return ('check failed (no local zip like ' + $ds.zipPrefix + '*.zip)') }
  if ($pinned -eq $local) { return ('current (' + $pinned + ')') }
  if ($checkOnly) { return ('UPDATE ' + $local + ' -> ' + $pinned) }
  Log $name ('dataset UPDATE ' + $local + ' -> ' + $pinned + ': downloading...')
  $url = $ds.urlTemplate.Replace('{v}', $pinned)
  $tmpZip = Join-Path $env:TEMP ('mcp-{0}-dataset.zip' -f $name)
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest $url -OutFile $tmpZip -TimeoutSec 900 -UseBasicParsing
    $expected = ''
    try { $shaRaw = (Invoke-WebRequest ($url + '.sha256') -TimeoutSec 60 -UseBasicParsing).Content; $expected = (([string]$shaRaw).Trim() -split '\s+' | Select-Object -First 1) } catch { }
    if ($expected) {
      $got = (Get-FileHash -LiteralPath $tmpZip -Algorithm SHA256).Hash.ToLower()
      if ($got -ne $expected.ToLower()) { throw ('sha256 mismatch (expected ' + $expected + ', got ' + $got + ')') }
    } else {
      Log $name 'dataset: no .sha256 sidecar reachable - hash verification skipped'
    }
    $dest = Join-Path $ds.zipDir ($ds.zipPrefix + $pinned + '.zip')
    if (Test-Path $dest) { Copy-Item -LiteralPath $dest -Destination ($dest + '.bak') -Force }   # rollback copy
    Move-Item -LiteralPath $tmpZip -Destination $dest -Force
    Log $name ('dataset zip replaced with ' + $pinned + ' - rebuilding DB (takes minutes)...')
    $b = Run-Bounded { param($c) (& cmd /c $c 2>&1) -join "`n" } 3600 $ds.rebuild
    if (-not $b.ok) { throw ('rebuild failed: ' + (Short $b.out 300)) }
    Log $name ('dataset updated to {0} (previous zip kept as .bak)' -f $pinned)
    return ('updated ' + $local + ' -> ' + $pinned + ' (DB rebuilt)')
  } catch {
    Log $name ('dataset update FAILED: {0}' -f $_.Exception.Message)
    Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
    return ('UPDATE FAILED (' + $_.Exception.Message + ')')
  }
}

# --- running-server guard: never mutate a running server's files -----------
# uv reinstalls remove the venv (uv deletes site-packages BEFORE failing on a
# locked Scripts dir - that once left arxiv's venv half-deleted), and release
# swaps move a locked exe. So: defer when the server runs, unless -Restart was
# passed, in which case stop it first, then update. pi reconnects on next call.
function Get-RunningServerPids([string]$name, $cfgEntry) {
  $h = @{}
  $h[$name] = $cfgEntry
  return @(Get-ServerPids $name ([pscustomobject]@{ mcpServers = $h }))
}

# --- per-kind check/update -------------------------------------------------
function Update-One([string]$name, $m, $cfgEntry) {
  $kind = $m.kind
  $res = @{ name = $name; kind = $kind; installed = ''; latest = ''; action = 'no-op' }

  if ($kind -eq 'remote') { $res.installed = 'hosted'; $res.latest = 'hosted'; $res.action = 'remote (nothing to do)'; return $res }

  switch ($kind) {
    'uv' {
      $res.installed = Get-UvVersion $m.package
      $res.latest    = Get-PypiLatest $m.package
      $res.action    = 'up to date'
      if (-not $res.installed) { $res.action = 'not installed here' }
      elseif (-not $res.latest) { $res.action = 'PyPI query failed' }
      elseif ($res.installed -ne $res.latest) { $res.action = "UPDATE $($res.installed) -> $($res.latest)" }
      if (-not $CheckOnly -and $res.action -like 'UPDATE*' -and $res.latest) {
        $rp = @(Get-RunningServerPids $name $cfgEntry)
        if ($rp.Count -gt 0 -and -not $Restart) {
          Set-Content -Path (Join-Path $Stamps ("{0}.stamp" -f $name)) -Value (Get-Date).AddDays(-($IntervalDays + 1)).ToString('o')   # retry at next startup
          $res.action = "UPDATE deferred: server is running ($($rp.Count) process(es)) - use /mcp-update-plus $name or -Restart"
          return $res
        }
        if ($rp.Count -gt 0) {
          Log $name ("stopping running server before reinstall (pids: {0})" -f ($rp -join ', '))
          foreach ($p in $rp) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
          Start-Sleep -Seconds 1
        }
        Log $name $res.action
        # NOTE: 'uv tool upgrade' refuses anything installed with an exact pin, so
        # the manifest carries an explicit reinstall command per server (it also
        # carries yttranscript's mandatory --with "mcp<2" / --python 3.12 pins).
        $cmd = if ($m.upgrade) { $m.upgrade } else { "uv tool install --force $($m.package)" }
        $u = Run-Bounded { param($c) (& cmd /c $c 2>&1) -join "`n" } 900 $cmd
        Log $name ("uv reinstall ok={0} {1}" -f $u.ok, (Short $u.out 300))
        # verify afterwards - trust the install dir, not the command's exit code
        $now = Get-UvVersion $m.package
        $res.installed = $now
        if ($now -ne $res.latest) {
          Set-Content -Path (Join-Path $Stamps ("{0}.stamp" -f $name)) -Value (Get-Date).AddDays(-($IntervalDays + 1)).ToString('o')
          $res.action = "FAILED (still $now, wanted $($res.latest)) - will retry next run"
        } else {
          $res.action = "updated to $now"
        }
      }
    }
    'npm' {
      $res.installed = Get-NpmInstalled $m.package
      $res.latest    = Get-NpmLatest $m.package
      $res.action    = 'up to date'
      if (-not $res.installed) { $res.action = 'not installed here' }
      elseif (-not $res.latest) { $res.action = 'npm registry query failed' }
      elseif ($res.installed -ne $res.latest) { $res.action = "UPDATE $($res.installed) -> $($res.latest)" }
      if (-not $CheckOnly -and $res.action -like 'UPDATE*') {
        Log $name $res.action
        $u = Run-Bounded { param($p) (& npm install -g ("{0}@latest" -f $p) 2>&1) -join "`n" } 900 $m.package
        Log $name ("npm upgrade ok={0} {1}" -f $u.ok, (Short $u.out 200))
        if (-not $u.ok) { $res.action += ' FAILED' }
      }
    }
    'release' {
      $res.installed = Get-ExeVersion $m.exe
      $r = Get-LatestRelease $m.repo $m.asset
      $res.latest = $r.tag
      $res.action = 'up to date'
      if (-not $res.installed) { $res.action = 'binary missing' }
      elseif (-not $r.tag) { $res.action = 'GitHub release query failed' }
      elseif ($res.installed -ne $r.tag) { $res.action = "UPDATE $($res.installed) -> $($r.tag)" }
      if (-not $CheckOnly -and $res.action -like 'UPDATE*') {
        $rp = @(Get-RunningServerPids $name $cfgEntry)
        if ($rp.Count -gt 0 -and -not $Restart) {
          Set-Content -Path (Join-Path $Stamps ("{0}.stamp" -f $name)) -Value (Get-Date).AddDays(-($IntervalDays + 1)).ToString('o')   # retry at next startup
          $res.action = "UPDATE deferred: server is running ($($rp.Count) process(es)) - use /mcp-update-plus $name or -Restart"
          return $res
        }
        if ($rp.Count -gt 0) {
          Log $name ("stopping running server before swap (pids: {0})" -f ($rp -join ', '))
          foreach ($p in $rp) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
          Start-Sleep -Seconds 1
        }
        if (-not $r.asset) { $res.action = "no asset like '$($m.asset)' in $($r.tag)" }
        else {
          Log $name ("{0} downloading {1}" -f $res.action, $r.asset.name)
          $zip = Join-Path $env:TEMP ("mcp-{0}.zip" -f $name)
          $exd = Join-Path $env:TEMP ("mcp-{0}.ex" -f $name)
          try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest $r.asset.browser_download_url -OutFile $zip -TimeoutSec 600 -UseBasicParsing
            if (Test-Path $exd) { Remove-Item $exd -Recurse -Force }
            Expand-Archive -Path $zip -DestinationPath $exd -Force
            $got = Get-ChildItem $exd -Recurse -Include '*.exe' | Select-Object -First 1
            if (-not $got) { throw 'no .exe inside downloaded zip' }
            $bak = "$($m.exe).bak"
            if (Test-Path $m.exe) { Copy-Item $m.exe $bak -Force }   # keep a rollback copy
            Move-Item -Path $got.FullName -Destination $m.exe -Force
            Remove-Item $zip, $exd -Recurse -Force -ErrorAction SilentlyContinue
            Log $name ("updated to {0} (previous kept as .bak)" -f $r.tag)
          } catch {
            Log $name ("download/replace FAILED: {0}" -f $_.Exception.Message)
            Remove-Item $zip, $exd -Recurse -Force -ErrorAction SilentlyContinue
            $res.action += ' FAILED'
          }
        }
      }
    }
    default {   # git  /  git+venv  (same flow; git+venv also refreshes its .venv)
      $g = Get-GitState $m.path
      $res.installed = $g.head
      $res.latest    = if ($g.behind -gt 0) { "+$($g.behind) commits" } else { 'same' }
      $res.action    = if ($g.behind -gt 0) { "UPDATE pull $($g.behind) commit(s)" } else { 'up to date' }
      if (-not $CheckOnly -and $g.behind -gt 0) {
        Log $name $res.action
        $p = Run-Bounded { param($r) (& git -C $r pull --ff-only 2>&1) -join "`n" } 300 $m.path
        Log $name ("git pull ok={0} {1}" -f $p.ok, (Short $p.out 200))
        if (-not $p.ok) { $res.action += ' PULL FAILED' }
        elseif ($m.post) {
          Log $name 'running post-update build...'
          $b = Run-Bounded { param($c) (& cmd /c $c 2>&1) -join "`n" } ([int]$m.postTimeoutSec) $m.post
          Log $name ("post-update ok={0} {1}" -f $b.ok, (Short $b.out 300))
          if (-not $b.ok) { $res.action += ' POST FAILED' }
        }
      }
    }
  }
  if ($m.dataset) {
    $d = Update-Dataset $name $m.dataset ([bool]$CheckOnly)
    if ($d -like 'UPDATE FAILED*' -or $d -like 'check failed*') {
      Set-Content -Path (Join-Path $Stamps ("{0}.stamp" -f $name)) -Value (Get-Date).AddDays(-($IntervalDays + 1)).ToString('o')   # retry sooner
    }
    $res.action = ('{0}; dataset {1}' -f $res.action, $d)
  }

  return $res
}

# --- kill process tree of a server (used by -Restart) ---------------------
function Get-ServerPids([string]$name, $cfg) {
  $s = $cfg.mcpServers.$name
  if (-not $s -or -not $s.command) { return @() }
  $tokens = @($s.command) + @(if ($s.args) { $s.args })
  $procs = Get-CimInstance Win32_Process
  $byParent = @{}
  foreach ($p in $procs) {
    if (-not $byParent.ContainsKey([int]$p.ParentProcessId)) { $byParent[[int]$p.ParentProcessId] = @() }
    $byParent[[int]$p.ParentProcessId] += [int]$p.ProcessId
  }
  # never target this script or its ancestors (pi, the terminal): a needle that
  # is only an executable name (node.exe / python.exe) would otherwise match pi itself
  $danger = @($PID)
  try {
    $cur = $PID
    for ($i = 0; $i -lt 20 -and $cur -gt 0; $i++) {
      $danger += [int]$cur
      $pp = ($procs | Where-Object { [int]$_.ProcessId -eq [int]$cur } | Select-Object -First 1)
      if (-not $pp) { break }
      $cur = [int]$pp.ParentProcessId
    }
  } catch { }
  # every token (exe + each arg) must appear in the command line: quoting-tolerant,
  # and specific enough not to hit other servers sharing the same interpreter
  $roots = @($procs | Where-Object {
    $cl = $_.CommandLine
    if (-not $cl -or $danger -contains [int]$_.ProcessId) { return $false }
    foreach ($t in $tokens) { if ($cl -notlike ('*' + $t.Replace('[', '`[') + '*')) { return $false } }
    return $true
  } | ForEach-Object { [int]$_.ProcessId })
  $all = @(); $queue = New-Object System.Collections.Queue
  $roots | ForEach-Object { $queue.Enqueue($_) }
  while ($queue.Count -gt 0) {
    $pid_ = $queue.Dequeue()
    if ($all -contains $pid_) { continue }
    $all += $pid_
    if ($byParent.ContainsKey($pid_)) { $byParent[$pid_] | ForEach-Object { $queue.Enqueue($_) } }
  }
  return @($all | Where-Object { $danger -notcontains $_ })
}

# ============================ main =========================================
if (-not (Test-Path $Manifest)) { Write-Host "missing manifest: $Manifest"; exit 1 }
if (-not (Test-Path $ConfigF))  { Write-Host "missing config: $ConfigF"; exit 1 }
$mf = Read-Jsonc $Manifest
$cfg = Read-Jsonc $ConfigF

# optional: rebuild the OpenNutrition food database on demand
if ($RepairData) {
  $o = Join-Path $Root 'sources\mcp-opennutrition'
  Write-Host "Rebuilding OpenNutrition local DB in $o (this takes a while)..."
  & cmd /c "cd /d `"$o`" && npm install --no-audit --no-fund && npx tsc && npx tsx scripts/run-windows.ts decompress && npx tsx scripts/run-windows.ts sqlite && rd /s /q data_local_temp"
  Log 'opennutrition' '-RepairData finished'
  exit $LASTEXITCODE
}

$targets = @()
foreach ($n in $mf.servers.PSObject.Properties.Name) {
  $entry = $cfg.mcpServers.$n
  $disabled = ($entry -and ($entry.enabled -eq $false))   # pi built-in MCP: enabled:false = off
  if ($Name.Count -gt 0) { if ($Name -notcontains $n) { continue } }
  elseif (-not $All -and $disabled -and -not ($mf.servers.$n.dataset)) { continue }   # skip disabled, unless they carry a dataset to keep fresh
  elseif (-not $entry) { if (-not $All) { continue } }  # not registered in mcp.json at all
  $targets += $n
}
if ($Name.Count -gt 0) {
  $unknown = @($Name | Where-Object { $mf.servers.PSObject.Properties.Name -notcontains $_ })
  if ($unknown.Count) { Write-Host "not in manifest: $($unknown -join ', ')"; exit 1 }
}

$doWork = -not ($Status -or $CheckOnly)
$rows = @()
$updated = @()
foreach ($n in $targets) {
  $m = $mf.servers.$n
  $stamp = Join-Path $Stamps "$n.stamp"
  $fresh = $false
  if ((Test-Path $stamp) -and -not $Force) {
    $age = (Get-Date) - [datetime](Get-Content $stamp -First 1)
    $fresh = ($age.TotalDays -lt $IntervalDays)
  }
  if ($doWork -and $fresh) {
    $rows += [pscustomobject]@{ Server = $n; Kind = $m.kind; Installed = ''; Latest = ''; Action = "skipped (checked $([int]$age.TotalDays)d ago)" }
    continue
  }
  if ($doWork) { Set-Content -Path $stamp -Value (Get-Date -Format 'o') }   # stamp first: never retry-loop every launch
  $r = Update-One $n $m $cfg.mcpServers.$n
  if ($r.action -like 'UPDATE*') {
    if ($doWork) { $updated += $n; Log $n ("done: {0}" -f $r.action) }
    if ($CheckOnly -or $Status) { $r.action = 'update available: ' + ($r.action -replace '^UPDATE ', '') }
  }
  $rows += [pscustomobject]@{ Server = $n; Kind = $m.kind; Installed = $r.installed; Latest = $r.latest; Action = $r.action }
}

$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

if ($updated.Count -and $Restart) {
  Write-Host "Restarting updated servers so the new code is used..."
  foreach ($n in $updated) {
    $pids = @(Get-ServerPids $n $cfg)
    if ($pids.Count -eq 0) { Write-Host "  ${n}: not running - nothing to do"; continue }
    [array]::Reverse($pids)
    foreach ($p in $pids) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
    Write-Host "  ${n}: killed $($pids -join ', ') - pi will respawn it on next tool call"
  }
} elseif ($updated.Count) {
  Write-Host "Updated: $($updated -join ', '). Idle MCP servers pick the new code up on their next start (or run mcp-reload.ps1)."
}
exit 0
