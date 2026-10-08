# Generates docs/demo.svg: an animated terminal recording of the claude-clone dashboard (pure SVG + CSS).
$out = Join-Path $PSScriptRoot 'demo.svg'
$cycle = 14.0
$lh = 21; $x0 = 26; $y0 = 70; $cw = 8.4
$C = @{ w = '#faf9f5'; g = '#c2c0b6'; d = '#77756e'; cy = '#5fb3c9'; gr = '#4ec27a'; or = '#d97757' }
$H = [char]0x2500; $V = [char]0x2502
$dot = [char]0x25CF; $ring = [char]0x25CB
$inner = 70
$lines = @(
    @{ t = 0;   s = @(@('PS C:\&gt; ', 'd'), @('.\claude-clone.ps1', 'w')); typing = $true },
    @{ t = 2.0; s = @(@(('  ' + [char]0x256D + ([string]$H * $inner) + [char]0x256E), 'd')) },
    @{ t = 2.0; s = @(@("  $V ", 'd'), @('claude-clone', 'w'), @(' v1.2.0', 'd'), @(((' ' * 13) + "several Claude accounts side by side $V"), 'd')) },
    @{ t = 2.0; s = @(@(('  ' + [char]0x2570 + ([string]$H * $inner) + [char]0x256F), 'd')) },
    @{ t = 2.5; s = @(@('  INSTALLED', 'cy')) },
    @{ t = 2.5; s = @(@("    $dot ", 'gr'), @('Claude Desktop  Microsoft Store   2.26454.2.0', 'g')) },
    @{ t = 2.5; s = @(@("    $dot ", 'gr'), @('Claude Code     2.1.293  (bundled with Claude Desktop)', 'g')) },
    @{ t = 3.1; s = @(@('  YOUR CLONES (3)', 'cy')) },
    @{ t = 3.1; s = @(@('      NAME          APP      STATUS         LAST USED', 'd')) },
    @{ t = 3.4; s = @(@("    $dot ", 'gr'), @('work          ', 'w'), @('Desktop  ', 'g'), @('running        ', 'gr'), @('just now', 'd')) },
    @{ t = 3.7; s = @(@("    $dot ", 'cy'), @('client-a      ', 'w'), @('Desktop  ', 'g'), @('signed in      ', 'cy'), @('2 h ago', 'd')) },
    @{ t = 4.0; s = @(@("    $ring ", 'd'), @('personal      ', 'w'), @('Code     ', 'g'), @('not signed in  ', 'd'), @('-', 'd')) },
    @{ t = 4.5; s = @(@('  What would you like to do?', 'cy')) }
)
$menu = @('Launch a clone', 'Create new clones', 'Remove a clone', 'Repair shortcuts', 'Open a profile folder', 'Quit')
$tMenu = 4.5
# rows: lines get a blank row before INSTALLED, YOUR CLONES and the menu title
$rowOf = @{}
$row = 0
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($i -in @(1, 4, 7, 12)) { $row++ }
    $rowOf[$i] = $row
    $row++
}
$menuRow0 = $row
$height = $y0 + ($menuRow0 + $menu.Count) * $lh + 34

function Pct([double]$s) { return [Math]::Round($s / $cycle * 100, 2) }
$css = New-Object Text.StringBuilder
$body = New-Object Text.StringBuilder
$k = 0
function Add-Appear([double]$At) {
    $script:k++
    $a = Pct $At; $b = Pct ($At + 0.25)
    [void]$css.AppendLine(".a$($script:k){animation:k$($script:k) ${cycle}s linear infinite}@keyframes k$($script:k){0%,$a%{opacity:0}$b%,92%{opacity:1}97%,100%{opacity:0}}")
    return "a$($script:k)"
}

for ($i = 0; $i -lt $lines.Count; $i++) {
    $L = $lines[$i]
    $y = $y0 + $rowOf[$i] * $lh
    if ($L.typing) { $cls = Add-Appear 0.05 } else { $cls = Add-Appear $L.t }
    [void]$body.Append("<text class=""$cls"" x=""$x0"" y=""$y"" xml:space=""preserve"">")
    $segs = $L.s
    if ($segs[0] -is [string]) { $segs = ,$segs }
    foreach ($seg in $segs) { [void]$body.Append("<tspan fill=""$($C[$seg[1]])"">$($seg[0])</tspan>") }
    [void]$body.AppendLine('</text>')
    if ($L.typing) {
        # cover that slides away char by char = typing effect
        $startX = $x0 + 8 * $cw
        $w = 18 * $cw + 4
        [void]$css.AppendLine(".type{animation:type ${cycle}s steps(18,end) infinite}@keyframes type{0%,$(Pct 0.3)%{transform:translateX(0)}$(Pct 1.6)%,96%{transform:translateX(${w}px)}96.01%,100%{transform:translateX(0)}}")
        [void]$body.AppendLine("<g class=""type""><rect x=""$startX"" y=""$($y - 15)"" width=""$w"" height=""20"" fill=""#0f0f0e""/><rect class=""caret"" x=""$startX"" y=""$($y - 14)"" width=""8"" height=""17"" fill=""$($C.or)""/></g>")
        [void]$css.AppendLine(".caret{animation:caret ${cycle}s steps(1,end) infinite}@keyframes caret{0%{opacity:1}$(Pct 1.8)%,100%{opacity:0}}")

    }
}

# menu with a moving highlight bar
$barCls = Add-Appear $tMenu
$moves = @(@(4.5, 0), @(6.2, 1), @(7.2, 2), @(8.2, 1), @(9.2, 0))
$kf = New-Object Text.StringBuilder
[void]$kf.Append('@keyframes bar{')
$prevT = 0; $prevIdx = 0
foreach ($m in $moves) {
    [void]$kf.Append("$(Pct $m[0])%{transform:translateY($($m[1] * $lh)px)}")
}
[void]$kf.Append('100%{transform:translateY(0px)}}')
[void]$css.AppendLine(".bar{animation:bar ${cycle}s steps(1,end) infinite}$kf")
[void]$css.AppendLine(".press{animation:press ${cycle}s linear infinite}@keyframes press{0%,$(Pct 10.2)%{fill:#2b6d7e}$(Pct 10.35)%{fill:#4aa3bb}$(Pct 10.6)%,100%{fill:#2b6d7e}}")
$yBar = $y0 + $menuRow0 * $lh - 15
[void]$body.AppendLine("<g class=""$barCls""><g class=""bar""><rect class=""press"" x=""$($x0 + 8)"" y=""$yBar"" width=""300"" height=""$($lh - 1)"" rx=""4"" fill=""#2b6d7e""/></g></g>")
for ($j = 0; $j -lt $menu.Count; $j++) {
    $y = $y0 + ($menuRow0 + $j) * $lh
    $cls = Add-Appear ($tMenu + 0.05 * $j)
    [void]$body.AppendLine("<text class=""$cls"" x=""$($x0 + 18)"" y=""$y"" fill=""$($C.w)"" xml:space=""preserve"">$($menu[$j])</text>")
}

$svg = @"
<svg xmlns="http://www.w3.org/2000/svg" width="860" height="$height" viewBox="0 0 860 $height" role="img" aria-label="Animated terminal: the claude-clone dashboard">
<style>
text{font-family:'Cascadia Code','JetBrains Mono',Consolas,'DejaVu Sans Mono','Courier New',monospace;font-size:14px}
$($css.ToString())</style>
<rect width="860" height="$height" rx="14" fill="#0f0f0e" stroke="#2c2b28"/>
<rect width="860" height="38" rx="14" fill="#1c1b19"/>
<rect y="24" width="860" height="14" fill="#1c1b19"/>
<circle cx="24" cy="19" r="6" fill="#d97757"/><circle cx="44" cy="19" r="6" fill="#c2a14b"/><circle cx="64" cy="19" r="6" fill="#788c5d"/>
<text x="430" y="24" fill="#77756e" text-anchor="middle" style="font-size:13px">Windows PowerShell</text>
$($body.ToString())</svg>
"@
[IO.File]::WriteAllText($out, $svg, (New-Object Text.UTF8Encoding $false))
"written: $out ($((Get-Item $out).Length) bytes, height $height)"
