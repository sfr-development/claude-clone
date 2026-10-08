<#
.SYNOPSIS
    claude-clone - run several Claude accounts side by side.

.DESCRIPTION
    Finds Claude Desktop and Claude Code on this machine and creates extra, fully separate
    profiles ("clones") for them. Every clone signs in on its own, keeps its own windows and
    gets its own shortcut with the Claude icon. Your main installation is never modified.

    Windows: run with Windows PowerShell 5.1 or PowerShell 7.
    macOS / Linux: this script hands over to claude-clone.sh.

.EXAMPLE
    .\claude-clone.ps1                       # interactive
    .\claude-clone.ps1 -Product desktop -Names work,personal -Yes
    .\claude-clone.ps1 -List
    .\claude-clone.ps1 -Launch work
    .\claude-clone.ps1 -Remove work -Purge
    .\claude-clone.ps1 -Repair
#>
[CmdletBinding()]
param(
    [ValidateSet('desktop', 'code', 'both')]
    [string]$Product,
    [int]$Count,
    [string[]]$Names,
    [string]$Path,
    [switch]$NoShareSessions,
    [switch]$NoCopySettings,
    [switch]$NoShortcuts,
    [switch]$NoMainShortcut,
    [switch]$NoPath,
    [switch]$List,
    [string]$Remove,
    [switch]$Purge,
    [string]$Launch,
    [switch]$Repair,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$Version = '1.2.0'
$RawBase = 'https://raw.githubusercontent.com/sfr-development/claude-clone/main'

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
    if ($NoShareSessions) { $fwd += '--no-share-sessions' }
    if ($NoCopySettings) { $fwd += '--no-copy-settings' }
    if ($NoShortcuts) { $fwd += '--no-shortcuts' }
    if ($NoMainShortcut) { $fwd += '--no-main-shortcut' }
    if ($List) { $fwd += '--list' }
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

# ---------------------------------------------------------------------------------------------
# State (manifest of created clones)
# ---------------------------------------------------------------------------------------------
$StateDir = Join-Path $env:USERPROFILE '.claude-clone'
$Manifest = Join-Path $StateDir 'clones.json'
$BinDir = Join-Path $StateDir 'bin'

function Get-Clones {
    if (-not (Test-Path $Manifest)) { return @() }
    $raw = Get-Content $Manifest -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $data = $raw | ConvertFrom-Json
    return @($data | ForEach-Object { $_ })
}

function Save-Clones($Clones) {
    New-Item -ItemType Directory -Force $StateDir | Out-Null
    $json = ConvertTo-Json -InputObject @($Clones) -Depth 5
    [IO.File]::WriteAllText($Manifest, $json, (New-Object Text.UTF8Encoding $false))
}

# ---------------------------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------------------------
# The same resolver is embedded into every launcher, so a launcher keeps working after the
# Claude app updates itself (the Microsoft Store path changes with every version).
$DesktopResolver = @'
function Resolve-ClaudeDesktop {
    $pkg = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like '*Claude*' -and $_.InstallLocation -and (Test-Path (Join-Path $_.InstallLocation 'app\Claude.exe'))
    } | Sort-Object Version -Descending | Select-Object -First 1
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
'@

$CodeResolver = @'
function Resolve-ClaudeCode {
    $cmd = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    foreach ($c in @((Join-Path $env:USERPROFILE '.local\bin\claude.exe'), (Join-Path $env:APPDATA 'npm\claude.cmd'))) {
        if (Test-Path $c) { return $c }
    }
    # Claude Desktop ships its own copy. The Microsoft Store version keeps it in its private AppData
    # (Packages\<family>\LocalCache\Roaming), which normal processes do not see under %APPDATA%.
    $roots = @(Join-Path $env:APPDATA 'Claude\claude-code')
    $roots += @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'LocalCache\Roaming\Claude\claude-code' })
    $bundled = $roots | Where-Object { Test-Path $_ } | ForEach-Object { Get-ChildItem $_ -Recurse -Filter claude.exe -ErrorAction SilentlyContinue } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($bundled) { return $bundled.FullName }
    return $null
}
'@

. ([scriptblock]::Create($DesktopResolver))
. ([scriptblock]::Create($CodeResolver))

# Main Claude Desktop profile. The Microsoft Store (MSIX) version virtualizes %APPDATA%: its real data
# lives in %LOCALAPPDATA%\Packages\<family>\LocalCache\Roaming\Claude and is invisible to normal processes.
$MainDesktopData = Join-Path $env:APPDATA 'Claude'
$probe = Resolve-ClaudeDesktop
if ($probe -and $probe.Pfn) {
    $virt = Join-Path $env:LOCALAPPDATA ('Packages\' + $probe.Pfn + '\LocalCache\Roaming\Claude')
    if (Test-Path $virt) { $MainDesktopData = $virt }
}
$DefaultProfileBase = Join-Path $env:USERPROFILE '.claude-clone\profiles'
$MainCodeConfig = Join-Path $env:USERPROFILE '.claude'
$DesktopDir = [Environment]::GetFolderPath('Desktop')
$StartMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude Clones'

# ---------------------------------------------------------------------------------------------
# Icon: build a real .ico from the app's own logo (PNG-in-ICO), so shortcuts survive updates
# ---------------------------------------------------------------------------------------------
function Save-PngAsIco([string]$Png, [string]$Ico) {
    $bytes = [IO.File]::ReadAllBytes($Png)
    $w = ([int]$bytes[16] -shl 24) -bor ([int]$bytes[17] -shl 16) -bor ([int]$bytes[18] -shl 8) -bor [int]$bytes[19]
    $h = ([int]$bytes[20] -shl 24) -bor ([int]$bytes[21] -shl 16) -bor ([int]$bytes[22] -shl 8) -bor [int]$bytes[23]
    $ms = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter($ms)
    $bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]1)
    $bw.Write([byte]($(if ($w -ge 256) { 0 } else { $w })))
    $bw.Write([byte]($(if ($h -ge 256) { 0 } else { $h })))
    $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([UInt16]1); $bw.Write([UInt16]32)
    $bw.Write([UInt32]$bytes.Length); $bw.Write([UInt32]22)
    $bw.Write($bytes)
    $bw.Flush()
    [IO.File]::WriteAllBytes($Ico, $ms.ToArray())
}

function Get-ClaudeIcon([string]$Target) {
    $d = Resolve-ClaudeDesktop
    if ($d) {
        $png = Get-ChildItem (Join-Path $d.Root 'assets') -Filter 'Square44x44Logo.targetsize-256*.png' -ErrorAction SilentlyContinue |
            Sort-Object { $_.Name -notlike '*unplated*' } | Select-Object -First 1
        if (-not $png) {
            $png = Get-ChildItem $d.Root -Recurse -Filter '*Logo*.png' -ErrorAction SilentlyContinue |
                Sort-Object Length -Descending | Select-Object -First 1
        }
        if ($png) { Save-PngAsIco $png.FullName $Target; return $Target }
        $ico = Get-ChildItem $d.Root -Filter '*.ico' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ico) { Copy-Item $ico.FullName $Target -Force; return $Target }
        try {
            Add-Type -AssemblyName System.Drawing
            $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($d.Exe)
            $fs = [IO.File]::Create($Target); $icon.Save($fs); $fs.Close()
            return $Target
        } catch { }
    }
    return $null
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

function Write-Utf8([string]$File, [string]$Text) {
    [IO.File]::WriteAllText($File, $Text, (New-Object Text.UTF8Encoding $false))
}

function New-Junction([string]$Link, [string]$Target) {
    if (Test-Path $Link) { return $false }
    New-Item -ItemType Directory -Force $Target | Out-Null
    cmd /c mklink /J "`"$Link`"" "`"$Target`"" | Out-Null
    return (Test-Path $Link)
}

# Removes a folder WITHOUT following junctions/symlinks inside it (Windows PowerShell 5.1 would
# otherwise delete the contents of the linked main profile).
function Remove-Links([string]$Dir) {
    foreach ($item in @(Get-ChildItem -LiteralPath $Dir -Force -Directory -ErrorAction SilentlyContinue)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($item.FullName, $false) }
        else { Remove-Links $item.FullName }
    }
}

function Remove-FolderSafely([string]$Dir) {
    if (-not (Test-Path $Dir)) { return }
    Remove-Links $Dir
    # rd with the \\?\ prefix also removes paths longer than 260 characters
    $full = (Resolve-Path -LiteralPath $Dir).ProviderPath
    cmd /c "rd /s /q `"\\?\$full`"" 2>$null
    if (Test-Path -LiteralPath $Dir) { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $Dir) { Warn "Could not delete everything in $Dir" }
}

# ---------------------------------------------------------------------------------------------
# Create clones
# ---------------------------------------------------------------------------------------------
function New-DesktopClone([string]$Name, [string]$Base, [bool]$Share, [bool]$CopySettings, [bool]$Shortcuts) {
    $dir = Join-Path $Base "Claude-$Name"
    if (Test-Path $dir) { Warn "Profile folder already exists, reusing it: $dir" }
    New-Item -ItemType Directory -Force $dir | Out-Null

    if ($Share) {
        if (New-Junction (Join-Path $dir 'claude-code-sessions') (Join-Path $MainDesktopData 'claude-code-sessions')) {
            Ok 'session list shared with the main profile (each account still sees only its own sessions)'
        }
        if (Test-Path (Join-Path $MainDesktopData 'claude-code')) {
            if (New-Junction (Join-Path $dir 'claude-code') (Join-Path $MainDesktopData 'claude-code')) { Ok 'Claude Code runtime shared (no second download)' }
        }
    }
    if ($CopySettings) {
        $cfg = Join-Path $MainDesktopData 'claude_desktop_config.json'
        if (Test-Path $cfg) { Copy-Item $cfg (Join-Path $dir 'claude_desktop_config.json') -Force; Ok 'MCP / desktop settings copied' }
        foreach ($x in @('Claude Extensions', 'Claude Extensions Settings')) {
            $src = Join-Path $MainDesktopData $x
            if ((Test-Path $src) -and -not (Test-Path (Join-Path $dir $x))) {
                # robocopy copies paths longer than 260 characters (extension virtualenvs often are)
                robocopy "$src" "$(Join-Path $dir $x)" /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
                if ($LASTEXITCODE -lt 8) { Ok "$x copied" } else { Warn "$x could not be copied completely (robocopy $LASTEXITCODE)" }
                $global:LASTEXITCODE = 0
            }
        }
    }

    $launcher = Join-Path $dir 'launch.ps1'
    Write-Utf8 $launcher (@"
# claude-clone $Version - Claude Desktop, profile '$Name'
$DesktopResolver
`$d = Resolve-ClaudeDesktop
if (-not `$d) { Write-Error 'Claude Desktop not found'; exit 1 }
Start-Process -FilePath `$d.Exe -ArgumentList '--user-data-dir="$dir"'
"@)
    Ok "launcher: $launcher"

    $icon = Get-ClaudeIcon (Join-Path $dir 'claude.ico')
    $links = @()
    if ($Shortcuts) {
        $title = "Claude ($Name)"
        $lnk = Join-Path $DesktopDir "$title.lnk"
        New-Shortcut $lnk $launcher $icon "Claude Desktop - profile $Name (claude-clone)"
        $links += $lnk
        New-Item -ItemType Directory -Force $StartMenuDir | Out-Null
        $lnk2 = Join-Path $StartMenuDir "$title.lnk"
        New-Shortcut $lnk2 $launcher $icon "Claude Desktop - profile $Name (claude-clone)"
        $links += $lnk2
        Ok "shortcuts: Desktop and Start menu ('$title')"
    }
    return [pscustomobject]@{ name = $Name; product = 'desktop'; dir = $dir; launcher = $launcher; shortcuts = $links }
}

function New-CodeClone([string]$Name, [string]$Base, [bool]$CopySettings, [bool]$Shortcuts) {
    $dir = Join-Path $Base ".claude-$Name"
    if (Test-Path $dir) { Warn "Config folder already exists, reusing it: $dir" }
    New-Item -ItemType Directory -Force $dir | Out-Null

    if ($CopySettings -and (Test-Path $MainCodeConfig)) {
        foreach ($x in @('CLAUDE.md', 'settings.json', 'keybindings.json')) {
            $src = Join-Path $MainCodeConfig $x
            if (Test-Path $src) { Copy-Item $src (Join-Path $dir $x) -Force }
        }
        foreach ($x in @('skills', 'agents', 'commands', 'output-styles')) {
            $src = Join-Path $MainCodeConfig $x
            if ((Test-Path $src) -and -not (Test-Path (Join-Path $dir $x))) { Copy-Item $src (Join-Path $dir $x) -Recurse }
        }
        Ok 'CLAUDE.md, settings, skills, agents and commands copied (never credentials)'
    }

    New-Item -ItemType Directory -Force $BinDir | Out-Null
    $ps1 = Join-Path $dir 'launch.ps1'
    Write-Utf8 $ps1 (@"
# claude-clone $Version - Claude Code, profile '$Name'
$CodeResolver
`$exe = Resolve-ClaudeCode
if (-not `$exe) { Write-Error 'Claude Code not found'; exit 1 }
`$env:CLAUDE_CONFIG_DIR = '$dir'
& `$exe @args
"@)
    $cmd = Join-Path $BinDir "claude-$Name.cmd"
    Write-Utf8 $cmd "@echo off`r`npowershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$ps1`" %*`r`n"
    Ok "command: claude-$Name  ($cmd)"

    $links = @()
    if ($Shortcuts) {
        $icon = Get-ClaudeIcon (Join-Path $dir 'claude.ico')
        $title = "Claude Code ($Name)"
        $lnk = Join-Path $DesktopDir "$title.lnk"
        New-Shortcut $lnk $ps1 $icon "Claude Code - profile $Name (claude-clone)" -Console
        $links += $lnk
        Ok "shortcut: Desktop ('$title')"
    }
    return [pscustomobject]@{ name = $Name; product = 'code'; dir = $dir; launcher = $cmd; shortcuts = $links }
}

function New-MainShortcuts([bool]$Desktop, [bool]$Code) {
    $links = @()
    New-Item -ItemType Directory -Force $StateDir | Out-Null
    if ($Desktop) {
        $launcher = Join-Path $StateDir 'launch-main-desktop.ps1'
        Write-Utf8 $launcher (@"
# claude-clone $Version - Claude Desktop, main profile
$DesktopResolver
`$d = Resolve-ClaudeDesktop
if (-not `$d) { Write-Error 'Claude Desktop not found'; exit 1 }
Start-Process -FilePath `$d.Exe
"@)
        $icon = Get-ClaudeIcon (Join-Path $StateDir 'claude.ico')
        $lnk = Join-Path $DesktopDir 'Claude (main).lnk'
        New-Shortcut $lnk $launcher $icon 'Claude Desktop - main profile (claude-clone)'
        $links += $lnk
        Ok "shortcut: Desktop ('Claude (main)')"
    }
    if ($Code) {
        $launcher = Join-Path $StateDir 'launch-main-code.ps1'
        Write-Utf8 $launcher (@"
# claude-clone $Version - Claude Code, main profile
$CodeResolver
`$exe = Resolve-ClaudeCode
if (-not `$exe) { Write-Error 'Claude Code not found'; exit 1 }
& `$exe @args
"@)
        $icon = Get-ClaudeIcon (Join-Path $StateDir 'claude.ico')
        $lnk = Join-Path $DesktopDir 'Claude Code (main).lnk'
        New-Shortcut $lnk $launcher $icon 'Claude Code - main profile (claude-clone)' -Console
        $links += $lnk
        Ok "shortcut: Desktop ('Claude Code (main)')"
    }
    return $links
}

# ---------------------------------------------------------------------------------------------
# Terminal UI (box drawing via char codes keeps this file ASCII for Windows PowerShell 5.1)
# ---------------------------------------------------------------------------------------------
$G = @{
    TL = [char]0x256D; TR = [char]0x256E; BL = [char]0x2570; BR = [char]0x256F; H = [char]0x2500; V = [char]0x2502
    Dot = [char]0x25CF; Ring = [char]0x25CB; Cross = [char]0x2715; Pick = [char]0x203A
}
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch { }

$CanReadKey = $false
try { $CanReadKey = ($Host.Name -eq 'ConsoleHost') -and -not [Console]::IsInputRedirected -and -not $Yes } catch { }

function Get-Width { try { return [Math]::Max(60, [Math]::Min(100, [Console]::WindowWidth - 2)) } catch { return 80 } }

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

function Short-Path([string]$P) {
    if (-not $P) { return '' }
    $p2 = $P.Replace($env:USERPROFILE, '~')
    $max = (Get-Width) - 58
    if ($max -lt 20) { $max = 20 }
    if ($p2.Length -gt $max) { $p2 = '...' + $p2.Substring($p2.Length - $max + 3) }
    return $p2
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
    $first = Get-Content -LiteralPath $File -TotalCount 1
    if ($first -match "^# claude-clone \S+ - Claude (Desktop|Code), profile '([^']+)'") {
        $prod = 'desktop'
        if ($Matches[1] -eq 'Code') { $prod = 'code' }
        return @{ product = $prod; name = $Matches[2] }
    }
    return $null
}

# Manifest plus every claude-clone profile found on disk (adopted into the manifest).
function Get-AllClones {
    $clones = @(Get-Clones)
    $known = @{}
    foreach ($c in $clones) { $known[$c.dir.ToLower()] = $true }
    $cands = @()
    foreach ($b in @($DefaultProfileBase, $env:APPDATA)) {
        if ($b -and (Test-Path $b)) { $cands += @(Get-ChildItem -LiteralPath $b -Directory -Filter 'Claude-*' -ErrorAction SilentlyContinue) }
    }
    $cands += @(Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Force -Filter '.claude-*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.claude-clone' })
    $added = $false
    foreach ($d in $cands) {
        if ($known.ContainsKey($d.FullName.ToLower())) { continue }
        $h = Read-LauncherHeader (Join-Path $d.FullName 'launch.ps1')
        if (-not $h) { continue }
        $launcher = Join-Path $d.FullName 'launch.ps1'
        if ($h.product -eq 'code') { $launcher = Join-Path $BinDir "claude-$($h.name).cmd" }
        $clones += [pscustomobject]@{ name = $h.name; product = $h.product; dir = $d.FullName; launcher = $launcher; shortcuts = @() }
        $known[$d.FullName.ToLower()] = $true
        $added = $true
    }
    if ($added) { Save-Clones $clones }
    return $clones
}

function Get-ClaudeProcesses {
    try { return @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction Stop | Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--type=' }) } catch { return @() }
}

function Get-CloneStatus($Clone, $Procs) {
    $st = [ordered]@{ State = 'missing'; LastUsed = $null }
    if (-not (Test-Path -LiteralPath $Clone.dir)) { return $st }
    $st.State = 'not signed in'
    if ($Clone.product -eq 'desktop') {
        $cfg = Join-Path $Clone.dir 'config.json'
        if (Test-Path -LiteralPath $cfg) {
            # only the presence of the token cache is checked, never its value
            if ([IO.File]::ReadAllText($cfg) -match '"oauth:tokenCache(V2)?"\s*:\s*"[^"]') { $st.State = 'signed in' }
        }
        $st.LastUsed = @('Local State', 'config.json', 'Preferences') | ForEach-Object { Join-Path $Clone.dir $_ } |
            Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { (Get-Item -LiteralPath $_).LastWriteTime } |
            Sort-Object -Descending | Select-Object -First 1
        foreach ($p in $Procs) {
            if ($p.CommandLine.IndexOf($Clone.dir, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $st.State = 'running'; break }
        }
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
        Write-Host ('{0,-16}{1}' -f 'Claude Code', $(if ($ver) { $ver } else { Short-Path $Code }))
    } else {
        Write-Host ('    ' + $G.Ring + ' ') -ForegroundColor DarkGray -NoNewline
        Write-Host 'Claude Code     not found' -ForegroundColor DarkGray
    }
}

function Show-CloneTable($Clones) {
    $procs = Get-ClaudeProcesses
    Section ("Your clones ({0})" -f @($Clones).Count)
    if (-not @($Clones).Count) {
        Write-Host '    none yet - choose "Create new clones"' -ForegroundColor DarkGray
    } else {
        Write-Host ('      {0,-14}{1,-9}{2,-15}{3,-11}{4}' -f 'NAME', 'APP', 'STATUS', 'LAST USED', 'FOLDER') -ForegroundColor DarkGray
        foreach ($c in $Clones) {
            $st = Get-CloneStatus $c $procs
            $sym = $G.Dot; $col = 'Gray'
            switch ($st.State) {
                'running' { $col = 'Green' }
                'signed in' { $col = 'Cyan' }
                'not signed in' { $sym = $G.Ring; $col = 'DarkGray' }
                'missing' { $sym = $G.Cross; $col = 'Red' }
            }
            $app = 'Desktop'
            if ($c.product -eq 'code') { $app = 'Code' }
            Write-Host ('    ' + $sym + ' ') -ForegroundColor $col -NoNewline
            Write-Host ('{0,-14}' -f $c.name) -ForegroundColor White -NoNewline
            Write-Host ('{0,-9}' -f $app) -NoNewline
            Write-Host ('{0,-15}' -f $st.State) -ForegroundColor $col -NoNewline
            Write-Host ('{0,-11}' -f (Ago $st.LastUsed)) -ForegroundColor DarkGray -NoNewline
            Write-Host (Short-Path $c.dir) -ForegroundColor DarkGray
        }
    }
    # Profiles started with --user-data-dir that claude-clone does not manage (other tools, manual starts)
    $managed = @($Clones | ForEach-Object { $_.dir })
    $foreign = @()
    foreach ($p in $procs) {
        if ($p.CommandLine -match '--user-data-dir="?([^"]+?)"?(\s|$)') {
            $d = $Matches[1]
            if (-not ($managed | Where-Object { $_ -ieq $d }) -and ($foreign -notcontains $d)) { $foreign += $d }
        }
    }
    foreach ($d in $foreign) {
        Write-Host ('    ' + $G.Dot + ' ') -ForegroundColor DarkYellow -NoNewline
        Write-Host ('{0,-14}{1,-9}{2,-15}{3,-11}{4}' -f '(unmanaged)', 'Desktop', 'running', '', (Short-Path $d)) -ForegroundColor DarkYellow
    }
}

# ---------------------------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------------------------
function Invoke-Launch($Clone) {
    if (-not (Test-Path -LiteralPath $Clone.dir)) { Warn "Profile folder is missing: $($Clone.dir)"; return }
    $ps1 = Join-Path $Clone.dir 'launch.ps1'
    if ($Clone.product -eq 'desktop') {
        & $ps1
        Ok "started Claude Desktop '$($Clone.name)'"
    } else {
        $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
        if ($wt) { Start-Process $wt.Source -ArgumentList "powershell.exe -NoLogo -NoExit -ExecutionPolicy Bypass -File `"$ps1`"" }
        else { Start-Process powershell.exe -ArgumentList "-NoLogo -NoExit -ExecutionPolicy Bypass -File `"$ps1`"" }
        Ok "opened Claude Code '$($Clone.name)' in a new terminal"
    }
}

function Invoke-Remove([string]$Name, [bool]$DeleteProfile, [bool]$AskDelete = $true) {
    $clones = @(Get-AllClones)
    $hit = @($clones | Where-Object { $_.name -eq $Name })
    if (-not $hit.Count) { Say "No clone named '$Name'." 'Yellow'; return $false }
    foreach ($c in $hit) {
        Step "Removing $($c.product) clone '$($c.name)'"
        foreach ($l in @($c.shortcuts)) { if ($l -and (Test-Path -LiteralPath $l)) { Remove-Item -LiteralPath $l -Force; Ok "removed $l" } }
        if ($c.product -eq 'code' -and $c.launcher -and (Test-Path -LiteralPath $c.launcher)) { Remove-Item -LiteralPath $c.launcher -Force; Ok "removed $($c.launcher)" }
        $del = $DeleteProfile
        if (-not $del -and $AskDelete) { $del = AskYesNo "Also delete the profile folder $($c.dir)? This signs the account out on this machine." $false }
        if ($del) {
            Remove-FolderSafely $c.dir
            Ok "deleted $($c.dir) (shared folders of the main profile are untouched)"
        } else {
            Say "    kept $($c.dir)"
        }
    }
    Save-Clones @($clones | Where-Object { $_.name -ne $Name })
    return $true
}

# Re-creates launcher icons and shortcuts of every clone (after moving the Desktop, deleting a shortcut, ...)
function Invoke-Repair {
    $clones = @(Get-AllClones)
    if (-not $clones.Count) { Say '    No clones to repair.' 'DarkGray'; return }
    $out = @()
    foreach ($c in $clones) {
        if (-not (Test-Path -LiteralPath $c.dir)) { Warn "skipped '$($c.name)': profile folder missing"; $out += $c; continue }
        $ps1 = Join-Path $c.dir 'launch.ps1'
        $icon = Get-ClaudeIcon (Join-Path $c.dir 'claude.ico')
        $links = @()
        if ($c.product -eq 'desktop') {
            $title = "Claude ($($c.name))"
            New-Item -ItemType Directory -Force $StartMenuDir | Out-Null
            foreach ($l in @((Join-Path $DesktopDir "$title.lnk"), (Join-Path $StartMenuDir "$title.lnk"))) {
                New-Shortcut $l $ps1 $icon "Claude Desktop - profile $($c.name) (claude-clone)"
                $links += $l
            }
        } else {
            $title = "Claude Code ($($c.name))"
            $l = Join-Path $DesktopDir "$title.lnk"
            New-Shortcut $l $ps1 $icon "Claude Code - profile $($c.name) (claude-clone)" -Console
            $links += $l
            New-Item -ItemType Directory -Force $BinDir | Out-Null
            Write-Utf8 (Join-Path $BinDir "claude-$($c.name).cmd") "@echo off`r`npowershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$ps1`" %*`r`n"
        }
        $c.shortcuts = $links
        $out += $c
        Ok "repaired '$($c.name)' ($($c.product))"
    }
    Save-Clones $out
}

function Invoke-Create {
    $prod = $Product; $names = $Names; $cnt = $Count
    Section 'Create new clones'
    $desk = Resolve-ClaudeDesktop
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

    $existing = @(Get-AllClones | ForEach-Object { $_.name })
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
    foreach ($n in $names) { if ($existing -contains $n) { Warn "'$n' already exists - its profile is kept and its launcher refreshed" } }

    $desktopBase = $Path; $codeBase = $Path
    if (-not $Path) {
        if ($doDesktop) { $desktopBase = Ask 'Where to store Claude Desktop profiles?' $DefaultProfileBase }
        if ($doCode) { $codeBase = Ask 'Where to store Claude Code profiles?' $env:USERPROFILE }
    }
    foreach ($b in @($desktopBase, $codeBase)) {
        if ($b -and ($b -match '(?i)OneDrive|Dropbox|Google Drive|iCloud|Nextcloud')) {
            Warn "$b looks like a cloud-synced folder. Live app profiles there cause sync conflicts and slow Claude down."
            if (-not (AskYesNo 'Use it anyway?' $false)) { Say '  Cancelled. Pick a local folder.'; return }
        }
    }

    $share = -not $NoShareSessions; $copy = -not $NoCopySettings; $links = -not $NoShortcuts; $mainLink = -not $NoMainShortcut
    if (-not $Yes) {
        if ($doDesktop -and -not $NoShareSessions) { $share = AskYesNo 'Share the Desktop session list with the main profile (each account still sees only its own sessions)?' $true }
        if (-not $NoCopySettings) { $copy = AskYesNo 'Copy your settings (MCP servers, CLAUDE.md, skills; never login data)?' $true }
        if (-not $NoShortcuts) { $links = AskYesNo 'Create shortcuts with the Claude icon?' $true }
        if ($links -and -not $NoMainShortcut) { $mainLink = AskYesNo "Also create a 'main' shortcut for your current account?" $true }
    }

    Step 'Plan'
    foreach ($n in $names) {
        if ($doDesktop) { Say "    Claude Desktop  '$n'  ->  $(Join-Path $desktopBase "Claude-$n")" }
        if ($doCode) { Say "    Claude Code     '$n'  ->  $(Join-Path $codeBase ".claude-$n")" }
    }
    if (-not (AskYesNo 'Go ahead?' $true)) { Say '  Cancelled.'; return }

    $clones = @(Get-Clones)
    foreach ($n in $names) {
        if ($doDesktop) {
            Step "Claude Desktop clone '$n'"
            $c = New-DesktopClone $n $desktopBase $share $copy $links
            $clones = @($clones | Where-Object { -not ($_.name -eq $n -and $_.product -eq 'desktop') }) + $c
        }
        if ($doCode) {
            Step "Claude Code clone '$n'"
            $c = New-CodeClone $n $codeBase $copy $links
            $clones = @($clones | Where-Object { -not ($_.name -eq $n -and $_.product -eq 'code') }) + $c
        }
    }
    Save-Clones $clones

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
    if ($doDesktop) { Say '  Open a "Claude (<name>)" shortcut and sign in with that account. Your main app stays as it is.' }
    if ($doCode) { Say '  Run claude-<name> in a new terminal and type /login once.' }
}

function Select-Clone([string]$Title, $Clones) {
    $items = @($Clones | ForEach-Object { $app = 'Desktop'; if ($_.product -eq 'code') { $app = 'Code' }; '{0,-14} {1}' -f $_.name, $app }) + 'Back'
    $i = Select-Menu $Title $items 0
    if ($i -lt 0 -or $i -ge @($Clones).Count) { return $null }
    return @($Clones)[$i]
}

function Show-Dashboard {
    while ($true) {
        try { Clear-Host } catch { }
        Show-Header
        $desk = Resolve-ClaudeDesktop
        $code = Resolve-ClaudeCode
        Show-Installed $desk $code
        $clones = @(Get-AllClones)
        Show-CloneTable $clones

        $menu = @('Launch a clone', 'Create new clones', 'Remove a clone', 'Repair shortcuts', 'Open a profile folder', 'Quit')
        $default = 0
        if (-not $clones.Count) { $default = 1 }
        $choice = Select-Menu 'What would you like to do?' $menu $default
        switch ($choice) {
            0 {
                if (-not $clones.Count) { Warn 'No clones yet.'; Wait-Key; break }
                $c = Select-Clone 'Which clone?' $clones
                if ($c) { Invoke-Launch $c; Start-Sleep -Milliseconds 900 }
            }
            1 { Invoke-Create; Wait-Key }
            2 {
                if (-not $clones.Count) { Warn 'No clones yet.'; Wait-Key; break }
                $c = Select-Clone 'Remove which clone?' $clones
                if ($c) {
                    $how = Select-Menu "Remove '$($c.name)'" @('Remove shortcuts and launcher, keep the profile', 'Remove everything and delete the profile (signs it out)', 'Back') 0
                    if ($how -eq 0) { [void](Invoke-Remove $c.name $false $false); Wait-Key }
                    elseif ($how -eq 1) { [void](Invoke-Remove $c.name $true $false); Wait-Key }
                }
            }
            3 { Step 'Repairing shortcuts'; Invoke-Repair; Wait-Key }
            4 {
                if (-not $clones.Count) { Warn 'No clones yet.'; Wait-Key; break }
                $c = Select-Clone 'Open which profile folder?' $clones
                if ($c -and (Test-Path -LiteralPath $c.dir)) { Start-Process explorer.exe -ArgumentList "`"$($c.dir)`"" }
            }
            default { Write-Host ''; return }
        }
    }
}

# ---------------------------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------------------------
if ($List) {
    Show-Header
    Show-Installed (Resolve-ClaudeDesktop) (Resolve-ClaudeCode)
    Show-CloneTable @(Get-AllClones)
    Write-Host ''
    exit 0
}
if ($Remove) {
    if (Invoke-Remove $Remove ([bool]$Purge) $true) { exit 0 } else { exit 1 }
}
if ($Launch) {
    $c = @(Get-AllClones | Where-Object { $_.name -eq $Launch })
    if (-not $c.Count) { Say "No clone named '$Launch'." 'Yellow'; exit 1 }
    foreach ($x in $c) { Invoke-Launch $x }
    exit 0
}
if ($Repair) { Show-Header; Step 'Repairing shortcuts'; Invoke-Repair; exit 0 }

if ($Product -or $Names -or $Count -or $Path -or $Yes -or -not $CanReadKey) {
    Show-Header
    Invoke-Create
    Write-Host ''
    exit 0
}
Show-Dashboard
