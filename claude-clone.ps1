<#
.SYNOPSIS
    claude-clone - run several Claude accounts side by side.

.DESCRIPTION
    Finds Claude Desktop and Claude Code on this machine and creates extra, fully separate
    profiles ("clones") for them. Every clone signs in on its own, keeps its own windows and
    gets its own shortcut with the Claude icon.

    Every Desktop launcher checks its profile before Claude starts: broken links are repaired
    (Claude has moved its data folder before) and the session list of the signed-in account is
    synced with the main profile. -Doctor shows the state of all profiles, -Repair fixes it.

    Windows: run with Windows PowerShell 5.1 or PowerShell 7.
    macOS / Linux: this script hands over to claude-clone.sh.

.EXAMPLE
    .\claude-clone.ps1                       # dashboard
    .\claude-clone.ps1 -Product desktop -Names work,personal -Yes
    .\claude-clone.ps1 -List
    .\claude-clone.ps1 -Doctor               # check everything, change nothing
    .\claude-clone.ps1 -Repair               # fix what -Doctor found
    .\claude-clone.ps1 -Sync                 # sync the session lists now
    .\claude-clone.ps1 -Launch work
    .\claude-clone.ps1 -Set work -Label 'Family' -SessionSync pull
    .\claude-clone.ps1 -Move work -To D:\ClaudeProfiles
    .\claude-clone.ps1 -Rename work -To client-b
    .\claude-clone.ps1 -NameAccount '4f1c2a9e=Work'
    .\claude-clone.ps1 -Find 'invoice'       # which profile and account has that session?
    .\claude-clone.ps1 -Backup               # session lists of the main profile and every clone
    .\claude-clone.ps1 -Restore work-sessions-20261020-201500.zip
    .\claude-clone.ps1 -Update               # newest claude-clone from GitHub, launchers updated
    .\claude-clone.ps1 -Install              # 'claude-clone' command in every terminal
    .\claude-clone.ps1 -Remove work -Purge
#>
[CmdletBinding()]
param(
    [ValidateSet('desktop', 'code', 'both')]
    [string]$Product,
    [int]$Count,
    [string[]]$Names,
    [string]$Path,
    [string]$Label,
    [ValidateSet('both', 'pull', 'off')]
    [string]$SessionSync,
    [switch]$NoShareSessions,
    [switch]$NoShareRuntime,
    [switch]$NoCopySettings,
    [switch]$NoShortcuts,
    [switch]$NoMainShortcut,
    [switch]$NoBadge,
    [switch]$NoSyncOnExit,
    [switch]$NoPath,
    [switch]$List,
    [switch]$Doctor,
    [switch]$Repair,
    [switch]$Sync,
    [string]$Find,
    [string]$Launch,
    [string]$Set,
    [switch]$CopySettings,
    [string]$Move,
    [string]$Rename,
    [string]$To,
    [string[]]$NameAccount,
    [switch]$Backup,
    [string]$Restore,
    [switch]$Update,
    [switch]$Install,
    [string]$Remove,
    [switch]$Purge,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$Version = '1.3.0'
$RawBase = 'https://raw.githubusercontent.com/sfr-development/claude-clone/main'
$BoundParams = $PSBoundParameters

# ---------------------------------------------------------------------------------------------
# macOS / Linux: hand over to the bash implementation
# ---------------------------------------------------------------------------------------------
$onWindows = $true
if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { $onWindows = $false }
if (-not $onWindows) {
    $sh = $null
    if ($PSScriptRoot) { $sh = Join-Path $PSScriptRoot 'claude-clone.sh' }
    if (-not $sh -or -not (Test-Path $sh)) {
        $sh = Join-Path ([IO.Path]::GetTempPath()) 'claude-clone.sh'
        Invoke-WebRequest "$RawBase/claude-clone.sh" -OutFile $sh
    }
    $fwd = @()
    if ($Product) { $fwd += @('--product', $Product) }
    if ($Count) { $fwd += @('--count', "$Count") }
    if ($Names) { $fwd += @('--names', ($Names -join ',')) }
    if ($Path) { $fwd += @('--path', $Path) }
    if ($NoShareSessions -or $SessionSync -eq 'off') { $fwd += '--no-share-sessions' }
    if ($NoCopySettings) { $fwd += '--no-copy-settings' }
    if ($NoShortcuts) { $fwd += '--no-shortcuts' }
    if ($NoMainShortcut) { $fwd += '--no-main-shortcut' }
    if ($List) { $fwd += '--list' }
    if ($Doctor) { $fwd += '--doctor' }
    if ($Repair) { $fwd += '--repair' }
    if ($Launch) { $fwd += @('--launch', $Launch) }
    if ($Remove) { $fwd += @('--remove', $Remove) }
    if ($Purge) { $fwd += '--purge' }
    if ($Yes) { $fwd += '--yes' }
    & bash $sh @fwd
    exit $LASTEXITCODE
}

# ---------------------------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------------------------
function Say([string]$Text, [string]$Color = 'Gray') { Write-Host $Text -ForegroundColor $Color }
function Step([string]$Text) { Write-Host ''; Write-Host "  $Text" -ForegroundColor Cyan }
function Ok([string]$Text) { Write-Host "    [ok] $Text" -ForegroundColor Green }
function Warn([string]$Text) { Write-Host "    [!]  $Text" -ForegroundColor Yellow }
function Bad([string]$Text) { Write-Host "    [x]  $Text" -ForegroundColor Red }
function Info([string]$Text) { Write-Host "    [i]  $Text" -ForegroundColor DarkGray }
function Fixed([string]$Text) { Write-Host "    [fixed] $Text" -ForegroundColor Green }

function Ask([string]$Question, [string]$Default) {
    if ($Yes) { return $Default }
    $hint = ''
    if ($Default) { $hint = " [$Default]" }
    $a = Read-Host "  $Question$hint"
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return $a.Trim()
}

function AskYesNo([string]$Question, [bool]$Default = $true) {
    if ($Yes) { return $Default }
    $d = 'Y/n'
    if (-not $Default) { $d = 'y/N' }
    $a = Read-Host "  $Question [$d]"
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return ($a.Trim().ToLower() -in @('y', 'yes', 'j', 'ja'))
}

function Safe-Name([string]$Name) {
    $n = ($Name -replace '[^A-Za-z0-9_-]', '-').Trim('-')
    if (-not $n) { throw "Invalid clone name: '$Name'" }
    return $n
}

# Single-quoted PowerShell literal, for paths written into launchers
function Quote-PS([string]$Text) { return "'" + $Text.Replace("'", "''") + "'" }

# ---------------------------------------------------------------------------------------------
# Runtime: everything a launcher needs to check and repair its profile before Claude starts.
# The same text is embedded into every launcher, so launchers keep working without this script
# and after Claude updates itself.
# ---------------------------------------------------------------------------------------------
$RuntimeLib = @'
# ---- claude-clone runtime ----
function Resolve-ClaudeDesktop {
    $pkgs = @()
    try { $pkgs = @(Get-AppxPackage -Name '*Claude*' -ErrorAction Stop) } catch {
        try { Import-Module Appx -UseWindowsPowerShell -ErrorAction Stop -WarningAction SilentlyContinue; $pkgs = @(Get-AppxPackage -Name '*Claude*' -ErrorAction Stop) } catch { }
    }
    $pkg = $pkgs | Where-Object { $_.InstallLocation -and (Test-Path (Join-Path $_.InstallLocation 'app\Claude.exe')) } |
        Sort-Object { try { [version]"$($_.Version)" } catch { [version]'0.0' } } -Descending | Select-Object -First 1
    if ($pkg) { return @{ Exe = (Join-Path $pkg.InstallLocation 'app\Claude.exe'); Kind = 'msix'; Root = $pkg.InstallLocation; Pfn = $pkg.PackageFamilyName; Version = "$($pkg.Version)" } }
    $squirrel = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
    if (Test-Path (Join-Path $squirrel 'claude.exe')) {
        $app = Get-ChildItem $squirrel -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
            Sort-Object { try { [version]($_.Name -replace '^app-', '') } catch { [version]'0.0' } } -Descending | Select-Object -First 1
        $exe = Join-Path $squirrel 'claude.exe'
        if ($app -and (Test-Path (Join-Path $app.FullName 'claude.exe'))) { $exe = Join-Path $app.FullName 'claude.exe' }
        $ver = ''
        if ($app) { $ver = $app.Name -replace '^app-', '' }
        return @{ Exe = $exe; Kind = 'squirrel'; Root = $squirrel; Version = $ver }
    }
    foreach ($c in @((Join-Path $env:LOCALAPPDATA 'Programs\Claude\Claude.exe'), (Join-Path $env:ProgramFiles 'Claude\Claude.exe'))) {
        if (Test-Path $c) { return @{ Exe = $c; Kind = 'exe'; Root = (Split-Path $c); Version = (Get-Item $c).VersionInfo.ProductVersion } }
    }
    return $null
}

# Data folder of the main Claude Desktop profile. It has moved before: %APPDATA%\Claude (installer),
# %LOCALAPPDATA%\Packages\<family>\LocalCache\Roaming\Claude (Microsoft Store) and, since 2026,
# %LOCALAPPDATA%\Claude-Data\claude_<publisher>. A folder Claude moved away from keeps only a
# ".user-data-left.*" marker. The newest folder with a config.json wins.
function Resolve-ClaudeMainData($Desk) {
    if ($env:CLAUDE_CLONE_MAIN_DATA) { return $env:CLAUDE_CLONE_MAIN_DATA }
    $pub = ''
    if ($Desk -and $Desk.Pfn) { $pub = ($Desk.Pfn -split '_')[-1] }
    $cands = @()
    $cands += @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Claude-Data') -Directory -ErrorAction SilentlyContinue |
        Sort-Object { -not ($pub -and $_.Name -like "*_$pub") } | ForEach-Object { $_.FullName })
    if ($Desk -and $Desk.Pfn) { $cands += Join-Path $env:LOCALAPPDATA "Packages\$($Desk.Pfn)\LocalCache\Roaming\Claude" }
    $cands += @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'LocalCache\Roaming\Claude' })
    $cands += Join-Path $env:APPDATA 'Claude'
    $best = $null
    $bestTime = [datetime]::MinValue
    foreach ($c in $cands) {
        $cfg = Join-Path $c 'config.json'
        if (-not (Test-Path -LiteralPath $cfg -PathType Leaf)) { continue }
        if (@(Get-ChildItem -LiteralPath $c -Force -File -Filter '.user-data-left*' -ErrorAction SilentlyContinue).Count) { continue }
        $t = (Get-Item -LiteralPath $cfg -Force).LastWriteTimeUtc
        if ($t -gt $bestTime) { $best = $c; $bestTime = $t }
    }
    return $best
}

function Test-SamePath([string]$A, [string]$B) {
    if (-not $A -or -not $B) { return $false }
    return ($A.TrimEnd('\') -ieq $B.TrimEnd('\'))
}

# $null if nothing is there; otherwise IsLink (junction or symbolic link), Target and Dead.
# Test-Path is $true for a dead junction itself, so the target is checked separately.
function Get-LinkInfo([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    $isLink = "$($item.LinkType)" -in @('Junction', 'SymbolicLink')
    $target = ''
    if ($isLink) {
        $target = [string](@($item.Target) | Select-Object -First 1)
        $target = $target -replace '^\\\\\?\\', '' -replace '^\\\?\?\\', ''
        if ($target -and -not [IO.Path]::IsPathRooted($target)) { $target = Join-Path (Split-Path $Path) $target }
    }
    return [pscustomobject]@{ IsLink = $isLink; Target = $target; Dead = ($isLink -and (-not $target -or -not (Test-Path -LiteralPath $target))) }
}

# Removes only the link itself, never what it points to
function Remove-Link([string]$Path) {
    try { [IO.Directory]::Delete($Path, $false) } catch {
        try { [IO.File]::Delete($Path) } catch { try { cmd /c "rmdir `"$Path`"" 2>$null | Out-Null } catch { } }
    }
    return (-not (Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue))
}

# Claude Desktop windows (not its helper processes, not Claude Code) and their --user-data-dir
function Get-DesktopProcesses($Desk) {
    $all = @()
    try { $all = @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction Stop) } catch { return @() }
    $out = @()
    foreach ($p in $all) {
        $cl = "$($p.CommandLine)"
        if (-not $cl -or $cl -match '--type=') { continue }
        $exe = "$($p.ExecutablePath)"
        if (-not $exe -and $cl -match '^\s*"([^"]+)"') { $exe = $Matches[1] }
        $isDesktop = ($exe -match '(?i)\\WindowsApps\\[^\\]*Claude[^\\]*\\app\\claude\.exe$') -or ($exe -match '(?i)\\AnthropicClaude\\') -or ($Desk -and $exe -ieq $Desk.Exe)
        if (-not $isDesktop) { continue }
        $dir = ''
        if ($cl -match '--user-data-dir=(?:"([^"]+)"|(\S+))') { $dir = "$($Matches[1])$($Matches[2])".TrimEnd('\') }
        $out += [pscustomobject]@{ Id = $p.ProcessId; UserDataDir = $dir }
    }
    return $out
}

function Test-ProfileRunning([string]$Dir, $Procs) { return [bool](@($Procs | Where-Object { Test-SamePath $_.UserDataDir $Dir }).Count) }
function Test-MainRunning($Procs) { return [bool](@($Procs | Where-Object { -not $_.UserDataDir }).Count) }

# Reads a file that Claude may have open at the same time
function Read-SharedBytes([string]$Path) {
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
    try {
        $buf = New-Object byte[] $fs.Length
        $read = 0
        while ($read -lt $buf.Length) {
            $n = $fs.Read($buf, $read, $buf.Length - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        return , $buf
    } finally { $fs.Dispose() }
}

# Account a profile was last signed in with (only this id is read from config.json, never a token)
function Get-ActiveAccount([string]$Dir) {
    $cfg = Join-Path $Dir 'config.json'
    if (-not (Test-Path -LiteralPath $cfg -PathType Leaf)) { return '' }
    try { $raw = [Text.Encoding]::UTF8.GetString((Read-SharedBytes $cfg)) } catch { return '' }
    if ($raw -match '"lastKnownAccountUuid"\s*:\s*"([0-9a-fA-F-]{36})"') { return $Matches[1].ToLower() }
    return ''
}

# Accounts with a session list in this profile: claude-code-sessions\<account>\<organization>\...
function Get-AccountFolders([string]$Dir) {
    $root = Join-Path $Dir 'claude-code-sessions'
    $li = Get-LinkInfo $root
    if (-not $li -or $li.IsLink) { return @() }
    return @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^[0-9a-fA-F-]{36}$' } | ForEach-Object { $_.Name.ToLower() })
}

function Get-ProfileAccounts([string]$Dir) {
    $ids = @(Get-ActiveAccount $Dir) + @(Get-AccountFolders $Dir)
    return @($ids | Where-Object { $_ } | Select-Object -Unique)
}

function Get-SessionCount([string]$Dir, [string]$Account) {
    $acc = Join-Path (Join-Path $Dir 'claude-code-sessions') $Account
    $n = 0
    foreach ($org in @(Get-ChildItem -LiteralPath $acc -Directory -Force -ErrorAction SilentlyContinue)) {
        $n += @(Get-ChildItem -LiteralPath $org.FullName -File -Force -Filter 'local_*.json' -ErrorAction SilentlyContinue).Count
    }
    return $n
}

# Copies through a temp file so Claude never reads a half-written file. Returns $false (and is
# retried at the next start) when the source is being written or is not complete JSON.
function Copy-SessionFile([string]$Src, [string]$Dst) {
    try { $bytes = Read-SharedBytes $Src } catch { return $false }
    if ($Src -like '*.json') {
        $txt = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF).Trim()
        if (-not ($txt.StartsWith('{') -and $txt.EndsWith('}'))) { return $false }
    }
    $time = (Get-Item -LiteralPath $Src -Force).LastWriteTimeUtc
    $tmp = "$Dst.claude-clone-tmp"
    try {
        $dir = Split-Path $Dst
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        [IO.File]::WriteAllBytes($tmp, $bytes)
        if (Test-Path -LiteralPath $Dst) { [IO.File]::Copy($tmp, $Dst, $true); [IO.File]::Delete($tmp) }
        else { [IO.File]::Move($tmp, $Dst) }
        [IO.File]::SetLastWriteTimeUtc($Dst, $time)
        return $true
    } catch {
        try { if (Test-Path -LiteralPath $tmp) { [IO.File]::Delete($tmp) } } catch { }
        return $false
    }
}

# Merges the session lists of the given accounts from one claude-code-sessions folder into another.
# Never deletes. Existing entries are only replaced by newer ones when $AllowUpdate is set (target
# app not running). A session deleted on one side is never brought back.
function Sync-SessionRoot([string]$From, [string]$To, [string[]]$Accounts, [bool]$AllowUpdate, [bool]$WhatIf) {
    $r = [pscustomobject]@{ Added = 0; Updated = 0; Skipped = 0 }
    foreach ($acc in @($Accounts | Where-Object { $_ })) {
        $src = Join-Path $From $acc
        if (-not (Test-Path -LiteralPath $src -PathType Container)) { continue }
        foreach ($org in @(Get-ChildItem -LiteralPath $src -Directory -Force -ErrorAction SilentlyContinue)) {
            $dstOrg = Join-Path (Join-Path $To $acc) $org.Name
            foreach ($f in @(Get-ChildItem -LiteralPath $org.FullName -File -Force -ErrorAction SilentlyContinue)) {
                if ($f.Name -like '*.claude-clone-tmp') { continue }
                $dst = Join-Path $dstOrg $f.Name
                $exists = Test-Path -LiteralPath $dst -PathType Leaf
                $kind = 'other'
                if ($f.Name -match '^local_(.+)\.json$') {
                    if (Test-Path -LiteralPath (Join-Path $dstOrg "deleted_$($Matches[1])")) { continue }
                    if ($exists) {
                        if (-not $AllowUpdate) { continue }
                        if ($f.LastWriteTimeUtc -le (Get-Item -LiteralPath $dst -Force).LastWriteTimeUtc.AddSeconds(2)) { continue }
                        $kind = 'update'
                    } else { $kind = 'add' }
                } elseif ($f.Name -match '^deleted_(.+)$') {
                    if ($exists -or (Test-Path -LiteralPath (Join-Path $dstOrg "local_$($Matches[1]).json"))) { continue }
                } elseif ($exists) { continue }
                $done = $true
                if (-not $WhatIf) { $done = Copy-SessionFile $f.FullName $dst }
                if (-not $done) { $r.Skipped++ }
                elseif ($kind -eq 'add') { $r.Added++ }
                elseif ($kind -eq 'update') { $r.Updated++ }
            }
            # sub folders (backlog, ...) only get files they do not have; "waiting-input" belongs to one window
            foreach ($sub in @(Get-ChildItem -LiteralPath $org.FullName -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'waiting-input' })) {
                foreach ($f in @(Get-ChildItem -LiteralPath $sub.FullName -File -Force -Recurse -ErrorAction SilentlyContinue)) {
                    $dst = Join-Path $dstOrg $f.FullName.Substring($org.FullName.Length).TrimStart('\')
                    if (-not $WhatIf -and -not (Test-Path -LiteralPath $dst)) { [void](Copy-SessionFile $f.FullName $dst) }
                }
            }
        }
    }
    return $r
}

# Syncs the session list of every account signed in to a clone with the main profile.
# pull: main -> clone. both: also clone -> main, for accounts the main profile uses as well.
# A profile whose app is running only gets new entries, nothing in it is overwritten.
function Sync-CloneSessions([string]$Dir, [string]$MainData, [string]$Mode, [bool]$CloneRunning, [bool]$MainRunning, [bool]$WhatIf) {
    $res = [pscustomobject]@{ Accounts = @(); Pulled = 0; PullUpdated = 0; Pushed = 0; PushUpdated = 0; Skipped = 0; Note = '' }
    if ($Mode -notin @('pull', 'both') -or -not $MainData -or (Test-SamePath $Dir $MainData)) { return $res }
    $cloneRoot = Join-Path $Dir 'claude-code-sessions'
    $li = Get-LinkInfo $cloneRoot
    if ($li -and $li.IsLink) { $res.Note = 'the session folder is still a link'; return $res }
    $mainRoot = Join-Path $MainData 'claude-code-sessions'
    $res.Accounts = @(Get-ProfileAccounts $Dir)
    if (-not $res.Accounts.Count) { return $res }
    $a = Sync-SessionRoot $mainRoot $cloneRoot $res.Accounts (-not $CloneRunning) $WhatIf
    $res.Pulled = $a.Added; $res.PullUpdated = $a.Updated; $res.Skipped += $a.Skipped
    if ($Mode -eq 'both') {
        $shared = @($res.Accounts | Where-Object { Test-Path -LiteralPath (Join-Path $mainRoot $_) -PathType Container })
        if ($shared.Count) {
            $b = Sync-SessionRoot $cloneRoot $mainRoot $shared (-not $MainRunning) $WhatIf
            $res.Pushed = $b.Added; $res.PushUpdated = $b.Updated; $res.Skipped += $b.Skipped
        }
    }
    return $res
}

function Format-SyncResult($S) {
    if ($S.Note) { return "sessions: not synced, $($S.Note)" }
    if (-not @($S.Accounts).Count) { return 'sessions: no account signed in yet, nothing to sync' }
    $parts = @()
    if ($S.Pulled) { $parts += "$($S.Pulled) new from main" }
    if ($S.PullUpdated) { $parts += "$($S.PullUpdated) updated from main" }
    if ($S.Pushed) { $parts += "$($S.Pushed) new to main" }
    if ($S.PushUpdated) { $parts += "$($S.PushUpdated) updated in main" }
    if ($S.Skipped) { $parts += "$($S.Skipped) busy (next time)" }
    if (-not $parts.Count) { return 'sessions: in sync with the main profile' }
    return 'sessions: ' + ($parts -join ', ')
}

# Repairs the links inside a clone profile. Returns what was (or with $WhatIf: would be) done.
#   claude-code-sessions  must be a folder of its own. Older clones linked it to the main profile;
#                         that link broke when Claude moved its data folder.
#   claude-code           optional link to the Claude Code runtime of the main profile; re-pointed when
#                         the runtime moved, removed when it is gone (Claude then downloads its own).
#   anything else         dead links are removed.
function Repair-ProfileLinks([string]$Dir, [string]$MainData, [bool]$ShareRuntime, [bool]$WhatIf) {
    $acts = @()
    $runtime = ''
    if ($MainData -and (Test-Path -LiteralPath (Join-Path $MainData 'claude-code') -PathType Container)) { $runtime = Join-Path $MainData 'claude-code' }
    foreach ($item in @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue)) {
        $li = Get-LinkInfo $item.FullName
        if (-not $li -or -not $li.IsLink) { continue }
        if ($item.Name -eq 'claude-code-sessions') {
            if ($WhatIf -and $li.Dead) { $acts += "claude-code-sessions is a dead link to $($li.Target) - the session list looks empty"; continue }
            if ($WhatIf) { $acts += "claude-code-sessions is a link to $($li.Target) - it breaks when Claude moves its data again"; continue }
            $state = 'link'
            if ($li.Dead) { $state = 'dead link' }
            $acts += "claude-code-sessions: $state to $($li.Target) replaced by a folder of its own"
            if (-not (Remove-Link $item.FullName)) { throw "cannot remove the link $($item.FullName)" }
            New-Item -ItemType Directory -Force $item.FullName | Out-Null
            $acc = Get-ActiveAccount $Dir
            if (-not $li.Dead -and $acc) { [void](Sync-SessionRoot $li.Target $item.FullName @($acc) $true $false) }
        } elseif ($item.Name -eq 'claude-code') {
            if (-not $li.Dead -and (-not $runtime -or (Test-SamePath $li.Target $runtime))) { continue }
            $state = 'an outdated link'
            if ($li.Dead) { $state = 'a dead link' }
            if ($WhatIf) { $acts += "claude-code (Claude Code runtime) is $state to $($li.Target) - old sessions cannot be resumed"; continue }
            if ($ShareRuntime -and $runtime) { $acts += "claude-code: link re-pointed from $($li.Target) to $runtime" }
            else { $acts += "claude-code: dead link to $($li.Target) removed (Claude downloads its own copy)" }
            if (-not (Remove-Link $item.FullName)) { throw "cannot remove the link $($item.FullName)" }
            if ($ShareRuntime -and $runtime) { New-Item -ItemType Junction -Path $item.FullName -Target $runtime -ErrorAction Stop | Out-Null }
        } elseif ($li.Dead) {
            if ($WhatIf) { $acts += "$($item.Name) is a dead link to $($li.Target)"; continue }
            $acts += "$($item.Name): dead link to $($li.Target) removed"
            if (-not (Remove-Link $item.FullName)) { throw "cannot remove the link $($item.FullName)" }
        }
    }
    $rt = Join-Path $Dir 'claude-code'
    if ($ShareRuntime -and $runtime -and -not (Get-Item -LiteralPath $rt -Force -ErrorAction SilentlyContinue)) {
        if ($WhatIf) { $acts += 'claude-code (Claude Code runtime) is not linked to the main profile yet' }
        else {
            New-Item -ItemType Junction -Path $rt -Target $runtime -ErrorAction Stop | Out-Null
            $acts += "claude-code: linked to the runtime of the main profile ($runtime)"
        }
    }
    return $acts
}

# One lock for everything that changes profiles (launchers started twice, -Repair, -Sync)
function Enter-CloneLock {
    try {
        $m = New-Object Threading.Mutex($false, 'Local\claude-clone')
        try { [void]$m.WaitOne(20000) } catch [Threading.AbandonedMutexException] { }
        return $m
    } catch { return $null }
}
function Exit-CloneLock($M) { if ($M) { try { $M.ReleaseMutex() } catch { }; try { $M.Dispose() } catch { } } }

function Write-CloneLog([string]$Name, [string[]]$Lines) {
    try {
        $dir = Join-Path $env:USERPROFILE '.claude-clone\logs'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        $f = Join-Path $dir "$Name.log"
        if ((Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f).Length -gt 262144) { Move-Item -LiteralPath $f "$f.old" -Force }
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $text = (@($Lines | Where-Object { $_ }) | ForEach-Object { "$stamp  $_" }) -join "`r`n"
        [IO.File]::AppendAllText($f, $text + "`r`n", (New-Object Text.UTF8Encoding $false))
    } catch { }
}

function Read-CloneManifest {
    $f = Join-Path $env:USERPROFILE '.claude-clone\clones.json'
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    try {
        $raw = [IO.File]::ReadAllText($f)
        if (-not $raw.Trim()) { return @() }
        return @($raw | ConvertFrom-Json | ForEach-Object { $_ })
    } catch { return @() }
}

function Show-LauncherMessage([string]$Text) {
    try { [void](New-Object -ComObject WScript.Shell).Popup($Text, 60, 'claude-clone', 0x30) } catch { Write-Warning $Text }
}

function Show-LauncherResult($R, [bool]$CheckOnly) {
    if ($CheckOnly) {
        foreach ($n in @($R.Notes)) { Write-Host "  - $n" }
        if ($R.Problem) { Write-Host "  [x] $($R.Problem)" -ForegroundColor Red }
        if ($R.Warning) { Write-Host "  [!] $($R.Warning)" -ForegroundColor Yellow }
        return
    }
    $msg = @($R.Problem, $R.Warning) | Where-Object { $_ }
    if ($msg) { Show-LauncherMessage ($msg -join "`n`n") }
}

# What a clone launcher does: check the profile, repair links, sync sessions, start Claude.
# A profile whose window is already open is never touched.
function Invoke-CloneLauncher([string]$Name, [string]$Dir, [string]$SessionSync, [bool]$ShareRuntime, [bool]$CheckOnly) {
    $r = [pscustomobject]@{ Started = $false; Notes = @(); Problem = ''; Warning = '' }
    $d = Resolve-ClaudeDesktop
    if (-not $d) { $r.Problem = 'Claude Desktop was not found on this computer.' }
    elseif (-not (Test-Path -LiteralPath $Dir -PathType Container)) { $r.Problem = "The profile folder of '$Name' is missing:`n$Dir`n`nRun claude-clone.ps1 -Doctor for details." }
    if ($r.Problem) { Write-CloneLog $Name @("not started: $($r.Problem)"); return $r }
    $lock = Enter-CloneLock
    try {
        $procs = @(Get-DesktopProcesses $d)
        $main = Resolve-ClaudeMainData $d
        $mainRunning = Test-MainRunning $procs
        if (Test-ProfileRunning $Dir $procs) { $r.Notes += 'already running, profile left as it is' }
        elseif ($main -and (Test-SamePath $Dir $main)) { $r.Notes += 'this is the main profile, nothing to repair' }
        else {
            $r.Notes += @(Repair-ProfileLinks $Dir $main $ShareRuntime $CheckOnly)
            if ($SessionSync -in @('pull', 'both')) {
                if ($main) { $r.Notes += Format-SyncResult (Sync-CloneSessions $Dir $main $SessionSync $false $mainRunning $CheckOnly) }
                else { $r.Notes += 'sessions: main profile not found, not synced' }
            }
        }
        if ($mainRunning -and $main) {
            $acc = Get-ActiveAccount $main
            if ($acc -and (@(Get-ProfileAccounts $Dir) -contains $acc)) {
                $r.Warning = "The account of '$Name' is also open in the main Claude window. Each window shows the sessions it knew when it started; the other window's new sessions appear after a restart."
            }
        }
    } catch {
        $r.Problem = "claude-clone could not prepare the profile '$Name': $($_.Exception.Message)`n`nClaude starts anyway. Run claude-clone.ps1 -Doctor to check the profile."
    } finally { Exit-CloneLock $lock }
    if (-not $CheckOnly) {
        Start-Process -FilePath $d.Exe -ArgumentList ('--user-data-dir="' + $Dir.TrimEnd('\') + '"')
        $r.Started = $true
    }
    $head = 'start'
    if ($CheckOnly) { $head = 'check only' }
    Write-CloneLog $Name (@($head) + @($r.Notes) + @($r.Problem, $r.Warning))
    return $r
}

# The main launcher brings the sessions of clones in "both" mode into the main profile while it is closed
function Invoke-MainLauncher([bool]$CheckOnly) {
    $r = [pscustomobject]@{ Started = $false; Notes = @(); Problem = ''; Warning = '' }
    $d = Resolve-ClaudeDesktop
    if (-not $d) { $r.Problem = 'Claude Desktop was not found on this computer.'; return $r }
    $lock = Enter-CloneLock
    try {
        $procs = @(Get-DesktopProcesses $d)
        $main = Resolve-ClaudeMainData $d
        if (Test-MainRunning $procs) { $r.Notes += 'already running' }
        elseif ($main) {
            foreach ($c in @(Read-CloneManifest)) {
                if ("$($c.product)" -ne 'desktop' -or "$($c.sync)" -ne 'both' -or -not (Test-Path -LiteralPath "$($c.dir)" -PathType Container)) { continue }
                $s = Sync-CloneSessions "$($c.dir)" $main 'both' (Test-ProfileRunning "$($c.dir)" $procs) $false $CheckOnly
                $r.Notes += "$($c.name): $(Format-SyncResult $s)"
            }
        }
    } catch { $r.Problem = "claude-clone could not sync the session lists: $($_.Exception.Message)" }
    finally { Exit-CloneLock $lock }
    if (-not $CheckOnly) { Start-Process -FilePath $d.Exe; $r.Started = $true }
    Write-CloneLog 'main' (@('start') + @($r.Notes) + @($r.Problem))
    return $r
}

# Waits until the clone's window is closed (Claude restarting itself for an update counts as still
# open), then gives the main profile the sessions created in it. One watcher per clone; it waits on
# the process itself, nothing is polled while Claude runs.
function Wait-CloneAndSync([string]$Name, [string]$Dir) {
    $m = $null
    $owned = $false
    try {
        $m = New-Object Threading.Mutex($false, ('Local\claude-clone-watch-' + $Name))
        try { $owned = $m.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
    } catch { }
    if (-not $owned) { if ($m) { $m.Dispose() }; return }
    try {
        $d = Resolve-ClaudeDesktop
        $seen = $false
        $deadline = (Get-Date).AddSeconds(60)
        while ($true) {
            $p = @(Get-DesktopProcesses $d | Where-Object { Test-SamePath $_.UserDataDir $Dir })
            if ($p.Count) {
                $seen = $true
                try { Wait-Process -Id $p[0].Id -ErrorAction Stop } catch { }
                Start-Sleep -Seconds 5
                continue
            }
            if ($seen -or (Get-Date) -gt $deadline) { break }
            Start-Sleep -Seconds 2
        }
        if (-not $seen) { return }
        $lock = Enter-CloneLock
        try {
            $procs = @(Get-DesktopProcesses $d)
            $main = Resolve-ClaudeMainData $d
            if ($main -and -not (Test-ProfileRunning $Dir $procs)) {
                Write-CloneLog $Name @("closed - $(Format-SyncResult (Sync-CloneSessions $Dir $main 'both' $false (Test-MainRunning $procs) $false))")
            }
        } finally { Exit-CloneLock $lock }
    } catch { Write-CloneLog $Name @("sync after closing failed: $($_.Exception.Message)") }
    finally { try { $m.ReleaseMutex() } catch { }; $m.Dispose() }
}
'@

$CodeResolver = @'
function Resolve-ClaudeCode {
    $cmd = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    foreach ($c in @((Join-Path $env:USERPROFILE '.local\bin\claude.exe'), (Join-Path $env:APPDATA 'npm\claude.cmd'))) {
        if (Test-Path $c) { return $c }
    }
    # Claude Desktop ships its own copy, in whichever data folder it currently uses
    $roots = @(Join-Path $env:APPDATA 'Claude\claude-code')
    $roots += @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Claude-Data') -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'claude-code' })
    $roots += @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'LocalCache\Roaming\Claude\claude-code' })
    $bundled = $roots | Where-Object { Test-Path $_ } | ForEach-Object { Get-ChildItem $_ -Recurse -Filter claude.exe -ErrorAction SilentlyContinue } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($bundled) { return $bundled.FullName }
    return $null
}
'@

. ([scriptblock]::Create($RuntimeLib))
. ([scriptblock]::Create($CodeResolver))

# Fingerprint of the runtime. Launchers carry it, so one with an older runtime is noticed even when
# the version number did not change. Line endings are normalized (git may check out either).
$RuntimeId = -join @([Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($RuntimeLib.Replace("`r`n", "`n"))) |
    Select-Object -First 5 | ForEach-Object { $_.ToString('x2') })

$script:DeskLoaded = $false
$script:DeskCache = $null
function Get-Desk {
    if (-not $script:DeskLoaded) { $script:DeskCache = Resolve-ClaudeDesktop; $script:DeskLoaded = $true }
    return $script:DeskCache
}

# ---------------------------------------------------------------------------------------------
# Paths and state
# ---------------------------------------------------------------------------------------------
$StateDir = Join-Path $env:USERPROFILE '.claude-clone'
$Manifest = Join-Path $StateDir 'clones.json'
$AccountsFile = Join-Path $StateDir 'accounts.json'
$BinDir = Join-Path $StateDir 'bin'
$DefaultProfileBase = Join-Path $StateDir 'profiles'
$MainCodeConfig = Join-Path $env:USERPROFILE '.claude'
# GetFolderPath returns '' for a known folder that does not exist
$DesktopDir = $env:CLAUDE_CLONE_DESKTOP_DIR
if (-not $DesktopDir) { $DesktopDir = [Environment]::GetFolderPath('Desktop') }
if (-not $DesktopDir) { $DesktopDir = Join-Path $env:USERPROFILE 'Desktop' }
$StartMenuDir = $env:CLAUDE_CLONE_STARTMENU_DIR
if (-not $StartMenuDir) {
    $programs = [Environment]::GetFolderPath('Programs')
    if (-not $programs) { $programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs' }
    $StartMenuDir = Join-Path $programs 'Claude Clones'
}

function Get-Clones {
    if (-not (Test-Path -LiteralPath $Manifest)) { return @() }
    $raw = [IO.File]::ReadAllText($Manifest)
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    try { return @($raw | ConvertFrom-Json | ForEach-Object { $_ }) }
    catch {
        $bad = "$Manifest.broken-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $Manifest $bad -Force
        Warn "The clone list could not be read (copy kept as $bad). Clones are looked up on disk instead."
        return @()
    }
}

# Written to a temp file first; the previous version is kept as clones.json.bak
function Save-Clones($Clones) {
    New-Item -ItemType Directory -Force $StateDir | Out-Null
    $json = ConvertTo-Json -InputObject @($Clones) -Depth 5
    $tmp = "$Manifest.tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))
    if (Test-Path -LiteralPath $Manifest) { Copy-Item -LiteralPath $Manifest "$Manifest.bak" -Force }
    Move-Item -LiteralPath $tmp $Manifest -Force
}

# Fills in fields that older versions did not write. Clones from before 1.3.0 that linked the main
# profile keep their sessions shared, now through sync instead of a link.
function ConvertTo-Clone($c) {
    $p = $c.PSObject.Properties
    $o = [pscustomobject]@{
        name = "$($c.name)"; product = "$($c.product)"; dir = "$($c.dir)"; launcher = "$($c.launcher)"
        shortcuts = @($c.shortcuts | Where-Object { $_ } | ForEach-Object { "$_" })
        label = ''; sync = ''; shareRuntime = $false; badge = $true; syncOnExit = $true
    }
    if ($p['label']) { $o.label = "$($c.label)" }
    if ($p['badge']) { $o.badge = [bool]$c.badge }
    if ($p['syncOnExit']) { $o.syncOnExit = [bool]$c.syncOnExit }
    if ($o.product -eq 'desktop') {
        $legacyShared = $false
        foreach ($x in @('claude-code-sessions', 'claude-code')) {
            $li = Get-LinkInfo (Join-Path $o.dir $x)
            if ($li -and $li.IsLink) { $legacyShared = $true }
        }
        $o.sync = 'off'
        if ($p['sync'] -and "$($c.sync)" -in @('both', 'pull', 'off')) { $o.sync = "$($c.sync)" }
        elseif ($legacyShared) { $o.sync = 'both' }
        if ($p['shareRuntime']) { $o.shareRuntime = [bool]$c.shareRuntime }
        else { $li = Get-LinkInfo (Join-Path $o.dir 'claude-code'); $o.shareRuntime = [bool]($li -and $li.IsLink) }
    }
    return $o
}

function Get-AccountNames {
    $h = @{}
    if (Test-Path -LiteralPath $AccountsFile) {
        try { foreach ($p in ([IO.File]::ReadAllText($AccountsFile) | ConvertFrom-Json).PSObject.Properties) { $h[$p.Name] = "$($p.Value)" } } catch { }
    }
    return $h
}

function Save-AccountNames($H) {
    New-Item -ItemType Directory -Force $StateDir | Out-Null
    $o = [ordered]@{}
    foreach ($k in @($H.Keys | Sort-Object)) { $o[$k] = $H[$k] }
    [IO.File]::WriteAllText($AccountsFile, (ConvertTo-Json ([pscustomobject]$o)), (New-Object Text.UTF8Encoding $false))
}
$script:AccountNames = Get-AccountNames

$script:AccountCache = @{}
function Get-CloneAccount($c) {
    if ($c.product -ne 'desktop') { return '' }
    if (-not $script:AccountCache.ContainsKey($c.dir)) { $script:AccountCache[$c.dir] = Get-ActiveAccount $c.dir }
    return $script:AccountCache[$c.dir]
}

# Name shown for an account: the name you gave it, else the clone it is signed in to, else its id
function Get-AccountLabel([string]$Id, $Clones) {
    if (-not $Id) { return '-' }
    if ($script:AccountNames.ContainsKey($Id)) { return $script:AccountNames[$Id] }
    $c = @($Clones | Where-Object { (Get-CloneAccount $_) -eq $Id }) | Select-Object -First 1
    if ($c) { if ($c.label) { return $c.label }; return $c.name }
    return $Id.Substring(0, 8)
}

function Test-UnderPath([string]$Child, [string]$Root) {
    if (-not $Child -or -not $Root) { return $false }
    return ($Child.TrimEnd('\') + '\').StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Test-CloudPath([string]$P) {
    foreach ($v in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial)) { if (Test-UnderPath $P $v) { return $true } }
    return ($P -match '(?i)\\(OneDrive[^\\]*|Dropbox|Google Drive|My Drive|iCloud ?Drive|iCloudDrive|Nextcloud|ownCloud|Box|pCloud Drive|MEGA)(\\|$)')
}

# The Microsoft Store build may redirect what it writes into AppData to its private package folder
function Test-VirtualizedPath([string]$P) {
    $d = Get-Desk
    return ($d -and $d.Kind -eq 'msix' -and ((Test-UnderPath $P $env:APPDATA) -or (Test-UnderPath $P $env:LOCALAPPDATA)))
}

function Confirm-ProfileBase([string]$Base, [bool]$ForDesktop) {
    if (Test-CloudPath $Base) {
        Warn "$Base is in a cloud-synced folder (OneDrive, Dropbox, ...). Claude writes its databases there all the time; the sync client can damage them."
        if (-not (AskYesNo 'Use it anyway?' $false)) { return $false }
    }
    if ($ForDesktop -and (Test-VirtualizedPath $Base)) {
        Warn "$Base is inside AppData. The Microsoft Store version of Claude may redirect a profile there into its package folder."
        if (-not (AskYesNo 'Use it anyway?' $false)) { return $false }
    }
    return $true
}

function Resolve-FullPath([string]$P) { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($P) }

# ---------------------------------------------------------------------------------------------
# Icons: a real .ico from the app's own logo (PNG-in-ICO), optionally with a colored letter so
# clones are easy to tell apart on the Desktop
# ---------------------------------------------------------------------------------------------
function Write-PngIco([byte[]]$Png, [string]$Ico) {
    $w = ([int]$Png[16] -shl 24) -bor ([int]$Png[17] -shl 16) -bor ([int]$Png[18] -shl 8) -bor [int]$Png[19]
    $h = ([int]$Png[20] -shl 24) -bor ([int]$Png[21] -shl 16) -bor ([int]$Png[22] -shl 8) -bor [int]$Png[23]
    $ms = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter($ms)
    $bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]1)
    $bw.Write([byte]($(if ($w -ge 256) { 0 } else { $w })))
    $bw.Write([byte]($(if ($h -ge 256) { 0 } else { $h })))
    $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([UInt16]1); $bw.Write([UInt16]32)
    $bw.Write([UInt32]$Png.Length); $bw.Write([UInt32]22)
    $bw.Write($Png)
    $bw.Flush()
    [IO.File]::WriteAllBytes($Ico, $ms.ToArray())
}

function Get-ClaudePng {
    $d = Get-Desk
    if (-not $d) { return $null }
    $png = Get-ChildItem (Join-Path $d.Root 'assets') -Filter 'Square44x44Logo.targetsize-256*.png' -ErrorAction SilentlyContinue |
        Sort-Object { $_.Name -notlike '*unplated*' } | Select-Object -First 1
    if (-not $png) {
        $png = Get-ChildItem $d.Root -Recurse -Filter '*Logo*.png' -ErrorAction SilentlyContinue |
            Sort-Object Length -Descending | Select-Object -First 1
    }
    return $png
}

function Get-ClaudeIcon([string]$Target) {
    $d = Get-Desk
    if (-not $d) { return $null }
    $png = Get-ClaudePng
    if ($png) { Write-PngIco ([IO.File]::ReadAllBytes($png.FullName)) $Target; return $Target }
    $ico = Get-ChildItem $d.Root -Filter '*.ico' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ico) { Copy-Item $ico.FullName $Target -Force; return $Target }
    try {
        Add-Type -AssemblyName System.Drawing
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($d.Exe)
        $fs = [IO.File]::Create($Target); $icon.Save($fs); $fs.Close()
        return $Target
    } catch { }
    return $null
}

$BadgeColors = @('#2563EB', '#16A34A', '#9333EA', '#DB2777', '#0891B2', '#CA8A04', '#DC2626', '#4B5563')
function Get-BadgeColor([string]$Name) {
    $sum = 0
    foreach ($ch in $Name.ToCharArray()) { $sum += [int]$ch }
    return $BadgeColors[$sum % $BadgeColors.Count]
}

function New-BadgePng([string]$Png, [string]$Letter, [string]$Color) {
    Add-Type -AssemblyName System.Drawing
    $src = [Drawing.Image]::FromFile($Png)
    try {
        $s = 256
        $bmp = New-Object Drawing.Bitmap -ArgumentList $s, $s, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $g.InterpolationMode = 'HighQualityBicubic'
        $g.TextRenderingHint = 'AntiAliasGridFit'
        $g.DrawImage($src, 0, 0, $s, $s)
        $r = 136; $x = $s - $r - 6; $y = $s - $r - 6
        $g.FillEllipse((New-Object Drawing.SolidBrush -ArgumentList ([Drawing.ColorTranslator]::FromHtml($Color))), $x, $y, $r, $r)
        $g.DrawEllipse((New-Object Drawing.Pen -ArgumentList ([Drawing.Color]::White), 10), $x, $y, $r, $r)
        $font = New-Object Drawing.Font -ArgumentList 'Segoe UI', 84, ([Drawing.FontStyle]::Bold), ([Drawing.GraphicsUnit]::Pixel)
        $sf = New-Object Drawing.StringFormat
        $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
        $g.DrawString($Letter, $font, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF -ArgumentList $x, ($y + 4), $r, $r), $sf)
        $g.Dispose()
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        return , $ms.ToArray()
    } finally { $src.Dispose() }
}

function Write-CloneIcon($c) {
    $ico = Join-Path $c.dir 'claude.ico'
    if ($c.badge) {
        $png = Get-ClaudePng
        $text = $c.label
        if (-not $text) { $text = $c.name }
        $letter = ($text -replace '[^A-Za-z0-9]', '')
        if ($png -and $letter) {
            try { Write-PngIco (New-BadgePng $png.FullName $letter.Substring(0, 1).ToUpper() (Get-BadgeColor $c.name)) $ico; return $ico } catch { }
        }
    }
    return Get-ClaudeIcon $ico
}

# ---------------------------------------------------------------------------------------------
# Launchers and shortcuts (one place that writes them, used by create, repair, move and set)
# ---------------------------------------------------------------------------------------------
function Write-Utf8([string]$File, [string]$Text) {
    [IO.File]::WriteAllText($File, $Text, (New-Object Text.UTF8Encoding $false))
}

# .ps1 files get a BOM: without it Windows PowerShell 5.1 misreads paths with umlauts
function Write-Utf8Bom([string]$File, [string]$Text) {
    [IO.File]::WriteAllText($File, $Text, (New-Object Text.UTF8Encoding $true))
}

function New-Shortcut([string]$File, [string]$Script, [string]$Icon, [string]$Description, [switch]$Console) {
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($File)
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if ($Console) {
        $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
        if ($wt) {
            $lnk.TargetPath = $wt.Source
            $lnk.Arguments = "powershell.exe -NoLogo -NoExit -ExecutionPolicy Bypass -File `"$Script`""
        } else {
            $lnk.TargetPath = $ps
            $lnk.Arguments = "-NoLogo -NoExit -ExecutionPolicy Bypass -File `"$Script`""
        }
        $lnk.WindowStyle = 1
    } else {
        $lnk.TargetPath = $ps
        $lnk.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script`""
        $lnk.WindowStyle = 7
    }
    if ($Icon -and (Test-Path $Icon)) { $lnk.IconLocation = "$Icon,0" }
    $lnk.Description = $Description
    $lnk.WorkingDirectory = $env:USERPROFILE
    $lnk.Save()
}

function Get-ShortcutTitle($c) {
    if ($c.product -eq 'desktop') { return "Claude ($($c.name))" }
    return "Claude Code ($($c.name))"
}

function Get-StandardShortcuts($c) {
    $t = Get-ShortcutTitle $c
    $l = @(Join-Path $DesktopDir "$t.lnk")
    if ($c.product -eq 'desktop') { $l += Join-Path $StartMenuDir "$t.lnk" }
    return $l
}

# Clones created with -NoShortcuts have none and get none
function Get-ExpectedShortcuts($c) {
    if (-not @($c.shortcuts | Where-Object { $_ }).Count) { return @() }
    return Get-StandardShortcuts $c
}

function Test-ShortcutTarget([string]$Lnk, [string]$Script) {
    if (-not (Test-Path -LiteralPath $Lnk)) { return $false }
    try {
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut($Lnk)
        return ($s.Arguments.IndexOf($Script, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    } catch { return $false }
}

function Write-Shortcuts($c) {
    $ps1 = Join-Path $c.dir 'launch.ps1'
    $icon = Write-CloneIcon $c
    $links = @()
    foreach ($l in @(Get-StandardShortcuts $c)) {
        New-Item -ItemType Directory -Force (Split-Path $l) | Out-Null
        if ($c.product -eq 'desktop') { New-Shortcut $l $ps1 $icon "Claude Desktop - profile $($c.name) (claude-clone)" }
        else { New-Shortcut $l $ps1 $icon "Claude Code - profile $($c.name) (claude-clone)" -Console }
        $links += $l
    }
    $c.shortcuts = $links
}

function Write-Launcher($c) {
    $ps1 = Join-Path $c.dir 'launch.ps1'
    if ($c.product -eq 'desktop') {
        $share = '$false'
        if ($c.shareRuntime) { $share = '$true' }
        $watch = '$false'
        if ($c.syncOnExit -and $c.sync -eq 'both') { $watch = '$true' }
        Write-Utf8Bom $ps1 (@"
# claude-clone $Version - Claude Desktop, profile '$($c.name)'
# runtime $RuntimeId
# Written by claude-clone. Before Claude starts, this launcher repairs broken links in the profile and
# syncs the session list of the signed-in account with the main profile. With "sync when closed" it
# then waits in the background until the window is closed and syncs once more.
# Log: ~\.claude-clone\logs\$($c.name).log
#   launch.ps1 -CheckOnly    shows what it would do, without changing anything or starting Claude
#   launch.ps1 -WatchOnly    only waits for the window to close and syncs (used by the dashboard)
param([switch]`$CheckOnly, [switch]`$WatchOnly)
`$ErrorActionPreference = 'Continue'
$RuntimeLib
`$cloneName = '$($c.name)'
`$cloneDir = $(Quote-PS $c.dir)
if (-not `$WatchOnly) {
    `$result = Invoke-CloneLauncher -Name `$cloneName -Dir `$cloneDir -SessionSync '$($c.sync)' -ShareRuntime $share -CheckOnly ([bool]`$CheckOnly)
    Show-LauncherResult `$result ([bool]`$CheckOnly)
    if (-not `$result.Started) { exit }
}
if ($watch) { Wait-CloneAndSync `$cloneName `$cloneDir }
"@)
        $c.launcher = $ps1
    } else {
        Write-Utf8Bom $ps1 (@"
# claude-clone $Version - Claude Code, profile '$($c.name)'
$CodeResolver
`$exe = Resolve-ClaudeCode
if (-not `$exe) { Write-Error 'Claude Code not found'; exit 1 }
`$env:CLAUDE_CONFIG_DIR = $(Quote-PS $c.dir)
& `$exe @args
exit `$LASTEXITCODE
"@)
        New-Item -ItemType Directory -Force $BinDir | Out-Null
        $cmd = Join-Path $BinDir "claude-$($c.name).cmd"
        Write-Utf8 $cmd "@echo off`r`npowershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$ps1`" %*`r`n"
        $c.launcher = $cmd
    }
}

function New-MainShortcuts([bool]$Desktop, [bool]$Code) {
    $links = @()
    New-Item -ItemType Directory -Force $StateDir | Out-Null
    if ($Desktop) {
        $launcher = Write-MainLauncher
        $icon = Get-ClaudeIcon (Join-Path $StateDir 'claude.ico')
        $lnk = Join-Path $DesktopDir 'Claude (main).lnk'
        New-Shortcut $lnk $launcher $icon 'Claude Desktop - main profile (claude-clone)'
        $links += $lnk
        Ok "shortcut: Desktop ('Claude (main)')"
    }
    if ($Code) {
        $launcher = Join-Path $StateDir 'launch-main-code.ps1'
        Write-Utf8Bom $launcher (@"
# claude-clone $Version - Claude Code, main profile
$CodeResolver
`$exe = Resolve-ClaudeCode
if (-not `$exe) { Write-Error 'Claude Code not found'; exit 1 }
& `$exe @args
exit `$LASTEXITCODE
"@)
        $icon = Get-ClaudeIcon (Join-Path $StateDir 'claude.ico')
        $lnk = Join-Path $DesktopDir 'Claude Code (main).lnk'
        New-Shortcut $lnk $launcher $icon 'Claude Code - main profile (claude-clone)' -Console
        $links += $lnk
        Ok "shortcut: Desktop ('Claude Code (main)')"
    }
    return $links
}

function Write-MainLauncher {
    New-Item -ItemType Directory -Force $StateDir | Out-Null
    $launcher = Join-Path $StateDir 'launch-main-desktop.ps1'
    Write-Utf8Bom $launcher (@"
# claude-clone $Version - Claude Desktop, main profile
# runtime $RuntimeId
# Before Claude starts, new sessions of clones in "both" sync mode are copied into the main profile.
param([switch]`$CheckOnly)
`$ErrorActionPreference = 'Continue'
$RuntimeLib
`$result = Invoke-MainLauncher -CheckOnly ([bool]`$CheckOnly)
Show-LauncherResult `$result ([bool]`$CheckOnly)
"@)
    return $launcher
}

# ---------------------------------------------------------------------------------------------
# Folder helpers that never follow links into the main profile
# ---------------------------------------------------------------------------------------------
function Remove-Links([string]$Dir) {
    foreach ($item in @(Get-ChildItem -LiteralPath $Dir -Force -Directory -ErrorAction SilentlyContinue)) {
        # OneDrive placeholders are reparse points too, but not links: those are walked into, not removed
        if ("$($item.LinkType)" -in @('Junction', 'SymbolicLink')) {
            if (-not (Remove-Link $item.FullName)) { throw "cannot remove the link $($item.FullName)" }
        } else { Remove-Links $item.FullName }
    }
}

function Remove-FolderSafely([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { return $true }
    # a link that cannot be removed stops everything: deleting through it would reach the main profile
    try { Remove-Links $Dir } catch { Warn "$($_.Exception.Message) - nothing deleted"; return $false }
    # rd with the \\?\ prefix also removes paths longer than 260 characters
    $full = (Resolve-Path -LiteralPath $Dir).ProviderPath
    try { cmd /c "rd /s /q `"\\?\$full`"" 2>$null | Out-Null } catch { }
    if (Test-Path -LiteralPath $Dir) { try { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction Stop } catch { } }
    if (Test-Path -LiteralPath $Dir) { Warn "Could not delete everything in $Dir"; return $false }
    return $true
}

# File count and size without walking into links
function Get-TreeStats([string]$Dir) {
    $files = 0
    [long]$bytes = 0
    $stack = New-Object Collections.Stack
    $stack.Push($Dir)
    while ($stack.Count) {
        foreach ($i in @(Get-ChildItem -LiteralPath $stack.Pop() -Force -ErrorAction SilentlyContinue)) {
            if ($i.PSIsContainer) { if ("$($i.LinkType)" -notin @('Junction', 'SymbolicLink')) { $stack.Push($i.FullName) } }
            else { $files++; $bytes += $i.Length }
        }
    }
    return [pscustomobject]@{ Files = $files; Bytes = $bytes }
}

# Zip of a clone's session list in ~\.claude-clone\backups (the newest 5 per clone are kept)
function Backup-Sessions($c) {
    $src = Join-Path $c.dir 'claude-code-sessions'
    $li = Get-LinkInfo $src
    if (-not $li -or $li.IsLink) { return '' }
    $dir = Join-Path $StateDir 'backups'
    New-Item -ItemType Directory -Force $dir | Out-Null
    $zip = Join-Path $dir ('{0}-sessions-{1}.zip' -f $c.name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    # file by file with shared reads: works while Claude has the files open
    Add-Type -AssemblyName System.IO.Compression
    $fs = [IO.File]::Open($zip, [IO.FileMode]::CreateNew)
    try {
        $za = New-Object IO.Compression.ZipArchive -ArgumentList $fs, ([IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($f in @(Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                if ($f.Name -like '*.claude-clone-tmp') { continue }
                try { $bytes = Read-SharedBytes $f.FullName } catch { continue }
                $e = $za.CreateEntry($f.FullName.Substring($src.Length).TrimStart('\').Replace('\', '/'))
                $e.LastWriteTime = $f.LastWriteTime
                $s = $e.Open()
                try { $s.Write($bytes, 0, $bytes.Length) } finally { $s.Dispose() }
            }
        } finally { $za.Dispose() }
    } finally { $fs.Dispose() }
    Get-ChildItem -LiteralPath $dir -Filter "$($c.name)-sessions-*.zip" | Sort-Object Name -Descending | Select-Object -Skip 5 | Remove-Item -Force
    return $zip
}

# ---------------------------------------------------------------------------------------------
# Create clones
# ---------------------------------------------------------------------------------------------
function New-DesktopClone($c, [bool]$CopySettings, [bool]$Shortcuts) {
    $isNew = -not (Test-Path -LiteralPath $c.dir)
    if (-not $isNew) { Warn "Profile folder already exists, keeping its data: $($c.dir)" }
    New-Item -ItemType Directory -Force $c.dir | Out-Null
    $main = Resolve-ClaudeMainData (Get-Desk)
    if (-not $main) { Warn 'The data folder of the main profile was not found: nothing to copy, sessions are not synced' }

    foreach ($a in @(Repair-ProfileLinks $c.dir $main $c.shareRuntime $false)) { Ok $a }
    if ($c.sync -ne 'off') { Ok "session list: own folder, synced with the main profile at every start ($($c.sync))" }
    if ($CopySettings -and $main) {
        # existing settings of a reused profile are never overwritten
        $cfg = Join-Path $main 'claude_desktop_config.json'
        $dst = Join-Path $c.dir 'claude_desktop_config.json'
        if ((Test-Path $cfg) -and -not (Test-Path $dst)) { Copy-Item $cfg $dst; Ok 'MCP / desktop settings copied' }
        foreach ($x in @('Claude Extensions', 'Claude Extensions Settings')) {
            $src = Join-Path $main $x
            if ((Test-Path $src) -and -not (Test-Path (Join-Path $c.dir $x))) {
                # robocopy copies paths longer than 260 characters (extension virtualenvs often are)
                robocopy "$src" "$(Join-Path $c.dir $x)" /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
                if ($LASTEXITCODE -lt 8) { Ok "$x copied" } else { Warn "$x could not be copied completely (robocopy $LASTEXITCODE)" }
                $global:LASTEXITCODE = 0
            }
        }
    }
    Write-Launcher $c
    Ok "launcher: $($c.launcher)"
    if ($Shortcuts) {
        Write-Shortcuts $c
        Ok "shortcuts: Desktop and Start menu ('$(Get-ShortcutTitle $c)')"
    } else { $c.shortcuts = @() }
    return $c
}

function New-CodeClone($c, [bool]$CopySettings, [bool]$Shortcuts) {
    if (Test-Path -LiteralPath $c.dir) { Warn "Config folder already exists, keeping its data: $($c.dir)" }
    New-Item -ItemType Directory -Force $c.dir | Out-Null
    if ($CopySettings -and (Test-Path $MainCodeConfig)) {
        foreach ($x in @('CLAUDE.md', 'settings.json', 'keybindings.json')) {
            $src = Join-Path $MainCodeConfig $x
            if ((Test-Path $src) -and -not (Test-Path (Join-Path $c.dir $x))) { Copy-Item $src (Join-Path $c.dir $x) }
        }
        foreach ($x in @('skills', 'agents', 'commands', 'output-styles')) {
            $src = Join-Path $MainCodeConfig $x
            if ((Test-Path $src) -and -not (Test-Path (Join-Path $c.dir $x))) { Copy-Item $src (Join-Path $c.dir $x) -Recurse }
        }
        Ok 'CLAUDE.md, settings, skills, agents and commands copied (never credentials)'
    }
    Write-Launcher $c
    Ok "command: claude-$($c.name)  ($($c.launcher))"
    if ($Shortcuts) {
        Write-Shortcuts $c
        Ok "shortcut: Desktop ('$(Get-ShortcutTitle $c)')"
    } else { $c.shortcuts = @() }
    return $c
}

function Invoke-Create {
    $prod = $Product; $names = $Names; $cnt = $Count
    Section 'Create new clones'
    $desk = Get-Desk
    $code = Resolve-ClaudeCode
    if (-not $desk -and -not $code) { Say "`n  Nothing to clone. Install Claude Desktop or Claude Code first." 'Yellow'; return }

    if (-not $prod) {
        $opts = @(); $labels = @()
        if ($desk) { $opts += 'desktop'; $labels += 'Claude Desktop' }
        if ($code) { $opts += 'code'; $labels += 'Claude Code (CLI)' }
        if ($opts.Count -eq 2) { $opts += 'both'; $labels += 'both' }
        if ($opts.Count -eq 1) { $prod = $opts[0] }
        else {
            $i = Select-Menu 'What do you want to clone?' $labels 0
            if ($i -lt 0) { return }
            $prod = $opts[$i]
        }
    }
    $doDesktop = ($prod -in @('desktop', 'both')) -and $desk
    $doCode = ($prod -in @('code', 'both')) -and $code
    if ($prod -in @('desktop', 'both') -and -not $desk) { Warn 'Claude Desktop is not installed - skipping it' }
    if ($prod -in @('code', 'both') -and -not $code) { Warn 'Claude Code is not installed - skipping it' }
    if (-not $doDesktop -and -not $doCode) { return }

    $all = @(Get-AllClones)
    $existing = @($all | ForEach-Object { $_.name })
    if (-not $names) {
        Write-Host ''
        if (-not $cnt) { try { $cnt = [int](Ask 'How many clones?' '1') } catch { $cnt = 1 } }
        if ($cnt -lt 1) { $cnt = 1 }
        $names = @()
        $next = 2
        for ($i = 1; $i -le $cnt; $i++) {
            while ($existing -contains "account$next" -or $names -contains "account$next") { $next++ }
            $names += (Ask "Name for clone $i" "account$next")
            $next++
        }
    }
    $names = @($names | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { Safe-Name $_ } | Select-Object -Unique)
    foreach ($n in $names) { if ($existing -contains $n) { Warn "'$n' already exists - its profile is kept, launcher and shortcuts are refreshed" } }

    $desktopBase = $Path; $codeBase = $Path
    if (-not $Path) {
        if ($doDesktop) { $desktopBase = Ask 'Where to store Claude Desktop profiles?' $DefaultProfileBase }
        if ($doCode) { $codeBase = Ask 'Where to store Claude Code profiles?' $env:USERPROFILE }
    }
    if ($doDesktop) { $desktopBase = Resolve-FullPath $desktopBase; if (-not (Confirm-ProfileBase $desktopBase $true)) { Say '  Cancelled. Pick a local folder.'; return } }
    if ($doCode) { $codeBase = Resolve-FullPath $codeBase; if (-not (Confirm-ProfileBase $codeBase $false)) { Say '  Cancelled. Pick a local folder.'; return } }

    $sync = 'both'
    if ($SessionSync) { $sync = $SessionSync }
    if ($NoShareSessions) { $sync = 'off' }
    $copy = -not $NoCopySettings; $links = -not $NoShortcuts; $mainLink = -not $NoMainShortcut
    if (-not $Yes) {
        if ($doDesktop -and -not $SessionSync -and -not $NoShareSessions) {
            if (-not (AskYesNo "Keep each account's session list in sync with the main profile (synced at every start)?" $true)) { $sync = 'off' }
        }
        if (-not $NoCopySettings) { $copy = AskYesNo 'Copy your settings (MCP servers, CLAUDE.md, skills; never login data)?' $true }
        if (-not $NoShortcuts) { $links = AskYesNo 'Create shortcuts with the Claude icon?' $true }
        if ($links -and -not $NoMainShortcut) { $mainLink = AskYesNo "Also create a 'main' shortcut for your current account?" $true }
    }

    Step 'Plan'
    foreach ($n in $names) {
        if ($doDesktop) { Say "    Claude Desktop  '$n'  ->  $(Join-Path $desktopBase "Claude-$n")   (sessions: $sync)" }
        if ($doCode) { Say "    Claude Code     '$n'  ->  $(Join-Path $codeBase ".claude-$n")" }
    }
    if (-not (AskYesNo 'Go ahead?' $true)) { Say '  Cancelled.'; return }

    $clones = @($all)
    foreach ($n in $names) {
        foreach ($p in @('desktop', 'code')) {
            if (($p -eq 'desktop' -and -not $doDesktop) -or ($p -eq 'code' -and -not $doCode)) { continue }
            $old = @($clones | Where-Object { $_.name -eq $n -and $_.product -eq $p }) | Select-Object -First 1
            if ($old) { $c = $old }
            else {
                if ($p -eq 'desktop') { $dir = Join-Path $desktopBase "Claude-$n" } else { $dir = Join-Path $codeBase ".claude-$n" }
                $c = ConvertTo-Clone ([pscustomobject]@{ name = $n; product = $p; dir = $dir; launcher = ''; shortcuts = @() })
                $c.badge = -not $NoBadge
                $c.syncOnExit = -not $NoSyncOnExit
                if ($p -eq 'desktop') { $c.sync = $sync; $c.shareRuntime = -not $NoShareRuntime }
            }
            if ($Label -and $names.Count -eq 1) { $c.label = $Label }
            if ($p -eq 'desktop') {
                if ($SessionSync -or $NoShareSessions) { $c.sync = $sync }
                Step "Claude Desktop clone '$n'"
                $c = New-DesktopClone $c $copy $links
            } else {
                Step "Claude Code clone '$n'"
                $c = New-CodeClone $c $copy $links
            }
            $clones = @($clones | Where-Object { -not ($_.name -eq $n -and $_.product -eq $p) }) + $c
            Save-Clones $clones
        }
    }

    if ($links -and $mainLink) {
        Step 'Main account'
        New-MainShortcuts ([bool]$doDesktop) ([bool]$doCode) | Out-Null
    }
    if ($doCode -and -not $NoPath) {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if (($userPath -split ';') -notcontains $BinDir) {
            if (AskYesNo "Add $BinDir to your PATH so 'claude-<name>' works in every terminal?" $true) {
                [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $BinDir), 'User')
                Ok 'PATH updated (open a new terminal)'
            }
        }
    }
    Write-Host ''
    Write-Host '  Done.' -ForegroundColor Green
    if ($doDesktop) { Say '  Open a "Claude (<name>)" shortcut and sign in with that account. Start it once more afterwards to bring in the sessions this account already has in the main profile.' }
    if ($doCode) { Say '  Run claude-<name> in a new terminal and type /login once.' }
}

# ---------------------------------------------------------------------------------------------
# Terminal UI (box drawing via char codes keeps this file ASCII for Windows PowerShell 5.1)
# ---------------------------------------------------------------------------------------------
$G = @{
    TL = [char]0x256D; TR = [char]0x256E; BL = [char]0x2570; BR = [char]0x256F; H = [char]0x2500; V = [char]0x2502
    Dot = [char]0x25CF; Ring = [char]0x25CB; Cross = [char]0x2715; Pick = [char]0x203A; Both = [char]0x2194
}
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch { }

$CanReadKey = $false
try { $CanReadKey = ($Host.Name -eq 'ConsoleHost') -and -not [Console]::IsInputRedirected -and -not $Yes } catch { }

function Get-Width { try { return [Math]::Max(60, [Math]::Min(110, [Console]::WindowWidth - 2)) } catch { return 80 } }

function Show-Header {
    $w = Get-Width
    $inner = $w - 4
    $left = "claude-clone v$Version"
    $right = 'several Claude accounts side by side'
    $gap = [Math]::Max(1, $inner - 2 - $left.Length - $right.Length)
    Write-Host ''
    Write-Host ('  ' + $G.TL + ([string]$G.H * $inner) + $G.TR) -ForegroundColor DarkGray
    Write-Host ('  ' + $G.V + ' ') -ForegroundColor DarkGray -NoNewline
    Write-Host 'claude-clone' -ForegroundColor White -NoNewline
    Write-Host " v$Version" -ForegroundColor DarkGray -NoNewline
    Write-Host ((' ' * $gap) + $right + ' ') -ForegroundColor DarkGray -NoNewline
    Write-Host $G.V -ForegroundColor DarkGray
    Write-Host ('  ' + $G.BL + ([string]$G.H * $inner) + $G.BR) -ForegroundColor DarkGray
}

function Section([string]$Title) { Write-Host ''; Write-Host "  $($Title.ToUpper())" -ForegroundColor DarkCyan }

function Short-Path([string]$P, [int]$Max = 0) {
    if (-not $P) { return '' }
    $p2 = $P.Replace($env:USERPROFILE, '~')
    if (-not $Max) { $Max = (Get-Width) - 74 }
    if ($Max -lt 20) { $Max = 20 }
    if ($p2.Length -gt $Max) { $p2 = '...' + $p2.Substring($p2.Length - $Max + 3) }
    return $p2
}

function Cut([string]$Text, [int]$Max) {
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max - 1) + '~'
}

function Ago($When) {
    if (-not $When) { return '-' }
    $s = (New-TimeSpan -Start $When -End (Get-Date))
    if ($s.TotalMinutes -lt 2) { return 'just now' }
    if ($s.TotalHours -lt 1) { return ('{0} min ago' -f [int]$s.TotalMinutes) }
    if ($s.TotalDays -lt 1) { return ('{0} h ago' -f [int]$s.TotalHours) }
    return ('{0} d ago' -f [int]$s.TotalDays)
}

# Arrow-key menu with a numbered fallback (redirected input, ISE, -Yes)
function Select-Menu([string]$Title, [string[]]$Items, [int]$Default = 0) {
    Write-Host ''
    Write-Host "  $Title" -ForegroundColor Cyan
    if (-not $CanReadKey) {
        for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host ("    {0}) {1}" -f ($i + 1), $Items[$i]) }
        $a = Ask 'Choose' ([string]($Default + 1))
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) { return ($n - 1) }
        return -1
    }
    for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host '' }
    $top = [Console]::CursorTop - $Items.Count
    $w = Get-Width
    $sel = $Default
    $done = $false
    try { [Console]::CursorVisible = $false } catch { }
    try {
        while (-not $done) {
            for ($i = 0; $i -lt $Items.Count; $i++) {
                [Console]::SetCursorPosition(0, $top + $i)
                if ($i -eq $sel) {
                    Write-Host '  ' -NoNewline
                    Write-Host (" $($G.Pick) " + $Items[$i]).PadRight($w - 4) -ForegroundColor Black -BackgroundColor Cyan -NoNewline
                    Write-Host '  ' -NoNewline
                } else {
                    Write-Host ('     ' + $Items[$i]).PadRight($w) -ForegroundColor Gray -NoNewline
                }
            }
            $k = [Console]::ReadKey($true)
            switch ($k.Key) {
                'UpArrow' { $sel = ($sel - 1 + $Items.Count) % $Items.Count }
                'DownArrow' { $sel = ($sel + 1) % $Items.Count }
                'Home' { $sel = 0 }
                'End' { $sel = $Items.Count - 1 }
                'Enter' { $done = $true }
                'Escape' { $sel = -1; $done = $true }
                default {
                    $d = 0
                    if ([int]::TryParse([string]$k.KeyChar, [ref]$d) -and $d -ge 1 -and $d -le $Items.Count) { $sel = $d - 1; $done = $true }
                }
            }
        }
    } finally {
        try { [Console]::CursorVisible = $true } catch { }
        [Console]::SetCursorPosition(0, $top + $Items.Count)
    }
    return $sel
}

function Wait-Key {
    if (-not $CanReadKey) { return }
    Write-Host ''
    Write-Host '  Press any key to continue' -ForegroundColor DarkGray -NoNewline
    [void][Console]::ReadKey($true)
}

# ---------------------------------------------------------------------------------------------
# Clone discovery and status
# ---------------------------------------------------------------------------------------------
function Read-LauncherHeader([string]$File) {
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    $head = @(Get-Content -LiteralPath $File -TotalCount 2)
    if ($head[0] -match "^# claude-clone (\S+) - Claude (Desktop|Code), profile '([^']+)'") {
        $prod = 'desktop'
        if ($Matches[2] -eq 'Code') { $prod = 'code' }
        $h = @{ version = $Matches[1]; product = $prod; name = $Matches[3]; runtime = '' }
        if ($head.Count -gt 1 -and $head[1] -match '^# runtime (\S+)') { $h.runtime = $Matches[1] }
        return $h
    }
    return $null
}

# Older version, or (Desktop) a runtime that differs from this script's
function Test-LauncherOutdated($H) {
    return ($H.version -ne $Version -or ($H.product -eq 'desktop' -and $H.runtime -ne $RuntimeId))
}

# Manifest plus every claude-clone profile found on disk. Nothing is written here; the next action
# that saves the list also keeps the profiles found on disk.
function Get-AllClones {
    $clones = @(Get-Clones | ForEach-Object { ConvertTo-Clone $_ })
    $known = @{}
    foreach ($c in $clones) { $known[$c.dir.TrimEnd('\').ToLower()] = $true }
    $cands = @()
    foreach ($b in @($DefaultProfileBase, $env:APPDATA)) {
        if ($b -and (Test-Path $b)) { $cands += @(Get-ChildItem -LiteralPath $b -Directory -Filter 'Claude-*' -ErrorAction SilentlyContinue) }
    }
    $cands += @(Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Force -Filter '.claude-*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.claude-clone' })
    foreach ($d in $cands) {
        if ($known.ContainsKey($d.FullName.TrimEnd('\').ToLower())) { continue }
        $h = Read-LauncherHeader (Join-Path $d.FullName 'launch.ps1')
        if (-not $h) { continue }
        $launcher = Join-Path $d.FullName 'launch.ps1'
        if ($h.product -eq 'code') { $launcher = Join-Path $BinDir "claude-$($h.name).cmd" }
        $clones += ConvertTo-Clone ([pscustomobject]@{ name = $h.name; product = $h.product; dir = $d.FullName; launcher = $launcher; shortcuts = @() })
        $known[$d.FullName.TrimEnd('\').ToLower()] = $true
    }
    return $clones
}

function Get-CloneStatus($Clone, $Procs) {
    $st = [ordered]@{ State = 'missing'; LastUsed = $null }
    if (-not (Test-Path -LiteralPath $Clone.dir)) { return $st }
    $st.State = 'not signed in'
    if ($Clone.product -eq 'desktop') {
        $cfg = Join-Path $Clone.dir 'config.json'
        if (Test-Path -LiteralPath $cfg) {
            # only the presence of the token cache is checked, never its value
            try { if ([Text.Encoding]::UTF8.GetString((Read-SharedBytes $cfg)) -match '"oauth:tokenCache(V2)?"\s*:\s*"[^"]') { $st.State = 'signed in' } } catch { }
        }
        $st.LastUsed = @('Local State', 'config.json', 'Preferences') | ForEach-Object { Join-Path $Clone.dir $_ } |
            Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { (Get-Item -LiteralPath $_).LastWriteTime } |
            Sort-Object -Descending | Select-Object -First 1
        if (Test-ProfileRunning $Clone.dir $Procs) { $st.State = 'running' }
    } else {
        if (Test-Path -LiteralPath (Join-Path $Clone.dir '.credentials.json')) { $st.State = 'signed in' }
        $st.LastUsed = @('.claude.json', 'projects', 'history.jsonl') | ForEach-Object { Join-Path $Clone.dir $_ } |
            Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { (Get-Item -LiteralPath $_).LastWriteTime } |
            Sort-Object -Descending | Select-Object -First 1
    }
    return $st
}

function Show-Installed($Desk, $Code) {
    Section 'Installed'
    if ($Desk) {
        Write-Host ('    ' + $G.Dot + ' ') -ForegroundColor Green -NoNewline
        $kind = @{ msix = 'Microsoft Store'; squirrel = 'installer'; exe = 'installer' }[$Desk.Kind]
        Write-Host ('{0,-16}{1,-18}{2}' -f 'Claude Desktop', $kind, $Desk.Version)
    } else {
        Write-Host ('    ' + $G.Ring + ' ') -ForegroundColor DarkGray -NoNewline
        Write-Host 'Claude Desktop  not found' -ForegroundColor DarkGray
    }
    if ($Code) {
        $ver = ''
        if ($Code -match '\\claude-code\\([0-9][^\\]*)\\') { $ver = "$($Matches[1])  (bundled with Claude Desktop)" }
        Write-Host ('    ' + $G.Dot + ' ') -ForegroundColor Green -NoNewline
        Write-Host ('{0,-16}{1}' -f 'Claude Code', $(if ($ver) { $ver } else { Short-Path $Code 60 }))
    } else {
        Write-Host ('    ' + $G.Ring + ' ') -ForegroundColor DarkGray -NoNewline
        Write-Host 'Claude Code     not found' -ForegroundColor DarkGray
    }
}

# The main profile and the accounts it holds - the answer to "which window has which sessions?"
function Show-MainProfile($Desk, $Main, $Clones, $Procs) {
    if (-not $Desk) { return }
    $running = Test-MainRunning $Procs
    Section 'Main profile (Claude started normally)'
    if (-not $Main) { Write-Host '    data folder not found - start Claude once normally' -ForegroundColor DarkGray; return }
    $sym = $G.Ring; $col = 'DarkGray'; $state = 'not running'
    if ($running) { $sym = $G.Dot; $col = 'Green'; $state = 'running' }
    Write-Host ('    ' + $sym + ' ') -ForegroundColor $col -NoNewline
    Write-Host ('{0,-14}' -f $state) -ForegroundColor $col -NoNewline
    Write-Host (Short-Path $Main 80) -ForegroundColor DarkGray
    $active = Get-ActiveAccount $Main
    foreach ($a in @(Get-ProfileAccounts $Main | Sort-Object { $_ -ne $active }, { - (Get-SessionCount $Main $_) })) {
        $in = @($Clones | Where-Object { (Get-CloneAccount $_) -eq $a } | ForEach-Object { $_.name })
        $mark = ''
        if ($a -eq $active) { $mark = 'active' }
        Write-Host '      ' -NoNewline
        Write-Host ('{0,-22}' -f (Cut (Get-AccountLabel $a $Clones) 21)) -ForegroundColor White -NoNewline
        Write-Host ('{0,-10}' -f $a.Substring(0, 8)) -ForegroundColor DarkGray -NoNewline
        Write-Host ('{0,-8}' -f $mark) -ForegroundColor Green -NoNewline
        Write-Host ('{0,-14}' -f ('{0} sessions' -f (Get-SessionCount $Main $a))) -ForegroundColor Gray -NoNewline
        if ($in.Count) { Write-Host ("$($G.Both) clone " + ($in -join ', ')) -ForegroundColor Cyan } else { Write-Host '' }
    }
}

function Show-CloneTable($Clones, $Procs) {
    Section ("Your clones ({0})" -f @($Clones).Count)
    if (-not @($Clones).Count) {
        Write-Host '    none yet - choose "Create new clones"' -ForegroundColor DarkGray
    } else {
        Write-Host ('      {0,-14}{1,-9}{2,-15}{3,-16}{4,-11}{5}' -f 'NAME', 'APP', 'STATUS', 'ACCOUNT', 'LAST USED', 'FOLDER') -ForegroundColor DarkGray
        foreach ($c in $Clones) {
            $st = Get-CloneStatus $c $Procs
            $sym = $G.Dot; $col = 'Gray'
            switch ($st.State) {
                'running' { $col = 'Green' }
                'signed in' { $col = 'Cyan' }
                'not signed in' { $sym = $G.Ring; $col = 'DarkGray' }
                'missing' { $sym = $G.Cross; $col = 'Red' }
            }
            $app = 'Desktop'
            if ($c.product -eq 'code') { $app = 'Code' }
            $acc = '-'
            if ($c.product -eq 'desktop' -and $st.State -ne 'missing') { $acc = Get-AccountLabel (Get-CloneAccount $c) $Clones }
            Write-Host ('    ' + $sym + ' ') -ForegroundColor $col -NoNewline
            Write-Host ('{0,-14}' -f (Cut $c.name 13)) -ForegroundColor White -NoNewline
            Write-Host ('{0,-9}' -f $app) -NoNewline
            Write-Host ('{0,-15}' -f $st.State) -ForegroundColor $col -NoNewline
            Write-Host ('{0,-16}' -f (Cut $acc 15)) -NoNewline
            Write-Host ('{0,-11}' -f (Ago $st.LastUsed)) -ForegroundColor DarkGray -NoNewline
            Write-Host (Short-Path $c.dir) -ForegroundColor DarkGray
        }
    }
    # Profiles started with --user-data-dir that claude-clone does not manage (other tools, manual starts)
    $foreign = @()
    foreach ($p in @($Procs | Where-Object { $_.UserDataDir })) {
        $d = $p.UserDataDir
        if (-not @($Clones | Where-Object { Test-SamePath $_.dir $d }).Count -and ($foreign -notcontains $d)) { $foreign += $d }
    }
    foreach ($d in $foreign) {
        Write-Host ('    ' + $G.Dot + ' ') -ForegroundColor DarkYellow -NoNewline
        Write-Host ('{0,-14}{1,-9}{2,-15}{3,-16}{4,-11}{5}' -f '(unmanaged)', 'Desktop', 'running', '', '', (Short-Path $d)) -ForegroundColor DarkYellow
    }
}

function Show-Health($Findings) {
    Section 'Health'
    $bad = @($Findings | Where-Object { $_.Level -ne 'info' })
    if (-not $bad.Count) {
        Write-Host ('    ' + $G.Dot + ' ') -ForegroundColor Green -NoNewline
        Write-Host 'all profiles OK'
        return
    }
    $w = (Get-Width) - 10
    foreach ($x in @($bad | Select-Object -First 4)) {
        $col = 'Yellow'
        if ($x.Level -eq 'error') { $col = 'Red' }
        $who = ''
        if ($x.Clone) { $who = "$($x.Clone): " }
        Write-Host ('    ' + $G.Dot + ' ') -ForegroundColor $col -NoNewline
        Write-Host (Cut ($who + $x.Text) $w)
    }
    if ($bad.Count -gt 4) { Write-Host ("      ... and {0} more" -f ($bad.Count - 4)) -ForegroundColor DarkGray }
    Write-Host '      choose "Check & repair" for details' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------------------------
# Doctor / repair
# ---------------------------------------------------------------------------------------------
function Add-Finding($List, [string]$Clone, [string]$Level, [string]$Text, [string]$Fix = '', $Arg = $null, [string]$Hint = '') {
    [void]$List.Add([pscustomobject]@{ Clone = $Clone; Level = $Level; Text = $Text; Fix = $Fix; Arg = $Arg; Hint = $Hint })
}

function Get-CloneArtifacts($c) {
    $l = @($c.shortcuts) + @(Get-StandardShortcuts $c)
    if ($c.product -eq 'code') { $l += Join-Path $BinDir "claude-$($c.name).cmd" }
    return @($l | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)
}

# Shortcuts made by claude-clone whose launcher no longer exists
function Get-OrphanShortcuts($Clones) {
    $taken = @{}
    foreach ($c in $Clones) { foreach ($l in @(Get-CloneArtifacts $c)) { $taken[$l.ToLower()] = $true } }
    $out = @()
    $ws = New-Object -ComObject WScript.Shell
    foreach ($dir in @($StartMenuDir, $DesktopDir)) {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'Claude*.lnk' -ErrorAction SilentlyContinue)) {
            if ($taken.ContainsKey($f.FullName.ToLower())) { continue }
            try { $s = $ws.CreateShortcut($f.FullName) } catch { continue }
            if ($s.Description -notlike '*(claude-clone)*') { continue }
            if ($s.Arguments -match '-File "([^"]+)"' -and -not (Test-Path -LiteralPath $Matches[1])) { $out += $f.FullName }
        }
    }
    return $out
}

function Get-Findings($Clones) {
    $f = New-Object Collections.ArrayList
    $desk = Get-Desk
    $main = Resolve-ClaudeMainData $desk
    $procs = @(Get-DesktopProcesses $desk)
    $mainRunning = Test-MainRunning $procs
    $desktopClones = @($Clones | Where-Object { $_.product -eq 'desktop' -and (Test-Path -LiteralPath $_.dir) })
    if ($desk -and -not $main -and $desktopClones.Count) {
        Add-Finding $f '' 'warn' 'The data folder of the main Claude Desktop profile was not found, so session lists are not synced.' '' $null 'Start Claude once normally, then check again.'
    }
    foreach ($grp in @($Clones | Group-Object { $_.dir.TrimEnd('\').ToLower() } | Where-Object { $_.Count -gt 1 })) {
        Add-Finding $f '' 'warn' ("Several clones use the same folder {0}: {1}" -f $grp.Group[0].dir, (($grp.Group | ForEach-Object { "$($_.name) ($($_.product))" }) -join ', '))
    }
    $byAcc = @{}
    foreach ($c in $desktopClones) {
        $a = Get-CloneAccount $c
        if ($a) { if (-not $byAcc.ContainsKey($a)) { $byAcc[$a] = @() }; $byAcc[$a] += $c.name }
    }
    foreach ($k in @($byAcc.Keys)) {
        if ($byAcc[$k].Count -gt 1) { Add-Finding $f '' 'info' ("Account {0} is signed in to several clones: {1}." -f (Get-AccountLabel $k $Clones), ($byAcc[$k] -join ', ')) }
    }

    foreach ($c in $Clones) {
        $n = $c.name
        if (-not (Test-Path -LiteralPath $c.dir -PathType Container)) {
            $arts = @(Get-CloneArtifacts $c)
            $hint = "remove '$n' from the list"
            if ($arts.Count) { $hint += " and delete its $($arts.Count) shortcut(s)/command(s)" }
            Add-Finding $f $n 'error' "Profile folder is missing: $($c.dir)" 'drop' $c $hint
            continue
        }
        $running = ($c.product -eq 'desktop') -and (Test-ProfileRunning $c.dir $procs)
        $ps1 = Join-Path $c.dir 'launch.ps1'
        $h = Read-LauncherHeader $ps1
        if (-not $h) { Add-Finding $f $n 'warn' 'Launcher is missing.' 'launcher' $c 'write a new launcher' }
        elseif ($h.version -ne $Version) {
            $why = ''
            if ($c.product -eq 'desktop' -and -not $h.runtime) { $why = ' - it cannot repair the profile before starting' }
            Add-Finding $f $n 'warn' "Launcher is from claude-clone $($h.version)$why." 'launcher' $c "update it to $Version"
        } elseif (Test-LauncherOutdated $h) {
            Add-Finding $f $n 'warn' 'Launcher was written by another build of this version.' 'launcher' $c 'write it again'
        }
        if ($c.product -eq 'code' -and -not (Test-Path -LiteralPath (Join-Path $BinDir "claude-$n.cmd"))) {
            Add-Finding $f $n 'warn' "The command claude-$n is missing." 'launcher' $c 'write it again'
        }
        if ($c.product -eq 'desktop') {
            $acts = @(Repair-ProfileLinks $c.dir $main $c.shareRuntime $true)
            foreach ($a in $acts) {
                $lvl = 'warn'
                if ($a -match 'dead link') { $lvl = 'error' } elseif ($a -match 'not linked') { $lvl = 'info' }
                if ($running) { Add-Finding $f $n $lvl $a '' $null "close Claude ($n), then run -Repair" }
                else { Add-Finding $f $n $lvl $a 'links' $c 'repair the link' }
            }
            if ($main -and $c.sync -ne 'off' -and -not $acts.Count) {
                $s = Sync-CloneSessions $c.dir $main $c.sync $running $mainRunning $true
                if ($s.Pulled + $s.PullUpdated + $s.Pushed + $s.PushUpdated) {
                    Add-Finding $f $n 'info' ((Format-SyncResult $s) -replace '^sessions: ', 'session entries to sync: ') 'sync' $c 'sync now (also happens at the next start)'
                }
            }
            $acc = Get-CloneAccount $c
            if ($acc -and $mainRunning -and $acc -eq (Get-ActiveAccount $main)) {
                Add-Finding $f $n 'info' "Its account ($(Get-AccountLabel $acc $Clones)) is also the active account of the running main Claude window."
            }
        }
        $missing = @(Get-ExpectedShortcuts $c | Where-Object { -not (Test-ShortcutTarget $_ $ps1) })
        if ($missing.Count) { Add-Finding $f $n 'warn' ("Shortcut missing or pointing elsewhere: " + ($missing -join ', ')) 'shortcuts' $c 're-create it' }
        if (Test-CloudPath $c.dir) {
            Add-Finding $f $n 'warn' "Profile is in a cloud-synced folder ($(Short-Path $c.dir 60)); sync conflicts can damage its databases." '' $null "move it to a local folder: claude-clone.ps1 -Move $n"
        } elseif ($c.product -eq 'desktop' -and (Test-VirtualizedPath $c.dir)) {
            Add-Finding $f $n 'warn' 'Profile is inside AppData, where the Microsoft Store version of Claude may redirect its writes.' '' $null "move it: claude-clone.ps1 -Move $n"
        }
    }
    foreach ($l in @(Get-OrphanShortcuts $Clones)) { Add-Finding $f '' 'warn' "Shortcut of a profile that no longer exists: $l" 'orphan' $l 'delete it' }
    $mainLauncher = Join-Path $StateDir 'launch-main-desktop.ps1'
    if (Test-Path -LiteralPath $mainLauncher) {
        $head = @(Get-Content -LiteralPath $mainLauncher -TotalCount 2)
        if (-not ($head.Count -gt 1 -and $head[1] -eq "# runtime $RuntimeId" -and $head[0] -like "# claude-clone $Version *")) {
            Add-Finding $f '' 'warn' "The 'Claude (main)' launcher is from an older claude-clone." 'mainlauncher' $mainLauncher 'update it'
        }
    }
    return $f
}

function Write-Finding($x) {
    $sym = '[i]'; $col = 'DarkGray'
    switch ($x.Level) { 'error' { $sym = '[x]'; $col = 'Red' } 'warn' { $sym = '[!]'; $col = 'Yellow' } }
    Write-Host "    $sym " -ForegroundColor $col -NoNewline
    Write-Host $x.Text
    if ($x.Hint) {
        $how = $x.Hint
        if ($x.Fix) { $how = "repair: $how" }
        Write-Host "        -> $how" -ForegroundColor DarkGray
    }
}

function Invoke-SyncClone($c, $Main, $Procs) {
    $s = Sync-CloneSessions $c.dir $Main $c.sync (Test-ProfileRunning $c.dir $Procs) (Test-MainRunning $Procs) $false
    return Format-SyncResult $s
}

# Returns the number of problems that are left (0 = all fine)
function Invoke-Doctor([bool]$Fix) {
    $clones = @(Get-AllClones)
    $findings = @(Get-Findings $clones)
    $open = @($findings | Where-Object { $_.Level -ne 'info' })
    if (-not $findings.Count) { Write-Host ''; Ok 'all profiles OK'; return 0 }
    foreach ($g in @('') + @($clones | ForEach-Object { $_.name } | Select-Object -Unique)) {
        $items = @($findings | Where-Object { $_.Clone -eq $g })
        if (-not $items.Count) { continue }
        Write-Host ''
        if ($g) { Write-Host "  $g" -ForegroundColor White } else { Write-Host '  general' -ForegroundColor White }
        foreach ($x in $items) { Write-Finding $x }
    }
    $fixable = @($findings | Where-Object { $_.Fix })
    if (-not $Fix) {
        Write-Host ''
        if ($fixable.Count) { Say "  $($fixable.Count) of these can be repaired automatically: claude-clone.ps1 -Repair" 'Cyan' }
        return $open.Count
    }
    if (-not $fixable.Count) { return $open.Count }

    Step 'Repairing'
    $desk = Get-Desk
    $main = Resolve-ClaudeMainData $desk
    $done = @{}
    $dropped = @()
    $lock = Enter-CloneLock
    try {
        foreach ($x in $fixable) {
            $c = $x.Arg
            $key = "$($x.Clone)|$($x.Fix)"
            if ($x.Fix -eq 'orphan') { $key += "|$($x.Arg)" }
            if ($done.ContainsKey($key)) { continue }
            $done[$key] = $true
            try {
                switch ($x.Fix) {
                    'drop' {
                        if (AskYesNo "Remove '$($c.name)' ($($c.product)) from the list? Its profile folder no longer exists." $true) {
                            foreach ($l in @(Get-CloneArtifacts $c)) { Remove-Item -LiteralPath $l -Force; Fixed "deleted $l" }
                            $dropped += $c
                            Fixed "'$($c.name)' removed from the list"
                        }
                    }
                    'launcher' {
                        Write-Launcher $c
                        Fixed "$($c.name): launcher updated to $Version"
                        if (@($c.shortcuts).Count) {
                            Write-Shortcuts $c
                            $done["$($x.Clone)|shortcuts"] = $true
                            Fixed "$($c.name): shortcuts and icon refreshed"
                        }
                    }
                    'links' {
                        $procs = @(Get-DesktopProcesses $desk)
                        if (Test-ProfileRunning $c.dir $procs) { Warn "$($c.name) was started in the meantime - close it and run -Repair again"; break }
                        foreach ($a in @(Repair-ProfileLinks $c.dir $main $c.shareRuntime $false)) { Fixed "$($c.name): $a" }
                        if ($main -and $c.sync -ne 'off') {
                            Fixed "$($c.name): $(Invoke-SyncClone $c $main $procs)"
                            $done["$($x.Clone)|sync"] = $true
                        }
                    }
                    'sync' { Fixed "$($c.name): $(Invoke-SyncClone $c $main @(Get-DesktopProcesses $desk))" }
                    'shortcuts' { Write-Shortcuts $c; Fixed "$($c.name): shortcuts re-created" }
                    'orphan' { Remove-Item -LiteralPath $x.Arg -Force; Fixed "deleted $($x.Arg)" }
                    'mainlauncher' { [void](Write-MainLauncher); Fixed "'Claude (main)' launcher updated to $Version" }
                }
            } catch { Bad "$($x.Clone): $($_.Exception.Message)" }
        }
    } finally { Exit-CloneLock $lock }
    Save-Clones @($clones | Where-Object { $dropped -notcontains $_ })
    $script:AccountCache = @{}
    $left = @(Get-Findings @(Get-AllClones) | Where-Object { $_.Level -ne 'info' })
    Write-Host ''
    if ($left.Count) {
        Warn "$($left.Count) point(s) need you:"
        foreach ($x in $left) { Write-Finding $x }
    } else { Ok 'all profiles OK' }
    return $left.Count
}

# ---------------------------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------------------------
function Find-Clones([string]$Name) {
    return @(Get-AllClones | Where-Object { $_.name -eq $Name -and (-not $Product -or $Product -eq 'both' -or $_.product -eq $Product) })
}

function Invoke-Launch($Clone) {
    if ($Clone -is [string]) {
        $r = Invoke-MainLauncher $false
        foreach ($n in @($r.Notes)) { Info $n }
        if ($r.Problem) { Bad $r.Problem }
        if ($r.Started) { Ok 'started Claude Desktop (main profile)' }
        return
    }
    if (-not (Test-Path -LiteralPath $Clone.dir)) { Warn "Profile folder is missing: $($Clone.dir)"; return }
    if ($Clone.product -eq 'desktop') {
        $r = Invoke-CloneLauncher $Clone.name $Clone.dir $Clone.sync ([bool]$Clone.shareRuntime) $false
        foreach ($n in @($r.Notes)) { Info $n }
        if ($r.Problem) { Bad $r.Problem }
        if ($r.Warning) { Warn $r.Warning }
        if ($r.Started) { Ok "started Claude Desktop '$($Clone.name)'" }
        # the launcher in the background syncs again when the window is closed
        $ps1 = Join-Path $Clone.dir 'launch.ps1'
        $h = Read-LauncherHeader $ps1
        if ($r.Started -and $Clone.syncOnExit -and $Clone.sync -eq 'both' -and $h -and -not (Test-LauncherOutdated $h)) {
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ps1`" -WatchOnly"
        }
    } else {
        $ps1 = Join-Path $Clone.dir 'launch.ps1'
        $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
        if ($wt) { Start-Process $wt.Source -ArgumentList "powershell.exe -NoLogo -NoExit -ExecutionPolicy Bypass -File `"$ps1`"" }
        else { Start-Process powershell.exe -ArgumentList "-NoLogo -NoExit -ExecutionPolicy Bypass -File `"$ps1`"" }
        Ok "opened Claude Code '$($Clone.name)' in a new terminal"
    }
}

function Invoke-Remove([string]$Name, [bool]$DeleteProfile, [bool]$AskDelete = $true) {
    $clones = @(Get-AllClones)
    $hit = @($clones | Where-Object { $_.name -eq $Name -and (-not $Product -or $Product -eq 'both' -or $_.product -eq $Product) })
    if (-not $hit.Count) { Say "No clone named '$Name'." 'Yellow'; return $false }
    foreach ($c in $hit) {
        Step "Removing $($c.product) clone '$($c.name)'"
        if ($c.product -eq 'desktop' -and (Test-ProfileRunning $c.dir @(Get-DesktopProcesses (Get-Desk)))) { Warn "Claude ($($c.name)) is running - close it first."; continue }
        foreach ($l in @(Get-CloneArtifacts $c)) { Remove-Item -LiteralPath $l -Force; Ok "removed $l" }
        $del = $DeleteProfile
        if (-not $del -and $AskDelete) { $del = AskYesNo "Also delete the profile folder $($c.dir)? This signs the account out on this machine." $false }
        if ($del) {
            if ($c.product -eq 'desktop') {
                try { $zip = Backup-Sessions $c; if ($zip) { Ok "session list saved to $zip" } } catch { Warn "could not save the session list: $($_.Exception.Message)" }
            }
            if (Remove-FolderSafely $c.dir) { Ok "deleted $($c.dir) (shared folders of the main profile are untouched)" }
        } else {
            Say "    kept $($c.dir)"
        }
        $clones = @($clones | Where-Object { $_ -ne $c })
    }
    Save-Clones $clones
    return $true
}

# Moves a profile (for example out of OneDrive) and updates launcher, shortcuts and the list
function Invoke-Move([string]$Name, [string]$Dest) {
    $clones = @(Get-AllClones)
    $hit = @($clones | Where-Object { $_.name -eq $Name -and (-not $Product -or $Product -eq 'both' -or $_.product -eq $Product) })
    if (-not $hit.Count) { Say "No clone named '$Name'." 'Yellow'; return $false }
    $allOk = $true
    foreach ($c in $hit) {
        $default = $env:USERPROFILE
        if ($c.product -eq 'desktop') { $default = $DefaultProfileBase }
        $base = $Dest
        if (-not $base) { $base = Ask "Move '$Name' ($($c.product)) to which folder?" $default }
        $base = Resolve-FullPath $base
        $dst = Join-Path $base (Split-Path $c.dir -Leaf)
        Step "Moving $($c.product) clone '$Name'"
        if (Test-SamePath $dst $c.dir) { Ok "already in $base"; continue }
        if (-not (Test-Path -LiteralPath $c.dir -PathType Container)) { Bad "profile folder is missing: $($c.dir)"; $allOk = $false; continue }
        if (Get-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue) { Bad "$dst already exists"; $allOk = $false; continue }
        if (Test-UnderPath $dst $c.dir) { Bad 'the new folder cannot be inside the profile'; $allOk = $false; continue }
        if (-not (Confirm-ProfileBase $base ($c.product -eq 'desktop'))) { Say '    skipped'; $allOk = $false; continue }
        $desk = Get-Desk
        $main = Resolve-ClaudeMainData $desk
        if ($c.product -eq 'desktop') {
            if (Test-ProfileRunning $c.dir @(Get-DesktopProcesses $desk)) { Bad "Claude ($Name) is running - close it first"; $allOk = $false; continue }
            foreach ($a in @(Repair-ProfileLinks $c.dir $main $c.shareRuntime $false)) { Fixed $a }
            try { $zip = Backup-Sessions $c; if ($zip) { Ok "session list saved to $zip" } } catch { Warn "could not save the session list: $($_.Exception.Message)" }
        } else {
            Warn "make sure claude-$Name is not running"
        }
        # links are left out and set again afterwards; everything else is copied, then compared
        $skip = @(Get-ChildItem -LiteralPath $c.dir -Force -Directory | Where-Object { "$($_.LinkType)" -in @('Junction', 'SymbolicLink') } | ForEach-Object { $_.FullName })
        $before = Get-TreeStats $c.dir
        New-Item -ItemType Directory -Force $base | Out-Null
        $rcArgs = @($c.dir, $dst, '/E', '/COPY:DAT', '/DCOPY:T', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
        if ($skip.Count) { $rcArgs += '/XD'; $rcArgs += $skip }
        robocopy @rcArgs | Out-Null
        $rc = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        $after = Get-TreeStats $dst
        if ($rc -ge 8 -or $after.Files -ne $before.Files -or $after.Bytes -ne $before.Bytes) {
            Bad ("copy incomplete (robocopy {0}, {1}/{2} files) - nothing changed, the partial copy in {3} can be deleted" -f $rc, $after.Files, $before.Files, $dst)
            $allOk = $false
            continue
        }
        Ok ("copied {0} files ({1:N0} MB) to {2}" -f $after.Files, ($after.Bytes / 1MB), $dst)
        $old = $c.dir
        $c.dir = $dst
        if ($c.product -eq 'desktop') { foreach ($a in @(Repair-ProfileLinks $dst $main $c.shareRuntime $false)) { Ok $a } }
        Write-Launcher $c
        if (@($c.shortcuts).Count) { Write-Shortcuts $c }
        Save-Clones $clones
        Ok 'launcher, shortcuts and clone list now point to the new folder'
        if (AskYesNo "Delete the old folder $old?" $true) {
            if (Remove-FolderSafely $old) { Ok "deleted $old" }
        } else { Say "    kept $old (no longer used)" }
    }
    return $allOk
}

function Invoke-Sync {
    $desk = Get-Desk
    $main = Resolve-ClaudeMainData $desk
    Step 'Syncing session lists with the main profile'
    if (-not $main) { Warn 'The data folder of the main profile was not found - nothing to sync.'; return }
    $procs = @(Get-DesktopProcesses $desk)
    if (Test-MainRunning $procs) { Info 'the main Claude app is running: it only gets new sessions, nothing there is overwritten' }
    $clones = @(Get-AllClones | Where-Object { $_.product -eq 'desktop' -and (-not $Names -or $Names -contains $_.name) })
    if (-not $clones.Count) { Say '    No Claude Desktop clones.' 'DarkGray'; return }
    $lock = Enter-CloneLock
    try {
        foreach ($c in $clones) {
            if ($c.sync -eq 'off') { Info "$($c.name): sync is off"; continue }
            if (-not (Test-Path -LiteralPath $c.dir -PathType Container)) { Warn "$($c.name): profile folder is missing"; continue }
            $li = Get-LinkInfo (Join-Path $c.dir 'claude-code-sessions')
            if ($li -and $li.IsLink) { Warn "$($c.name): its session folder is still a link - run -Repair first"; continue }
            Ok "$($c.name): $(Invoke-SyncClone $c $main $procs)"
        }
    } finally { Exit-CloneLock $lock }
}

function Invoke-Set([string]$Name) {
    $clones = @(Get-AllClones)
    $hit = @($clones | Where-Object { $_.name -eq $Name -and (-not $Product -or $Product -eq 'both' -or $_.product -eq $Product) })
    if (-not $hit.Count) { Say "No clone named '$Name'." 'Yellow'; return $false }
    foreach ($c in $hit) {
        if ($BoundParams.ContainsKey('Label')) { $c.label = $Label }
        if ($c.product -eq 'desktop') {
            if ($SessionSync) { $c.sync = $SessionSync }
            if ($NoShareSessions) { $c.sync = 'off' }
            if ($BoundParams.ContainsKey('NoShareRuntime')) { $c.shareRuntime = -not $NoShareRuntime }
        }
        if ($BoundParams.ContainsKey('NoBadge')) { $c.badge = -not $NoBadge }
        if ($BoundParams.ContainsKey('NoSyncOnExit')) { $c.syncOnExit = -not $NoSyncOnExit }
        Save-CloneSettings $c
        if ($CopySettings -and $c.product -eq 'desktop') { Copy-MainSettings $c }
    }
    Save-Clones $clones
    return $true
}

function OnOff([bool]$B) { if ($B) { return 'on' }; return 'off' }

function Save-CloneSettings($c) {
    if (-not (Test-Path -LiteralPath $c.dir)) { Warn "$($c.name): profile folder is missing, only the list was updated"; return }
    Write-Launcher $c
    if (@($c.shortcuts).Count) { Write-Shortcuts $c }
    $what = "label '$($c.label)', icon letter $(OnOff $c.badge)"
    if ($c.product -eq 'desktop') { $what += ", session sync $($c.sync), sync when closed $(OnOff $c.syncOnExit), shared runtime $(OnOff $c.shareRuntime)" }
    Ok "$($c.name) ($($c.product)): $what"
}

# Copies the MCP / desktop settings of the main profile into a clone again (the old file is kept)
function Copy-MainSettings($c) {
    $main = Resolve-ClaudeMainData (Get-Desk)
    $src = ''
    if ($main) { $src = Join-Path $main 'claude_desktop_config.json' }
    if (-not $src -or -not (Test-Path -LiteralPath $src)) { Warn 'The main profile has no claude_desktop_config.json.'; return }
    if (Test-ProfileRunning $c.dir @(Get-DesktopProcesses (Get-Desk))) { Warn "Close Claude ($($c.name)) first - it writes this file while it runs."; return }
    $dst = Join-Path $c.dir 'claude_desktop_config.json'
    if (Test-Path -LiteralPath $dst) { Copy-Item -LiteralPath $dst "$dst.bak" -Force }
    Copy-Item -LiteralPath $src $dst -Force
    Ok "$($c.name): MCP / desktop settings copied from the main profile (previous file kept as claude_desktop_config.json.bak)"
}

# Renames a clone: folder, launcher, shortcuts, command, log and list entry
function Invoke-Rename([string]$Name, [string]$NewName, [string]$Prod = $Product) {
    if (-not $NewName) { $NewName = Ask "New name for '$Name'" '' }
    if (-not $NewName) { Bad 'give the new name with -To <name>'; return $false }
    $NewName = Safe-Name $NewName
    $clones = @(Get-AllClones)
    $hit = @($clones | Where-Object { $_.name -eq $Name -and (-not $Prod -or $Prod -eq 'both' -or $_.product -eq $Prod) })
    if (-not $hit.Count) { Say "No clone named '$Name'." 'Yellow'; return $false }
    $allOk = $true
    foreach ($c in $hit) {
        Step "Renaming $($c.product) clone '$Name' to '$NewName'"
        $leaf = ".claude-$NewName"
        if ($c.product -eq 'desktop') { $leaf = "Claude-$NewName" }
        $newDir = Join-Path (Split-Path $c.dir) $leaf
        $problem = ''
        if (@($clones | Where-Object { $_.name -eq $NewName -and $_.product -eq $c.product }).Count) { $problem = "a $($c.product) clone named '$NewName' already exists" }
        elseif (-not (Test-Path -LiteralPath $c.dir -PathType Container)) { $problem = "profile folder is missing: $($c.dir)" }
        elseif ($c.product -eq 'desktop' -and (Test-ProfileRunning $c.dir @(Get-DesktopProcesses (Get-Desk)))) { $problem = "Claude ($Name) is running - close it first" }
        elseif (Get-Item -LiteralPath $newDir -Force -ErrorAction SilentlyContinue) { $problem = "$newDir already exists" }
        if ($problem) { Bad $problem; $allOk = $false; continue }
        $hadShortcuts = @($c.shortcuts).Count -gt 0
        try { Rename-Item -LiteralPath $c.dir -NewName $leaf -ErrorAction Stop }
        catch { Bad "could not rename the folder (is it open in Explorer or another program?): $($_.Exception.Message)"; $allOk = $false; continue }
        foreach ($l in @(Get-CloneArtifacts $c)) { Remove-Item -LiteralPath $l -Force -ErrorAction SilentlyContinue }
        $log = Join-Path $StateDir "logs\$Name.log"
        if (Test-Path -LiteralPath $log) { Move-Item -LiteralPath $log (Join-Path $StateDir "logs\$NewName.log") -Force -ErrorAction SilentlyContinue }
        $c.name = $NewName
        $c.dir = $newDir
        Write-Launcher $c
        if ($hadShortcuts) { Write-Shortcuts $c }
        Save-Clones $clones
        Ok "folder: $newDir"
        if ($hadShortcuts) { Ok "shortcuts: '$(Get-ShortcutTitle $c)'" }
        if ($c.product -eq 'code') { Ok "command: claude-$NewName" }
    }
    return $allOk
}

# ---------------------------------------------------------------------------------------------
# Finding sessions: which profile and which account has a session?
# ---------------------------------------------------------------------------------------------
# Only the start of a session file is read: id, folder, title and times come first
function Read-SessionHead([string]$File) {
    try {
        $fs = [IO.File]::Open($File, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
        try {
            $buf = New-Object byte[] ([Math]::Min($fs.Length, 16384))
            [void]$fs.Read($buf, 0, $buf.Length)
        } finally { $fs.Dispose() }
    } catch { return $null }
    $t = [Text.Encoding]::UTF8.GetString($buf)
    $h = [pscustomobject]@{ Title = ''; Cwd = ''; Last = [int64]0; Archived = $false }
    $str = '"((?:[^"\\]|\\.)*)"'
    if ($t -match ('"title"\s*:\s*' + $str)) { try { $h.Title = [regex]::Unescape($Matches[1]) } catch { $h.Title = $Matches[1] } }
    if ($t -match ('"cwd"\s*:\s*' + $str)) { try { $h.Cwd = [regex]::Unescape($Matches[1]) } catch { $h.Cwd = $Matches[1] } }
    if ($t -match '"lastActivityAt"\s*:\s*(\d+)') { $h.Last = [int64]$Matches[1] }
    if ($t -match '"isArchived"\s*:\s*true') { $h.Archived = $true }
    return $h
}

# Every session of the main profile and of every Desktop clone, one entry per account and session,
# with the profiles that have it
function Get-SessionIndex($Clones) {
    $profiles = @()
    $main = Resolve-ClaudeMainData (Get-Desk)
    if ($main) { $profiles += [pscustomobject]@{ Name = 'main'; Dir = $main } }
    foreach ($c in @($Clones | Where-Object { $_.product -eq 'desktop' -and (Test-Path -LiteralPath $_.dir) })) { $profiles += [pscustomobject]@{ Name = $c.name; Dir = $c.dir } }
    $index = @{}
    foreach ($p in $profiles) {
        foreach ($acc in @(Get-AccountFolders $p.Dir)) {
            foreach ($org in @(Get-ChildItem -LiteralPath (Join-Path (Join-Path $p.Dir 'claude-code-sessions') $acc) -Directory -Force -ErrorAction SilentlyContinue)) {
                foreach ($f in @(Get-ChildItem -LiteralPath $org.FullName -File -Force -Filter 'local_*.json' -ErrorAction SilentlyContinue)) {
                    $key = "$acc|$($f.Name)"
                    $e = $index[$key]
                    if (-not $e -or $f.LastWriteTimeUtc -gt $e.Stamp) {
                        $h = Read-SessionHead $f.FullName
                        if (-not $h) { continue }
                        $in = @()
                        if ($e) { $in = $e.In }
                        $e = [pscustomobject]@{ Account = $acc; Id = $f.BaseName; Title = $h.Title; Cwd = $h.Cwd; Last = $h.Last; Archived = $h.Archived; Stamp = $f.LastWriteTimeUtc; In = $in }
                        $index[$key] = $e
                    }
                    $e.In += $p.Name
                }
            }
        }
    }
    return @($index.Values)
}

function Invoke-Find([string]$Text) {
    $clones = @(Get-AllClones)
    $all = @(Get-SessionIndex $clones)
    $hits = @($all | Where-Object {
            $Text -eq '*' -or $_.Title.IndexOf($Text, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $_.Cwd.IndexOf($Text, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $_.Id.IndexOf($Text, [StringComparison]::OrdinalIgnoreCase) -ge 0
        } | Sort-Object Last -Descending)
    $limit = 20
    if ($Count -gt 0) { $limit = $Count }
    $what = "matching '$Text'"
    if ($Text -eq '*') { $what = 'most recent first' }
    Section ("Sessions {0} ({1} of {2})" -f $what, $hits.Count, $all.Count)
    if (-not $hits.Count) { Write-Host '    none - search for part of the title or the project folder, or * for all' -ForegroundColor DarkGray; return }
    $w = Get-Width
    Write-Host ('      {0,-12}{1,-16}{2}' -f 'LAST ACTIVE', 'ACCOUNT', 'TITLE') -ForegroundColor DarkGray
    foreach ($e in @($hits | Select-Object -First $limit)) {
        $when = $null
        if ($e.Last) { $when = [DateTimeOffset]::FromUnixTimeMilliseconds($e.Last).LocalDateTime }
        $sym = $G.Dot; $col = 'Cyan'
        if ($e.Archived) { $sym = $G.Ring; $col = 'DarkGray' }
        $title = $e.Title
        if (-not $title) { $title = '(no title)' }
        if ($e.Archived) { $title += '  (archived)' }
        Write-Host ('    ' + $sym + ' ') -ForegroundColor $col -NoNewline
        Write-Host ('{0,-12}' -f (Ago $when)) -ForegroundColor DarkGray -NoNewline
        Write-Host ('{0,-16}' -f (Cut (Get-AccountLabel $e.Account $clones) 15)) -NoNewline
        Write-Host (Cut $title ($w - 34)) -ForegroundColor White
        $where = 'in ' + ((@($e.In) | Select-Object -Unique) -join ', ')
        if ($e.Cwd) { $where += '   ' + (Short-Path $e.Cwd ($w - 30 - $where.Length)) }
        Write-Host ('                          ' + $where) -ForegroundColor DarkGray
    }
    if ($hits.Count -gt $limit) { Write-Host ("      ... {0} more (-Count {1} shows them)" -f ($hits.Count - $limit), $hits.Count) -ForegroundColor DarkGray }
}

# ---------------------------------------------------------------------------------------------
# Backup and restore of session lists
# ---------------------------------------------------------------------------------------------
$BackupDir = Join-Path $StateDir 'backups'

function Invoke-BackupAll {
    Step 'Saving the session lists'
    $targets = @()
    $main = Resolve-ClaudeMainData (Get-Desk)
    if ($main -and (-not $Names -or $Names -contains 'main')) { $targets += [pscustomobject]@{ name = '_main'; dir = $main } }
    $targets += @(Get-AllClones | Where-Object { $_.product -eq 'desktop' -and (Test-Path -LiteralPath $_.dir) -and (-not $Names -or $Names -contains $_.name) })
    $ok = $true
    foreach ($t in $targets) {
        $label = $t.name
        if ($label -eq '_main') { $label = 'main profile' }
        try {
            $zip = Backup-Sessions $t
            if ($zip) { Ok ('{0}: {1} ({2:N1} MB)' -f $label, (Split-Path $zip -Leaf), ((Get-Item -LiteralPath $zip).Length / 1MB)) }
            else { Info "${label}: no session list of its own yet" }
        } catch { Bad "${label}: $($_.Exception.Message)"; $ok = $false }
    }
    foreach ($f in @($Manifest, $AccountsFile)) {
        if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f (Join-Path $BackupDir ('{0}-{1}.json' -f [IO.Path]::GetFileNameWithoutExtension($f), (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Force }
    }
    Info "kept in $BackupDir (the newest 5 per profile); bring one back with -Restore <file>"
    return $ok
}

# Adds the sessions of a backup that the profile does not have. Nothing is overwritten or deleted.
function Invoke-Restore([string]$Zip, [string]$Target) {
    $file = $Zip
    if (-not (Test-Path -LiteralPath $file) -and (Test-Path -LiteralPath (Join-Path $BackupDir $Zip))) { $file = Join-Path $BackupDir $Zip }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        Bad "backup not found: $Zip"
        $list = @(Get-ChildItem -LiteralPath $BackupDir -Filter '*-sessions-*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 10)
        foreach ($b in $list) { Info $b.Name }
        return $false
    }
    $file = (Resolve-Path -LiteralPath $file).ProviderPath
    if (-not $Target -and (Split-Path $file -Leaf) -match '^(.+)-sessions-\d{8}-\d{6}\.zip$') { $Target = $Matches[1] }
    if ($Target -eq '_main') { $Target = 'main' }
    if (-not $Target) { Bad 'say where to restore to: -To <clone name> or -To main'; return $false }
    $desk = Get-Desk
    $procs = @(Get-DesktopProcesses $desk)
    if ($Target -eq 'main') { $dir = Resolve-ClaudeMainData $desk; $running = Test-MainRunning $procs }
    else {
        $c = @(Get-AllClones | Where-Object { $_.name -eq $Target -and $_.product -eq 'desktop' }) | Select-Object -First 1
        if (-not $c) { Bad "no Claude Desktop clone named '$Target'"; return $false }
        $dir = $c.dir
        $running = Test-ProfileRunning $dir $procs
    }
    if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { Bad "profile folder of '$Target' not found"; return $false }
    $li = Get-LinkInfo (Join-Path $dir 'claude-code-sessions')
    if ($li -and $li.IsLink) { Bad "the session folder of '$Target' is still a link - run -Repair first"; return $false }
    Step "Restoring $(Split-Path $file -Leaf) into '$Target'"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('cc-restore-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        [IO.Compression.ZipFile]::ExtractToDirectory($file, $tmp)
        $accs = @(Get-ChildItem -LiteralPath $tmp -Directory | Where-Object { $_.Name -match '^[0-9a-fA-F-]{36}$' } | ForEach-Object { $_.Name.ToLower() })
        $lock = Enter-CloneLock
        try { $r = Sync-SessionRoot $tmp (Join-Path $dir 'claude-code-sessions') $accs $false $false } finally { Exit-CloneLock $lock }
        Ok "$($r.Added) session entries added back; entries that were there are kept as they are"
        if ($r.Added -and $running) { Info "restart Claude ($Target) to see them" }
    } catch { Bad $_.Exception.Message; return $false }
    finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } }
    return $true
}

# ---------------------------------------------------------------------------------------------
# Updating and installing claude-clone itself
# ---------------------------------------------------------------------------------------------
function Get-LatestScript([int]$Timeout) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $text = (Invoke-WebRequest "$RawBase/claude-clone.ps1" -UseBasicParsing -TimeoutSec $Timeout).Content
    if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
    $v = ''
    if ($text -match "(?m)^\`$Version = '([0-9][^']*)'") { $v = $Matches[1] }
    return [pscustomobject]@{ Text = $text; Version = $v }
}

function Test-NewerVersion([string]$V) {
    if (-not $V) { return $false }
    try { return ([version]$V -gt [version]$Version) } catch { return $false }
}

# Once a day, for the dashboard; silent when offline (CLAUDE_CLONE_NO_UPDATE_CHECK=1 turns it off)
function Get-UpdateNotice {
    if ($env:CLAUDE_CLONE_NO_UPDATE_CHECK) { return '' }
    $f = Join-Path $StateDir 'update-check.json'
    $latest = ''
    try {
        if ((Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f).LastWriteTime -gt (Get-Date).AddDays(-1)) {
            $latest = "$(([IO.File]::ReadAllText($f) | ConvertFrom-Json).latest)"
        } else {
            try { $latest = (Get-LatestScript 4).Version } catch { }
            New-Item -ItemType Directory -Force $StateDir | Out-Null
            [IO.File]::WriteAllText($f, (ConvertTo-Json ([pscustomobject]@{ latest = $latest })))
        }
    } catch { }
    if (Test-NewerVersion $latest) { return $latest }
    return ''
}

function Invoke-Update {
    Step 'Looking for a newer claude-clone on GitHub'
    try { $new = Get-LatestScript 30 } catch { Bad "download failed: $($_.Exception.Message)"; return $false }
    if (-not $new.Version) { Bad 'the download does not look like claude-clone.ps1 - nothing changed'; return $false }
    $tokens = $null; $errs = $null
    [void][Management.Automation.Language.Parser]::ParseInput($new.Text, [ref]$tokens, [ref]$errs)
    if ($errs.Count) { Bad "the download has errors ($($errs[0].Message)) - nothing changed"; return $false }
    $self = $PSCommandPath
    if (-not (Test-NewerVersion $new.Version)) {
        Ok "claude-clone $Version is the newest version"
    } elseif (-not $self) {
        Warn "claude-clone $($new.Version) is available. This copy was not started from a file: start it the same way again, or install it with -Install."
        return $true
    } elseif (Test-Path -LiteralPath (Join-Path (Split-Path $self) '.git')) {
        Warn "claude-clone $($new.Version) is available. This copy is a git checkout: update it with 'git pull', then run -Repair."
        return $true
    } else {
        Copy-Item -LiteralPath $self "$self.bak" -Force
        [IO.File]::WriteAllText($self, $new.Text.Replace("`r`n", "`n").Replace("`n", "`r`n"), (New-Object Text.UTF8Encoding $false))
        Ok "updated $Version -> $($new.Version): $self (previous version kept as .bak)"
        try { Remove-Item -LiteralPath (Join-Path $StateDir 'update-check.json') -Force -ErrorAction SilentlyContinue } catch { }
        # launchers carry the runtime of the script that wrote them
        Step 'Bringing launchers up to date'
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $self, '-Repair')
        if ($Yes) { $a += '-Yes' }
        & powershell.exe @a
        return $true
    }
    $old = @(Get-Findings @(Get-AllClones) | Where-Object { $_.Fix -in @('launcher', 'mainlauncher') })
    if ($old.Count) { Info "$($old.Count) launcher(s) are older than this script: run -Repair" }
    return $true
}

# Copies claude-clone to ~\.claude-clone, adds the 'claude-clone' command and a Start menu entry
function Invoke-Install {
    Step 'Installing claude-clone'
    New-Item -ItemType Directory -Force $StateDir, $BinDir | Out-Null
    $dst = Join-Path $StateDir 'claude-clone.ps1'
    $self = $PSCommandPath
    if ($self -and -not (Test-SamePath $self $dst)) { Copy-Item -LiteralPath $self $dst -Force; Ok "copied to $dst" }
    elseif (-not $self) {
        try { $new = Get-LatestScript 30 } catch { Bad "download failed: $($_.Exception.Message)"; return $false }
        [IO.File]::WriteAllText($dst, $new.Text, (New-Object Text.UTF8Encoding $false))
        Ok "downloaded to $dst"
    } else { Ok "already installed in $dst" }
    $sh = Join-Path $StateDir 'claude-clone.sh'
    if ($self -and (Test-Path -LiteralPath (Join-Path (Split-Path $self) 'claude-clone.sh'))) { Copy-Item -LiteralPath (Join-Path (Split-Path $self) 'claude-clone.sh') $sh -Force }
    Write-Utf8 (Join-Path $BinDir 'claude-clone.cmd') "@echo off`r`npowershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$dst`" %*`r`n"
    Ok "command: claude-clone  ($(Join-Path $BinDir 'claude-clone.cmd'))"
    New-Item -ItemType Directory -Force $StartMenuDir | Out-Null
    $icon = Get-ClaudeIcon (Join-Path $StateDir 'claude.ico')
    New-Shortcut (Join-Path $StartMenuDir 'claude-clone.lnk') $dst $icon 'claude-clone dashboard' -Console
    Ok "Start menu: Claude Clones > claude-clone"
    if (-not $NoPath) {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if (($userPath -split ';') -notcontains $BinDir) {
            if (AskYesNo "Add $BinDir to your PATH so 'claude-clone' works in every terminal?" $true) {
                [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $BinDir), 'User')
                Ok 'PATH updated (open a new terminal)'
            }
        } else { Ok "$BinDir is on your PATH" }
    }
    Info 'update it later with: claude-clone -Update'
    return $true
}

function Get-KnownAccounts($Clones) {
    $ids = @()
    $main = Resolve-ClaudeMainData (Get-Desk)
    if ($main) { $ids += @(Get-ProfileAccounts $main) }
    foreach ($c in @($Clones | Where-Object { $_.product -eq 'desktop' -and (Test-Path -LiteralPath $_.dir) })) { $ids += @(Get-ProfileAccounts $c.dir) }
    return @($ids | Where-Object { $_ } | Select-Object -Unique)
}

function Invoke-NameAccount([string[]]$Pairs) {
    $known = @(Get-KnownAccounts @(Get-AllClones))
    $ok = $true
    # "a=x,b=y" works too (powershell -File cannot pass arrays); a comma inside a name stays
    $Pairs = @($Pairs | ForEach-Object { $_ -split ',(?=\s*[0-9a-fA-F-]{4,36}\s*=)' })
    foreach ($p in $Pairs) {
        if ($p -notmatch '^\s*([0-9a-fA-F-]{4,36})\s*=(.*)$') { Warn "use <account id>=<name>, for example 4f1c2a9e=Work (got '$p')"; $ok = $false; continue }
        $pre = $Matches[1].ToLower()
        $text = $Matches[2].Trim()
        $m = @($known | Where-Object { $_.StartsWith($pre) })
        if ($m.Count -ne 1) { Warn "no single known account starts with '$pre' (known: $(($known | ForEach-Object { $_.Substring(0, 8) }) -join ', '))"; $ok = $false; continue }
        if ($text) { $script:AccountNames[$m[0]] = $text; Ok "$($m[0].Substring(0, 8)) is now shown as '$text'" }
        else { $script:AccountNames.Remove($m[0]); Ok "$($m[0].Substring(0, 8)): name removed" }
    }
    Save-AccountNames $script:AccountNames
    return $ok
}

# ---------------------------------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------------------------------
function Select-Clone([string]$Title, $Clones) {
    $items = @($Clones | ForEach-Object { $app = 'Desktop'; if ($_.product -eq 'code') { $app = 'Code' }; '{0,-14} {1}' -f $_.name, $app }) + 'Back'
    $i = Select-Menu $Title $items 0
    if ($i -lt 0 -or $i -ge @($Clones).Count) { return $null }
    return @($Clones)[$i]
}

function Edit-CloneSettings($Clones) {
    $c = Select-Clone 'Settings of which clone?' $Clones
    if (-not $c) { return }
    $changed = $false
    while ($true) {
        $label = $c.label
        if (-not $label) { $label = '-' }
        $items = @("Label: $label")
        if ($c.product -eq 'desktop') {
            $items += "Session sync: $($c.sync)"
            $items += "Sync again when the window is closed: $(OnOff $c.syncOnExit)"
            $items += 'Copy MCP settings from the main profile again'
        }
        $items += "Colored letter on the icon: $(OnOff $c.badge)"
        $items += 'Rename'
        $items += 'Done'
        $i = Select-Menu "Settings of '$($c.name)' ($($c.product))" $items 0
        $pick = 'Done'
        if ($i -ge 0) { $pick = $items[$i] }
        if ($pick -like 'Label:*') { $c.label = Ask 'Label (shown as the account name)' $c.label; $changed = $true }
        elseif ($pick -like 'Session sync:*') {
            $modes = @('both', 'pull', 'off')
            $j = Select-Menu 'Session list' @('both - sync with the main profile in both directions', 'pull - only bring in sessions from the main profile', 'off - never sync') ([Array]::IndexOf($modes, $c.sync))
            if ($j -ge 0) { $c.sync = $modes[$j]; $changed = $true }
        }
        elseif ($pick -like 'Sync again*') { $c.syncOnExit = -not $c.syncOnExit; $changed = $true }
        elseif ($pick -like 'Copy MCP*') { Copy-MainSettings $c }
        elseif ($pick -like 'Colored letter*') { $c.badge = -not $c.badge; $changed = $true }
        elseif ($pick -eq 'Rename') {
            $new = Ask "New name for '$($c.name)'" ''
            if ($new) {
                if ($changed) { Save-CloneSettings $c; Save-Clones $Clones }
                [void](Invoke-Rename $c.name $new $c.product)
                return
            }
        } else {
            if ($changed) { Save-CloneSettings $c; Save-Clones $Clones }
            return
        }
    }
}

function Edit-Backups {
    $i = Select-Menu 'Session list backups' @('Back up all session lists now', 'Restore a backup (adds missing sessions, overwrites nothing)', 'Open the backup folder', 'Back') 0
    if ($i -eq 0) { [void](Invoke-BackupAll) }
    elseif ($i -eq 1) {
        $list = @(Get-ChildItem -LiteralPath $BackupDir -Filter '*-sessions-*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 15)
        if (-not $list.Count) { Warn 'No backups yet.'; return }
        $j = Select-Menu 'Restore which backup?' (@($list | ForEach-Object { '{0}  ({1:N1} MB)' -f $_.Name, ($_.Length / 1MB) }) + 'Back') 0
        if ($j -ge 0 -and $j -lt $list.Count) { [void](Invoke-Restore $list[$j].FullName '') }
    }
    elseif ($i -eq 2) { New-Item -ItemType Directory -Force $BackupDir | Out-Null; Start-Process explorer.exe -ArgumentList "`"$BackupDir`"" }
}

function Edit-AccountName($Clones) {
    $ids = @(Get-KnownAccounts $Clones)
    if (-not $ids.Count) { Warn 'No accounts found yet.'; return }
    $items = @($ids | ForEach-Object { '{0}  {1}' -f $_.Substring(0, 8), (Get-AccountLabel $_ $Clones) }) + 'Back'
    $i = Select-Menu 'Name which account?' $items 0
    if ($i -lt 0 -or $i -ge $ids.Count) { return }
    $cur = ''
    if ($script:AccountNames.ContainsKey($ids[$i])) { $cur = $script:AccountNames[$ids[$i]] }
    $text = Ask 'Name (empty removes it)' $cur
    [void](Invoke-NameAccount @("$($ids[$i])=$text"))
}

function Show-Dashboard {
    $update = Get-UpdateNotice
    while ($true) {
        try { Clear-Host } catch { }
        $script:AccountCache = @{}
        Show-Header
        if ($update) { Write-Host "  claude-clone $update is available - choose 'Update claude-clone'" -ForegroundColor Yellow }
        $desk = Get-Desk
        $code = Resolve-ClaudeCode
        $main = Resolve-ClaudeMainData $desk
        $procs = @(Get-DesktopProcesses $desk)
        $clones = @(Get-AllClones)
        Show-Installed $desk $code
        Show-MainProfile $desk $main $clones $procs
        Show-CloneTable $clones $procs
        Show-Health @(Get-Findings $clones)

        $menu = @('Launch', 'Find a session', 'Create new clones', 'Check & repair', 'Sync sessions now', 'Clone settings (label, sync, rename, ...)',
            'Name an account', 'Move a profile', 'Back up / restore session lists', 'Remove a clone', 'Open a profile folder', 'Update claude-clone', 'Quit')
        $default = 0
        if (-not $clones.Count) { $default = 2 }
        $choice = Select-Menu 'What would you like to do?' $menu $default
        $pick = 'Quit'
        if ($choice -ge 0) { $pick = $menu[$choice] }
        if ($pick -eq 'Launch') {
            $items = @('main  (Claude as usual)') + @($clones | ForEach-Object { $app = 'Desktop'; if ($_.product -eq 'code') { $app = 'Code' }; '{0,-14} {1}' -f $_.name, $app }) + 'Back'
            $i = Select-Menu 'Launch what?' $items 0
            if ($i -eq 0) { Invoke-Launch 'main'; Start-Sleep -Milliseconds 900 }
            elseif ($i -gt 0 -and $i -le $clones.Count) { Invoke-Launch $clones[$i - 1]; Wait-Key }
        }
        elseif ($pick -eq 'Find a session') { Invoke-Find (Ask 'Search for (part of the title or project folder, * for all)' '*'); Wait-Key }
        elseif ($pick -eq 'Create new clones') { Invoke-Create; Wait-Key }
        elseif ($pick -eq 'Check & repair') { [void](Invoke-Doctor $true); Wait-Key }
        elseif ($pick -eq 'Sync sessions now') { Invoke-Sync; Wait-Key }
        elseif ($pick -like 'Name an*') { Edit-AccountName $clones; Wait-Key }
        elseif ($pick -like 'Back up*') { Edit-Backups; Wait-Key }
        elseif ($pick -like 'Update*') { [void](Invoke-Update); Wait-Key; if ($PSCommandPath) { & $PSCommandPath; return } }
        elseif ($pick -eq 'Quit') { Write-Host ''; return }
        elseif (-not $clones.Count) { Warn 'No clones yet.'; Wait-Key }
        elseif ($pick -like 'Clone settings*') { Edit-CloneSettings $clones; Wait-Key }
        elseif ($pick -like 'Move*') {
            $c = Select-Clone 'Move which profile?' $clones
            if ($c) { [void](Invoke-Move $c.name ''); Wait-Key }
        }
        elseif ($pick -like 'Remove*') {
            $c = Select-Clone 'Remove which clone?' $clones
            if ($c) {
                $how = Select-Menu "Remove '$($c.name)'" @('Remove shortcuts and launcher, keep the profile', 'Remove everything and delete the profile (signs it out; the session list is saved first)', 'Back') 0
                if ($how -eq 0) { [void](Invoke-Remove $c.name $false $false); Wait-Key }
                elseif ($how -eq 1) { [void](Invoke-Remove $c.name $true $false); Wait-Key }
            }
        }
        elseif ($pick -like 'Open*') {
            $c = Select-Clone 'Open which profile folder?' $clones
            if ($c -and (Test-Path -LiteralPath $c.dir)) { Start-Process explorer.exe -ArgumentList "`"$($c.dir)`"" }
        }
    }
}

function Show-Status {
    Show-Header
    $desk = Get-Desk
    $main = Resolve-ClaudeMainData $desk
    $procs = @(Get-DesktopProcesses $desk)
    $clones = @(Get-AllClones)
    Show-Installed $desk (Resolve-ClaudeCode)
    Show-MainProfile $desk $main $clones $procs
    Show-CloneTable $clones $procs
    Show-Health @(Get-Findings $clones)
    Write-Host ''
}

# ---------------------------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------------------------
if ($List) { Show-Status; exit 0 }
if ($Doctor -or $Repair) {
    Show-Header
    if ($Repair) { Step 'Checking and repairing all profiles' } else { Step 'Checking all profiles (nothing is changed)' }
    $left = Invoke-Doctor ([bool]$Repair)
    Write-Host ''
    if ($left) { exit 1 } else { exit 0 }
}
if ($Sync) { Invoke-Sync; Write-Host ''; exit 0 }
if ($BoundParams.ContainsKey('Find')) {
    $q = $Find
    if (-not $q) { $q = '*' }
    Invoke-Find $q
    Write-Host ''
    exit 0
}
if ($Backup) { if (Invoke-BackupAll) { exit 0 } else { exit 1 } }
if ($Restore) { if (Invoke-Restore $Restore $To) { exit 0 } else { exit 1 } }
if ($Update) { if (Invoke-Update) { exit 0 } else { exit 1 } }
if ($Install) { if (Invoke-Install) { exit 0 } else { exit 1 } }
if ($NameAccount) { if (Invoke-NameAccount $NameAccount) { exit 0 } else { exit 1 } }
if ($Set) { if (Invoke-Set $Set) { exit 0 } else { exit 1 } }
if ($Move) { if (Invoke-Move $Move $To) { exit 0 } else { exit 1 } }
if ($Rename) { if (Invoke-Rename $Rename $To) { exit 0 } else { exit 1 } }
if ($Remove) {
    if (Invoke-Remove $Remove ([bool]$Purge) $true) { exit 0 } else { exit 1 }
}
if ($Launch) {
    if ($Launch -eq 'main') { Invoke-Launch 'main'; exit 0 }
    $c = @(Find-Clones $Launch)
    if (-not $c.Count) { Say "No clone named '$Launch'." 'Yellow'; exit 1 }
    foreach ($x in $c) { Invoke-Launch $x }
    exit 0
}

if ($Product -or $Names -or $Count -or $Path -or $Yes -or -not $CanReadKey) {
    Show-Header
    Invoke-Create
    Write-Host ''
    exit 0
}
Show-Dashboard
