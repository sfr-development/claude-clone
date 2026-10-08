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
    .\claude-clone.ps1 -Remove work
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
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$Version = '1.1.0'
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
    if ($pkg) { return @{ Exe = (Join-Path $pkg.InstallLocation 'app\Claude.exe'); Kind = 'msix'; Root = $pkg.InstallLocation; Pfn = $pkg.PackageFamilyName } }
    $squirrel = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
    if (Test-Path (Join-Path $squirrel 'claude.exe')) {
        $app = Get-ChildItem $squirrel -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
            Sort-Object { try { [version]($_.Name -replace '^app-', '') } catch { [version]'0.0' } } -Descending | Select-Object -First 1
        $exe = Join-Path $squirrel 'claude.exe'
        if ($app -and (Test-Path (Join-Path $app.FullName 'claude.exe'))) { $exe = Join-Path $app.FullName 'claude.exe' }
        return @{ Exe = $exe; Kind = 'squirrel'; Root = $squirrel }
    }
    foreach ($c in @((Join-Path $env:LOCALAPPDATA 'Programs\Claude\Claude.exe'), (Join-Path $env:ProgramFiles 'Claude\Claude.exe'))) {
        if (Test-Path $c) { return @{ Exe = $c; Kind = 'exe'; Root = (Split-Path $c) } }
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
# List / remove
# ---------------------------------------------------------------------------------------------
if ($List) {
    $clones = Get-Clones
    if (-not $clones.Count) { Say 'No clones yet.'; exit 0 }
    $clones | Select-Object name, product, dir | Format-Table -AutoSize
    exit 0
}

if ($Remove) {
    $clones = Get-Clones
    $hit = @($clones | Where-Object { $_.name -eq $Remove })
    if (-not $hit.Count) { Say "No clone named '$Remove'." 'Yellow'; exit 1 }
    foreach ($c in $hit) {
        Step "Removing $($c.product) clone '$($c.name)'"
        foreach ($l in @($c.shortcuts)) { if ($l -and (Test-Path $l)) { Remove-Item $l -Force; Ok "removed $l" } }
        if ($c.product -eq 'code' -and $c.launcher -and (Test-Path $c.launcher)) { Remove-Item $c.launcher -Force; Ok "removed $($c.launcher)" }
        if ($Purge -or (AskYesNo "Also delete the profile folder $($c.dir)? This signs the account out on this machine." $false)) {
            Remove-FolderSafely $c.dir
            Ok "deleted $($c.dir) (shared folders of the main profile are untouched)"
        } else {
            Say "    kept $($c.dir)"
        }
    }
    Save-Clones @($clones | Where-Object { $_.name -ne $Remove })
    exit 0
}

# ---------------------------------------------------------------------------------------------
# Interactive flow
# ---------------------------------------------------------------------------------------------
Write-Host ''
Write-Host '  claude-clone' -ForegroundColor White -NoNewline
Write-Host "  v$Version  -  several Claude accounts side by side" -ForegroundColor DarkGray
Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray

Step 'Looking for Claude on this machine'
$desk = Resolve-ClaudeDesktop
$code = Resolve-ClaudeCode
if ($desk) { Ok "Claude Desktop ($($desk.Kind)): $($desk.Exe)" } else { Warn 'Claude Desktop: not found' }
if ($code) { Ok "Claude Code: $code" } else { Warn 'Claude Code: not found' }
if (-not $desk -and -not $code) { Say "`n  Nothing to clone. Install Claude Desktop or Claude Code first." 'Yellow'; exit 1 }

if (-not $Product) {
    $opts = @()
    if ($desk) { $opts += 'desktop' }
    if ($code) { $opts += 'code' }
    if ($opts.Count -eq 2) { $opts += 'both' }
    if ($opts.Count -eq 1) { $Product = $opts[0] }
    else {
        Step 'What do you want to clone?'
        Say '    1) Claude Desktop      2) Claude Code (CLI)      3) both'
        $p = Ask 'Choose 1, 2 or 3' '1'
        switch ($p) { '2' { $Product = 'code' } '3' { $Product = 'both' } default { $Product = 'desktop' } }
    }
}
$doDesktop = ($Product -in @('desktop', 'both')) -and $desk
$doCode = ($Product -in @('code', 'both')) -and $code
if ($Product -in @('desktop', 'both') -and -not $desk) { Warn 'Claude Desktop is not installed - skipping it' }
if ($Product -in @('code', 'both') -and -not $code) { Warn 'Claude Code is not installed - skipping it' }
if (-not $doDesktop -and -not $doCode) { exit 1 }

if (-not $Names) {
    if (-not $Count) { try { $Count = [int](Ask 'How many clones?' '1') } catch { $Count = 1 } }
    if ($Count -lt 1) { $Count = 1 }
    $Names = @()
    for ($i = 1; $i -le $Count; $i++) {
        $Names += (Ask "Name for clone $i" ("account" + ($i + 1)))
    }
}
$Names = @($Names | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { Safe-Name $_ } | Select-Object -Unique)

$desktopBase = $Path
$codeBase = $Path
if (-not $Path) {
    if ($doDesktop) { $desktopBase = Ask 'Where to store Claude Desktop profiles?' $DefaultProfileBase }
    if ($doCode) { $codeBase = Ask 'Where to store Claude Code profiles?' $env:USERPROFILE }
}

foreach ($b in @($desktopBase, $codeBase)) {
    if ($b -and ($b -match '(?i)OneDrive|Dropbox|Google Drive|iCloud|Nextcloud')) {
        Warn "$b looks like a cloud-synced folder. Live app profiles there cause sync conflicts and slow Claude down."
        if (-not (AskYesNo 'Use it anyway?' $false)) { Say '  Cancelled. Run again and pick a local folder.'; exit 1 }
    }
}

$share = -not $NoShareSessions
$copy = -not $NoCopySettings
$links = -not $NoShortcuts
$mainLink = -not $NoMainShortcut
if (-not $Yes) {
    if ($doDesktop -and -not $NoShareSessions) { $share = AskYesNo 'Share the Desktop session list with the main profile (each account still sees only its own sessions)?' $true }
    if (-not $NoCopySettings) { $copy = AskYesNo 'Copy your settings (MCP servers, CLAUDE.md, skills; never login data)?' $true }
    if (-not $NoShortcuts) { $links = AskYesNo 'Create shortcuts with the Claude icon?' $true }
    if ($links -and -not $NoMainShortcut) { $mainLink = AskYesNo "Also create a 'main' shortcut for your current account?" $true }
}

Step 'Plan'
foreach ($n in $Names) {
    if ($doDesktop) { Say "    Claude Desktop  '$n'  ->  $(Join-Path $desktopBase "Claude-$n")" }
    if ($doCode) { Say "    Claude Code     '$n'  ->  $(Join-Path $codeBase ".claude-$n")" }
}
if (-not (AskYesNo 'Go ahead?' $true)) { Say '  Cancelled.'; exit 0 }

$clones = @(Get-Clones)
foreach ($n in $Names) {
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
Say '  List clones:   claude-clone.ps1 -List'
Say '  Remove one:    claude-clone.ps1 -Remove <name>'
Write-Host ''
