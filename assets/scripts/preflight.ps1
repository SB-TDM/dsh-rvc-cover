#Requires -Version 7.0
<#
.SYNOPSIS
    Preflight for the cover pipeline: proves a local engine can run before any audio work starts.

.DESCRIPTION
    Prints one line per check as OK / WARN / FAIL and exits 1 when any FAIL exists, so a caller can gate on it.
    Read-only: inspects paths and versions, never installs, downloads, or writes.

    Two engine layouts are supported and auto-detected:
      applio  - Applio checkout: core.py at the root, env\Scripts\python.exe, models\*.pth
                Automated inference available (core.py infer).
      rvc     - RVC 2.3.260718: webui.py + configs\config.py + assets\{hubert_base,rmvpe,weights,indices}
                No CLI entry; conversion runs through the WebUI or an internal API call.

.PARAMETER Root
    Engine root directory. Defaults to $env:DSH_RVC_HOME. The name is kept for compatibility; it may point at
    either layout.

.PARAMETER Engine
    auto (default), applio, or rvc. auto detects from the files present in Root.

.PARAMETER ModelName
    Model stem. applio: models\<name>.pth. rvc: assets\weights\<name>.pth. Defaults to $env:DSH_RVC_MODEL.

.PARAMETER Python
    Explicit interpreter to probe. Defaults to the layout's own (applio: env\Scripts\python.exe).

.PARAMETER MinFreeGb
    Minimum free space on the engine volume, in GB. Default 25.

.EXAMPLE
    pwsh -File scripts/preflight.ps1 -Root D:\AI-Song\rvc -ModelName myvocal
#>
[CmdletBinding()]
param(
    [Alias('RvcHome')][string]$Root = $env:DSH_RVC_HOME,
    [ValidateSet('auto', 'applio', 'rvc')][string]$Engine = 'auto',
    [string]$ModelName = $env:DSH_RVC_MODEL,
    [string]$Python = '',
    [int]$MinFreeGb = 25
)

$ErrorActionPreference = 'Stop'
$script:failed = 0
$script:warned = 0

function Write-Check {
    param(
        [ValidateSet('OK', 'WARN', 'FAIL')][string]$State,
        [string]$Item,
        [string]$Detail
    )
    $color = switch ($State) { 'OK' { 'Green' } 'WARN' { 'Yellow' } default { 'Red' } }
    Write-Host ("{0,-5} {1,-18} {2}" -f $State, $Item, $Detail) -ForegroundColor $color
    if ($State -eq 'FAIL') { $script:failed++ }
    if ($State -eq 'WARN') { $script:warned++ }
}

function Get-ToolPath([string]$Exe, [string]$FallbackDir) {
    $cmd = Get-Command $Exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if ($FallbackDir) {
        foreach ($sub in '', 'bin') {
            $candidate = if ($sub) { Join-Path (Join-Path $FallbackDir $sub) ($Exe + '.exe') } else { Join-Path $FallbackDir ($Exe + '.exe') }
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }
    return $null
}

function Test-IsPyLauncher([string]$Interpreter) {
    $leaf = [System.IO.Path]::GetFileName($Interpreter)
    return $leaf -eq 'py' -or $leaf -eq 'py.exe'
}

function Test-Python {
    param(
        [string]$Interpreter,
        [string]$Label,
        [int]$MinMinor = 10,
        [int]$MaxMinor = 99
    )
    if ([string]::IsNullOrWhiteSpace($Interpreter)) {
        Write-Check FAIL $Label 'no interpreter configured and none found in the layout'
        return $null
    }
    $isLauncher = Test-IsPyLauncher $Interpreter
    try {
        $out = if ($isLauncher) { & $Interpreter -3.12 --version 2>&1 } else { & $Interpreter --version 2>&1 }
        $ver = ($out | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $ver -match 'Python 3\.(\d+)') {
            $minor = [int]$Matches[1]
            if ($minor -ge $MinMinor -and $minor -le $MaxMinor) { Write-Check OK $Label $ver }
            else { Write-Check FAIL $Label "$ver is outside 3.$MinMinor..3.$MaxMinor; Applio needs 3.10+, RVC 2.3 needs 3.12" }
            return $Interpreter
        }
        Write-Check FAIL $Label ($ver + ' (unusable)')
    } catch {
        Write-Check FAIL $Label ("cannot run: {0}" -f $_.Exception.Message)
    }
    return $null
}

Write-Host "cover preflight" -ForegroundColor Cyan
Write-Host ("=" * 68)

# --- root --------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Root)) {
    Write-Check FAIL 'engine root' 'DSH_RVC_HOME is empty; pass -Root or set the variable'
} elseif (-not (Test-Path -LiteralPath $Root)) {
    Write-Check FAIL 'engine root' "not found: $Root"
    $Root = $null
} else {
    $Root = (Resolve-Path -LiteralPath $Root).Path
    Write-Check OK 'engine root' $Root
}

# --- detect layout -----------------------------------------------------------
$layout = $null
if ($Root) {
    $hasApplio = Test-Path -LiteralPath (Join-Path $Root 'core.py')
    $hasRvc = Test-Path -LiteralPath (Join-Path $Root 'webui.py')
    if ($Engine -eq 'applio') { $layout = 'applio' }
    elseif ($Engine -eq 'rvc') { $layout = 'rvc' }
    elseif ($hasApplio) { $layout = 'applio' }
    elseif ($hasRvc) { $layout = 'rvc' }
    else { $layout = 'unknown' }

    if ($layout -eq 'unknown') {
        Write-Check FAIL 'layout' 'neither core.py (Applio) nor webui.py (RVC) found at the root'
    } elseif ($Engine -ne 'auto' -and -not (($layout -eq 'applio' -and $hasApplio) -or ($layout -eq 'rvc' -and $hasRvc))) {
        Write-Check FAIL 'layout' "-Engine $Engine requested but the matching entry file is missing"
        $layout = 'unknown'
    } else {
        Write-Check OK 'layout' $layout
    }
}

# --- per-layout structure ----------------------------------------------------
if ($layout -eq 'applio') {
    $py = if ($Python) { $Python } else { Join-Path $Root 'env/Scripts/python.exe' }
    if ($Python -or (Test-Path -LiteralPath $py)) { $script:interp = Test-Python $py 'python' 10 99 }
    else { Write-Check FAIL 'python' "missing $py; pass -Python or fix the env" }

    $sep = Join-Path $Root 'env/Scripts/audio-separator.exe'
    if (Test-Path -LiteralPath $sep) { Write-Check OK 'audio-separator' 'env/Scripts/audio-separator.exe' }
    else { Write-Check WARN 'audio-separator' 'absent; separation must run from another environment' }

    $models = Join-Path $Root 'models'
    if (Test-Path -LiteralPath $models) {
        $count = @(Get-ChildItem -LiteralPath $models -Filter '*.pth' -File -ErrorAction SilentlyContinue).Count
        if ($count -gt 0) { Write-Check OK 'models dir' "$count .pth in models\" }
        else { Write-Check FAIL 'models dir' 'no .pth in models\; nothing to convert with' }
    } else { Write-Check FAIL 'models dir' "missing $models" }

    $rmvpe = @(
        (Join-Path $Root 'rmvpe.pt'),
        (Join-Path $Root 'assets/rmvpe/rmvpe.pt'),
        (Join-Path $Root 'rvc/models/rmvpe.pt')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($rmvpe) { Write-Check OK 'rmvpe' $rmvpe } else { Write-Check WARN 'rmvpe' 'rmvpe.pt not found; core.py may download it on first run' }
}
elseif ($layout -eq 'rvc') {
    foreach ($required in 'configs/config.py') {
        $p = Join-Path $Root $required
        if (Test-Path -LiteralPath $p) { Write-Check OK 'engine file' $required }
        else { Write-Check FAIL 'engine file' "missing $required" }
    }
    foreach ($required in 'assets/hubert_base', 'assets/rmvpe/rmvpe.pt') {
        $p = Join-Path $Root $required
        if (Test-Path -LiteralPath $p) { Write-Check OK 'pretrained' $required }
        else { Write-Check FAIL 'pretrained' "missing $required" }
    }
    if (Test-Path -LiteralPath (Join-Path $Root 'assets/indices')) { Write-Check OK 'indices dir' 'assets/indices' }
    else { Write-Check WARN 'indices dir' 'absent; conversion still works, detail is lower' }

    $py = if ($Python) { $Python } else { '' }
    $script:interp = if ($py) { Test-Python $py 'python' 12 12 } else {
        $launcher = Get-Command 'py' -ErrorAction SilentlyContinue
        if ($launcher) { Test-Python 'py' 'python' 12 12 } else { Test-Python 'python' 'python' 12 12 }
    }
    Write-Check WARN 'inference' 'RVC 2.3 has no CLI entry; conversion needs the WebUI or the internal API'
}

# --- model -------------------------------------------------------------------
if ($layout -and $layout -ne 'unknown') {
    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        Write-Check WARN 'model' 'DSH_RVC_MODEL is empty; pass -ModelName once the .pth is chosen'
    } else {
        $pth = if ($layout -eq 'applio') { Join-Path $Root "models/$ModelName.pth" } else { Join-Path $Root "assets/weights/$ModelName.pth" }
        if (Test-Path -LiteralPath $pth) {
            $mb = [math]::Round((Get-Item -LiteralPath $pth).Length / 1MB, 1)
            Write-Check OK 'model' ("{0} ({1} MB)" -f $pth, $mb)
            if ($mb -lt 30) { Write-Check WARN 'model size' 'unusually small; verify the .pth is complete' }
            $idx = if ($layout -eq 'applio') { Join-Path $Root "models/$ModelName.index" } else { Join-Path $Root "assets/indices/$ModelName.index" }
            if (Test-Path -LiteralPath $idx) { Write-Check OK 'index' (Split-Path -Leaf $idx) }
            else { Write-Check WARN 'index' 'no matching .index; index-rate must be 0 and detail will be lower' }
        } else {
            Write-Check FAIL 'model' "missing $pth"
        }
    }
}

# --- ffmpeg ------------------------------------------------------------------
if ($Root) {
    $ff = Get-ToolPath 'ffmpeg' $Root
    if ($ff) { Write-Check OK 'ffmpeg' $ff } else { Write-Check FAIL 'ffmpeg' 'not on PATH and not in the engine root or its bin\' }
    $fp = Get-ToolPath 'ffprobe' $Root
    if ($fp) { Write-Check OK 'ffprobe' $fp } else { Write-Check FAIL 'ffprobe' 'not on PATH and not in the engine root or its bin\' }
} else {
    Write-Check WARN 'ffmpeg' 'skipped: engine root unknown'
}

# --- gpu ---------------------------------------------------------------------
$smi = Get-Command 'nvidia-smi' -ErrorAction SilentlyContinue
if (-not $smi) {
    Write-Check FAIL 'gpu' 'nvidia-smi not found; CUDA inference unavailable'
} else {
    $csv = & $smi.Source --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>&1
    if ($LASTEXITCODE -eq 0) {
        foreach ($line in ($csv -split "`n" | Where-Object { $_.Trim() })) {
            Write-Check OK 'gpu' $line.Trim()
            if ($line -match '(\d+)\s*MiB') {
                $mib = [int]$Matches[1]
                if ($mib -lt 3500) { Write-Check WARN 'gpu memory' "$mib MiB; conversion needs ~4 GB, separation more" }
            }
        }
    } else {
        Write-Check WARN 'gpu' 'nvidia-smi present but failed to report'
    }
}

# --- disk --------------------------------------------------------------------
if ($Root) {
    $drive = (Split-Path -Qualifier $Root).TrimEnd(':')
    $free = (Get-PSDrive -Name $drive -ErrorAction SilentlyContinue).Free
    if ($null -ne $free) {
        $gb = [math]::Round($free / 1GB, 1)
        if ($gb -ge $MinFreeGb) { Write-Check OK 'disk free' "$gb GB" }
        else { Write-Check WARN 'disk free' "$gb GB; want at least $MinFreeGb GB for weights and intermediates" }
    }
}

# --- summary -----------------------------------------------------------------
Write-Host ("=" * 68)
if ($script:failed -gt 0) {
    Write-Host ("BLOCKED: {0} failure(s), {1} warning(s). Fix failures before running audio steps." -f $script:failed, $script:warned) -ForegroundColor Red
    exit 1
}
Write-Host ("READY: 0 failures, {0} warning(s). Layout: {1}" -f $script:warned, $layout) -ForegroundColor Green
exit 0
