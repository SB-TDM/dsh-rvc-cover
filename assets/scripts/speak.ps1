#Requires -Version 7.0
<#
.SYNOPSIS
    Synthesize speech with Applio TTS, then convert it with the same RVC model used for singing.

.DESCRIPTION
    This is the first check for "same person": one inference model converts both a sung vocal and this
    spoken clip. Edge TTS needs internet and sends the text to that service. It does not prove the result
    sounds like one person; listen before saying it does.

.PARAMETER Text
    The line to speak.

.PARAMETER Out
    Converted speech WAV. The intermediate TTS WAV is written beside it as <name>.tts.wav.

.PARAMETER Model
    Inference .pth. Do not pass a training checkpoint.

.PARAMETER Index
    Matching .index. Passed as an empty --index-path when absent, and index-rate is forced to 0.

.PARAMETER Voice
    Edge TTS voice id. Default zh-CN-XiaoxiaoNeural. This is only the source performance, not the target timbre.

.PARAMETER ApplioRoot
    Applio checkout. Defaults to $env:DSH_RVC_HOME.

.PARAMETER Python
    Interpreter. Defaults to <ApplioRoot>\env\Scripts\python.exe.

.PARAMETER Pitch
    Semitone shift. Default 0. Do not copy a singing shift onto speech without listening.

.PARAMETER DryRun
    Print the command instead of running it.

.EXAMPLE
    pwsh -File scripts/speak.ps1 -Text "今天晚上见。" -Out speech.wav -Model models\target.pth
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Text,
    [Parameter(Mandatory)][string]$Out,
    [Parameter(Mandatory)][string]$Model,
    [string]$Index = '',
    [string]$Voice = 'zh-CN-XiaoxiaoNeural',
    [string]$ApplioRoot = $env:DSH_RVC_HOME,
    [string]$Python = '',
    [int]$Pitch = 0,
    [double]$IndexRate = 0.4,
    [ValidateRange(0, 1)][double]$VolumeEnvelope = 0.25,
    [double]$Protect = 0.33,
    [ValidateSet('rmvpe', 'fcpe', 'crepe', 'harvest', 'pm')][string]$F0Method = 'rmvpe',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

function Resolve-FullPath([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "$Label not found: $Path" }
    return (Resolve-Path -LiteralPath $Path).Path
}

if ([string]::IsNullOrWhiteSpace($Text)) { throw 'Text is empty' }
if ([string]::IsNullOrWhiteSpace($ApplioRoot)) { throw 'ApplioRoot is empty; pass -ApplioRoot or set DSH_RVC_HOME' }
$ApplioRoot = Resolve-FullPath $ApplioRoot 'Applio root'
$core = Join-Path $ApplioRoot 'core.py'
if (-not (Test-Path -LiteralPath $core)) { throw "core.py not found under $ApplioRoot. speak.ps1 needs Applio." }

$modelFile = Resolve-FullPath $Model 'model .pth'
if ($modelFile -notlike '*.pth') { throw "model must be a .pth: $modelFile" }
$indexFile = ''
if (-not [string]::IsNullOrWhiteSpace($Index)) { $indexFile = Resolve-FullPath $Index 'index file' }
else { $IndexRate = 0 }
if ($IndexRate -lt 0 -or $IndexRate -gt 1) { throw "IndexRate must be within 0..1, got $IndexRate" }
if ($Pitch -lt -12 -or $Pitch -gt 12) { throw "Pitch $Pitch exceeds one octave" }

$outFull = [System.IO.Path]::GetFullPath($Out)
$outDir = Split-Path -Parent $outFull
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
if (Test-Path -LiteralPath $outFull) { throw "output already exists, refusing to overwrite: $outFull" }
$ttsFull = [System.IO.Path]::Combine($outDir, ([System.IO.Path]::GetFileNameWithoutExtension($outFull) + '.tts.wav'))
if (Test-Path -LiteralPath $ttsFull) { throw "intermediate already exists, refusing to overwrite: $ttsFull" }

if ([string]::IsNullOrWhiteSpace($Python)) { $Python = Join-Path $ApplioRoot 'env/Scripts/python.exe' }
if (-not (Test-Path -LiteralPath $Python)) { throw "interpreter not found: $Python" }

function Format-Num([double]$Value) { return $Value.ToString('0.####', $inv) }

$applioArgs = @(
    'core.py', 'tts',
    '--tts-file', '',
    '--tts-text', $Text,
    '--tts-voice', $Voice,
    '--output-tts-path', $ttsFull,
    '--output-rvc-path', $outFull,
    '--pth-path', $modelFile,
    '--index-path', $indexFile,
    '--pitch', [string]$Pitch,
    '--index-rate', (Format-Num $IndexRate),
    '--volume-envelope', (Format-Num $VolumeEnvelope),
    '--protect', (Format-Num $Protect),
    '--f0-method', $F0Method
)

Write-Host 'speak: Edge TTS, then the same RVC model. Network required. Listening still required.' -ForegroundColor Cyan
Write-Host ("  voice  : {0}" -f $Voice)
Write-Host ("  model  : {0}" -f $modelFile)

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
if ($code -ne 0) { throw "Applio exited $code. Compare with tts --help; this command follows the current standalone CLI." }
if (-not (Test-Path -LiteralPath $outFull)) { throw "Applio exited 0 but produced no converted file: $outFull" }
Write-Host ("OK {0}" -f $outFull) -ForegroundColor Green
Write-Host 'same model is not proof of the same person. Compare this clip with a sung clip before claiming that.' -ForegroundColor Cyan
