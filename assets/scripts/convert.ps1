#Requires -Version 7.0
<#
.SYNOPSIS
    Run one Applio voice conversion through its CLI, with guards and a product check.

.DESCRIPTION
    Wraps `python core.py infer`. Use this route when the engine is an Applio checkout: unlike RVC 2.3,
    Applio exposes a real CLI, so the conversion can run unattended.

    The standalone CLI requires --index-path. When no .index exists this script passes an empty string and
    forces --index-rate 0. The App adapter treats --index-path as optional; check infer --help on the installed revision.

.PARAMETER InputPath
    Vocal to convert (already separated).

.PARAMETER Out
    Output WAV path.

.PARAMETER Model
    Full path to the .pth model.

.PARAMETER Index
    Full path to a matching .index. Optional; index-rate drops to 0 without it.

.PARAMETER Pitch
    Semitone shift. Take it from pitch-match.py, do not guess.

.PARAMETER IndexRate
    Feature-retrieval share. 0.3-0.5 is the usable band for "real vs plastic".

.PARAMETER Protect
    Consonant protection. 0.33 default; raising it adds sibilance, lowering it smears lyrics.

.PARAMETER VolumeEnvelope
    Loudness blend. In current Applio, 0 stays closer to the original envelope and 1 keeps the converted envelope.
    Alias: -RmsMixRate.

.PARAMETER F0Method
    rmvpe (default), fcpe, crepe, harvest, pm. rmvpe first; switch to fcpe when rmvpe stair-steps.

.PARAMETER ApplioRoot
    Applio checkout. Defaults to $env:DSH_RVC_HOME.

.PARAMETER Python
    Interpreter. Defaults to <ApplioRoot>\env\Scripts\python.exe.

.PARAMETER DryRun
    Print the command instead of running it.

.EXAMPLE
    pwsh -File scripts/convert.ps1 -InputPath vocals.wav -Out vocals_conv.wav -Model models\me.pth -Pitch 3
#>
[CmdletBinding()]
param(
    # Not named -Input: $Input is a PowerShell automatic variable and would shadow the value.
    [Parameter(Mandatory)][Alias('Input')][string]$InputPath,
    [Parameter(Mandatory)][string]$Out,
    [Parameter(Mandatory)][string]$Model,
    [string]$Index = '',
    [int]$Pitch = 0,
    [double]$IndexRate = 0.5,
    [double]$Protect = 0.33,
    [Alias('RmsMixRate')][double]$VolumeEnvelope = 0.25,
    [ValidateSet('rmvpe', 'fcpe', 'crepe', 'harvest', 'pm')][string]$F0Method = 'rmvpe',
    [string]$ApplioRoot = $env:DSH_RVC_HOME,
    [string]$Python = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

function Resolve-FullPath([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "$Label not found: $Path" }
    return (Resolve-Path -LiteralPath $Path).Path
}

if ([string]::IsNullOrWhiteSpace($ApplioRoot)) { throw 'ApplioRoot is empty; pass -ApplioRoot or set DSH_RVC_HOME' }
$ApplioRoot = Resolve-FullPath $ApplioRoot 'Applio root'
$core = Join-Path $ApplioRoot 'core.py'
if (-not (Test-Path -LiteralPath $core)) {
    throw "core.py not found under $ApplioRoot. This route needs an Applio checkout; RVC 2.3 has no CLI entry, use its WebUI."
}

$script:inputFile = Resolve-FullPath $InputPath 'input audio'
$script:modelFile = Resolve-FullPath $Model 'model .pth'
if ($script:modelFile -notlike '*.pth') { throw "model must be a .pth: $script:modelFile" }

$indexFile = ''
if (-not [string]::IsNullOrWhiteSpace($Index)) {
    $indexFile = Resolve-FullPath $Index 'index file'
} else {
    $IndexRate = 0
    Write-Host 'no index given: index-rate forced to 0 (lower detail, no retrieval noise)' -ForegroundColor Yellow
}
if ($IndexRate -lt 0 -or $IndexRate -gt 1) { throw "IndexRate must be within 0..1, got $IndexRate" }
if ($VolumeEnvelope -lt 0 -or $VolumeEnvelope -gt 1) { throw "VolumeEnvelope must be within 0..1, got $VolumeEnvelope" }
if ($Pitch -lt -12 -or $Pitch -gt 12) { throw "Pitch $Pitch exceeds one octave; re-check the measurement first" }

$outFull = [System.IO.Path]::GetFullPath($Out)
$outDir = Split-Path -Parent $outFull
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
if (Test-Path -LiteralPath $outFull) { throw "output already exists, refusing to overwrite: $outFull" }

if ([string]::IsNullOrWhiteSpace($Python)) { $Python = Join-Path $ApplioRoot 'env/Scripts/python.exe' }
if (-not (Test-Path -LiteralPath $Python)) {
    throw "interpreter not found: $Python. Pass -Python with the Applio environment's python.exe."
}

function Format-Num([double]$Value) { return $Value.ToString('0.####', $inv) }

$applioArgs = @(
    'core.py', 'infer',
    '--input-path', $script:inputFile,
    '--output-path', $outFull,
    '--pth-path', $script:modelFile,
    '--pitch', [string]$Pitch,
    '--index-rate', (Format-Num $IndexRate),
    '--volume-envelope', (Format-Num $VolumeEnvelope),
    '--protect', (Format-Num $Protect),
    '--f0-method', $F0Method,
    '--export-format', 'WAV',
    '--index-path', $indexFile
)

Write-Host ("convert: {0}" -f $script:inputFile) -ForegroundColor Cyan
Write-Host ("  model  : {0}" -f $script:modelFile)
Write-Host ("  pitch  : {0:+0;-0;0} semitones, f0 {1}, index-rate {2}, volume-envelope {3}, protect {4}" -f $Pitch, $F0Method, (Format-Num $IndexRate), (Format-Num $VolumeEnvelope), (Format-Num $Protect))

if ($DryRun) {
    Write-Host ''
    Write-Host '[dry run] command:' -ForegroundColor Yellow
    Write-Host ('"{0}" {1}' -f $Python, ($applioArgs -join ' '))
    Write-Host ("cwd: {0}" -f $ApplioRoot)
    exit 0
}

Push-Location -LiteralPath $ApplioRoot
try {
    & $Python @applioArgs
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($code -ne 0) {
        throw ("Applio exited {0}. Run infer --help in this checkout and compare it with -DryRun; flags differ between standalone core.py and the App adapter." -f $code)
}
if (-not (Test-Path -LiteralPath $outFull)) { throw "Applio exited 0 but produced no file: $outFull" }

$size = [math]::Round((Get-Item -LiteralPath $outFull).Length / 1KB, 1)
Write-Host ("OK {0} ({1} KB)" -f $outFull, $size) -ForegroundColor Green
Write-Host 'measured, not judged: listen before claiming success.' -ForegroundColor Cyan
