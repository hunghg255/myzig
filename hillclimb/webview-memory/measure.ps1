# The memory of a hidden window on about:blank in myzig, mygo and Electron,
# Windows only. See README.md for building the three apps first.
#
#   powershell -File hillclimb\webview-memory\measure.ps1 [-Runs 3] [-Settle 6]
#
# Each run starts an app, waits -Settle seconds, then sums the private bytes
# of its process tree (the app and every WebView2/Chromium child; console
# hosts excluded). Apps take turns, so drift spreads over all of them; each
# cell of the table is the median over the runs.
param(
    [int]$Runs = 3,
    [int]$Settle = 6,
    [string]$Myzig = "$PSScriptRoot\..\..\zig-out\bin\hello.exe",
    [string]$Mygo = "$PSScriptRoot\mygo-blank\mygo-blank.exe",
    [string]$Electron = "$PSScriptRoot\electron-blank"
)
$ErrorActionPreference = 'Stop'

$electronExe = "$Electron\node_modules\electron\dist\electron.exe"
$apps = @(
    @{ Name = 'myzig'; Exe = $Myzig; ArgList = @('--myzig-eval=setTimeout(()=>myzig.window.close(),9000)'); Env = @{ MYZIG_DEV_URL = 'about:blank' } },
    @{ Name = 'mygo'; Exe = $Mygo; ArgList = @(); Env = @{} },
    @{ Name = 'electron'; Exe = $electronExe; ArgList = @("`"$((Resolve-Path $Electron).Path)`""); Env = @{} }
)
foreach ($a in $apps) {
    if (-not (Test-Path $a.Exe)) { throw "$($a.Name): $($a.Exe) is missing; build it first (README.md)" }
}

function Tree($root) {
    $all = Get-CimInstance Win32_Process
    $ids = @($root); $more = $true
    while ($more) {
        $more = $false
        foreach ($x in $all) {
            if ($ids -contains $x.ParentProcessId -and -not ($ids -contains $x.ProcessId)) { $ids += $x.ProcessId; $more = $true }
        }
    }
    $all | Where-Object { $ids -contains $_.ProcessId -and $_.Name -ne 'conhost.exe' }
}

function Role($p, $root) {
    if ($p.ProcessId -eq $root) { return 'app' }
    if ($p.CommandLine -notmatch '--type=([\w-]+)') { return 'browser' }
    $t = $matches[1]
    if ($t -ne 'utility') { return $t }
    if ($p.CommandLine -match 'NetworkService') { return 'network' }
    if ($p.CommandLine -match 'StorageService') { return 'storage' }
    return 'utility'
}

function Sample($app) {
    foreach ($k in $app.Env.Keys) { Set-Item "Env:$k" $app.Env[$k] }
    try {
        $p = if ($app.ArgList.Count) { Start-Process -FilePath $app.Exe -ArgumentList $app.ArgList -PassThru } else { Start-Process -FilePath $app.Exe -PassThru }
    } finally {
        foreach ($k in $app.Env.Keys) { Remove-Item "Env:$k" }
    }
    Start-Sleep -Seconds $Settle
    $row = @{ count = 0 }
    $tree = @(Tree $p.Id)
    foreach ($x in $tree) {
        $mb = (Get-Process -Id $x.ProcessId -ErrorAction SilentlyContinue).PrivateMemorySize64 / 1MB
        $r = Role $x $p.Id
        $row[$r] = [double]$row[$r] + $mb
        $row.count++
    }
    $row.total = ($row.GetEnumerator() | Where-Object { $_.Key -ne 'count' } | Measure-Object Value -Sum).Sum
    # The apps quit on their own; nothing must stay behind if one does not.
    if (-not $p.WaitForExit(20000)) {
        Write-Warning "$($app.Name) did not quit; stopping it"
        $tree | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Seconds 2
    $row
}

$samples = @{}
foreach ($a in $apps) { $samples[$a.Name] = @() }
for ($r = 1; $r -le $Runs; $r++) {
    foreach ($a in $apps) {
        Write-Host "run $r/$Runs`: $($a.Name)"
        $samples[$a.Name] += , (Sample $a)
    }
}

function Median($xs) {
    $s = @($xs | Sort-Object)
    if ($s.Count % 2) { $s[[int](($s.Count - 1) / 2)] } else { ($s[$s.Count / 2 - 1] + $s[$s.Count / 2]) / 2 }
}

$roles = @('app', 'browser', 'gpu-process', 'renderer', 'network', 'storage', 'utility', 'crashpad-handler', 'total', 'count')
$names = $apps | ForEach-Object { $_.Name }
"| process (MiB, median of $Runs) | $($names -join ' | ') |"
"|---|$(($names | ForEach-Object { '---:' }) -join '|')|"
foreach ($role in $roles) {
    $cells = foreach ($n in $names) {
        $v = Median ($samples[$n] | ForEach-Object { [double]$_[$role] })
        if ($role -eq 'count') { '{0:N0}' -f $v } elseif ($v -eq 0) { '-' } else { '{0:N1}' -f $v }
    }
    if (($cells | Where-Object { $_ -ne '-' }).Count -gt 0) { "| $role | $($cells -join ' | ') |" }
}
