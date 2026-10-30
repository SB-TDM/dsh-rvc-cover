#Requires -Version 7.0
<#
.SYNOPSIS
    Mix a converted vocal against an instrumental, pitch-shifting the instrumental to match.

.DESCRIPTION
    A cover fails most often here: the vocal is shifted but the accompaniment is not, so the
    whole track drifts out of key. This script shifts the instrumental by the same semitone
    count, sets the vocal ~2 dB above it, normalises loudness, and reports the duration delta.

    Prefers rubberband (clean, tempo-preserving). Falls back to asetrate + atempo, which is
    correct in pitch but slightly lossier.

.PARAMETER Vocal
    Converted vocal (vocals_conv.wav).

.PARAMETER Instrumental
    Separated instrumental at the ORIGINAL key.

.PARAMETER Out
    Output path. .mp3 encodes 320 kbps; anything else is written as PCM.

.PARAMETER Source
    Original song. When set, the duration check uses this file. Otherwise it uses the instrumental and says so.

.PARAMETER ShiftSemitones
    Semitone shift applied to the vocal. The instrumental gets the same shift.

.PARAMETER VocalDb
    Vocal gain above unity, in dB. 1..3 is the usable band; default 2.

.PARAMETER Lufs
    Integrated loudness target. Default -14.

.PARAMETER Tp
    True-peak ceiling in dBTP. Default -1.

.PARAMETER KeepTemp
    Keep intermediate WAVs next to the output for inspection.

.EXAMPLE
    pwsh -File scripts/mix.ps1 -Vocal v.wav -Instrumental i.wav -ShiftSemitones 3 -Out cover.mp3
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Vocal,
    [Parameter(Mandatory)][string]$Instrumental,
    [Parameter(Mandatory)][string]$Out,
    [string]$Source = '',
    [double]$ShiftSemitones = 0,
    [double]$VocalDb = 2,
    [double]$Lufs = -14,
    [double]$Tp = -1,
    [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

function Get-Tool([string]$Exe) {
    $cmd = Get-Command $Exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $local = Join-Path (Get-Location).Path ($Exe + '.exe')
    if (Test-Path -LiteralPath $local) { return $local }
    throw "$Exe not found. Put ffmpeg.exe/ffprobe.exe on PATH or in the RVC root, then retry."
}

function Format-Num([double]$Value, [string]$Pattern = '0.######') {
    return $Value.ToString($Pattern, $inv)
}

$ffmpeg = Get-Tool 'ffmpeg'
$ffprobe = Get-Tool 'ffprobe'

$inputs = [System.Collections.Generic.List[string]]::new()
$inputs.Add($Vocal)
$inputs.Add($Instrumental)
if (-not [string]::IsNullOrWhiteSpace($Source)) { $inputs.Add($Source) }
foreach ($path in $inputs) {
    if (-not (Test-Path -LiteralPath $path)) { throw "input not found: $path" }
}

if ([math]::Abs($ShiftSemitones) -gt 12) {
    throw ("shift {0} semitones exceeds one octave; re-check the measurement before mixing" -f $ShiftSemitones)
}

$outDir = Split-Path -Parent $Out
if ([string]::IsNullOrWhiteSpace($outDir)) { $outDir = (Get-Location).Path }
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("rvc-mix-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

function Get-Duration([string]$Path) {
    $raw = & $ffprobe -v error -show_entries format=duration -of "default=nw=1:nk=1" $Path 2>$null
    $value = 0.0
    if ([double]::TryParse(($raw | Out-String).Trim(), [System.Globalization.NumberStyles]::Float, $inv, [ref]$value)) {
        return $value
    }
    return 0.0
}

function Get-SampleRate([string]$Path) {
    $raw = & $ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of "default=nw=1:nk=1" $Path 2>$null
    $value = 0
    if ([int]::TryParse(($raw | Out-String).Trim(), [ref]$value)) { return $value }
    return 44100
}

try {
    $drumDur = Get-Duration $Instrumental
    $voxDur = Get-Duration $Vocal
    Write-Host ("inputs: vocal {0:N1}s, instrumental {1:N1}s, shift {2:+0.##;-0.##;0} semitones" -f $voxDur, $drumDur, $ShiftSemitones) -ForegroundColor Cyan

    # --- 1. pitch-shift the instrumental to follow the vocal ------------------
    $instrumentalForMix = $Instrumental
    if ([math]::Abs($ShiftSemitones) -ge 0.01) {
        $ratio = [math]::Pow(2.0, $ShiftSemitones / 12.0)
        $ratioStr = Format-Num $ratio '0.0000000'
        $shifted = Join-Path $workDir 'instrumental_shifted.wav'

        $filters = & $ffmpeg -hide_banner -filters 2>$null | Out-String
        if ($filters -match '\brubberband\b') {
            Write-Host "pitch: rubberband (tempo preserved)" -ForegroundColor Green
            & $ffmpeg -y -v error -i $Instrumental -af ("rubberband=pitch=" + $ratioStr) -ar 48000 $shifted
        } else {
            $sr = Get-SampleRate $Instrumental
            $newRate = [math]::Round($sr * $ratio, 2)
            $tempo = 1.0 / $ratio
            Write-Host "pitch: asetrate + atempo fallback (rubberband filter absent)" -ForegroundColor Yellow
            & $ffmpeg -y -v error -i $Instrumental `
                -af ("asetrate=" + (Format-Num $newRate '0.##') + ",aresample=48000,atempo=" + (Format-Num $tempo '0.0000000')) `
                $shifted
        }
        if ($LASTEXITCODE -ne 0) { throw "instrumental pitch shift failed (ffmpeg exit $LASTEXITCODE)" }
        $instrumentalForMix = $shifted
    }

    # --- 2. mix vocal over instrumental --------------------------------------
    $mixed = Join-Path $workDir 'mix.wav'
    $voiceGain = (Format-Num $VocalDb '0.##') + 'dB'
    & $ffmpeg -y -v error -i $Vocal -i $instrumentalForMix `
        -filter_complex ("[0:a]volume=" + $voiceGain + "[v];[v][1:a]amix=inputs=2:duration=longest:normalize=0") `
        -ar 48000 $mixed
    if ($LASTEXITCODE -ne 0) { throw "mixing failed (ffmpeg exit $LASTEXITCODE)" }

    # --- 3. loudness normalise and encode ------------------------------------
    $loud = "loudnorm=I=" + (Format-Num $Lufs '0.##') + ":TP=" + (Format-Num $Tp '0.##') + ":LRA=11"
    $isMp3 = $Out.ToLowerInvariant().EndsWith('.mp3')
    if ($isMp3) {
        & $ffmpeg -y -v error -i $mixed -af $loud -c:a libmp3lame -b:a 320k $Out
    } else {
        & $ffmpeg -y -v error -i $mixed -af $loud -c:a pcm_s24le $Out
    }
    if ($LASTEXITCODE -ne 0) { throw "final encode failed (ffmpeg exit $LASTEXITCODE)" }

    # --- 4. verify -----------------------------------------------------------
    $outDur = Get-Duration $Out
    Write-Host ("output: {0} ({1:N1}s)" -f $Out, $outDur) -ForegroundColor Green
    Write-Host ("level: +{0} dB was applied to the vocal track itself; it is not a measured vocal-minus-instrumental delta" -f (Format-Num $VocalDb '0.##'))
    $checks = @(
        @{ Name = 'instrumental'; Duration = $drumDur }
    )
    if (-not [string]::IsNullOrWhiteSpace($Source)) {
        $checks += @{ Name = 'source'; Duration = (Get-Duration $Source) }
    } else {
        Write-Host 'WARN duration is compared with the instrumental only; pass -Source to compare with the original song' -ForegroundColor Yellow
    }
    foreach ($check in $checks) {
        $delta = [math]::Abs($outDur - $check.Duration)
        if ($delta -gt 1.0) {
            Write-Host ("WARN duration differs from the {0} by {1:N2}s" -f $check.Name, $delta) -ForegroundColor Yellow
        } else {
            Write-Host ("OK   duration delta vs {0}: {1:N2}s" -f $check.Name, $delta) -ForegroundColor Green
        }
    }
    $loudLog = & $ffmpeg -hide_banner -nostats -i $Out -af ("loudnorm=I=" + (Format-Num $Lufs '0.##') + ":TP=" + (Format-Num $Tp '0.##') + ":LRA=11:print_format=json") -f null - 2>&1 | Out-String
    $start = $loudLog.LastIndexOf('{')
    $end = $loudLog.LastIndexOf('}')
    if ($start -ge 0 -and $end -gt $start) {
        $measured = $loudLog.Substring($start, $end - $start + 1) | ConvertFrom-Json
        $measuredI = 0.0
        $measuredTp = 0.0
        $hasI = [double]::TryParse([string]$measured.input_i, [System.Globalization.NumberStyles]::Float, $inv, [ref]$measuredI)
        $hasTp = [double]::TryParse([string]$measured.input_tp, [System.Globalization.NumberStyles]::Float, $inv, [ref]$measuredTp)
        if ($hasI) {
            Write-Host ("measured loudness: {0:N1} LUFS (target {1})" -f $measuredI, $Lufs)
            if ([math]::Abs($measuredI - $Lufs) -gt 1.5) {
                Write-Host ("WARN loudness is {0:N1} LU away from the target" -f ($measuredI - $Lufs)) -ForegroundColor Yellow
            }
        } else { Write-Host 'WARN loudness: integrated value was not numeric' -ForegroundColor Yellow }
        if ($hasTp) {
            Write-Host ("measured true peak: {0:N1} dBTP (ceiling {1})" -f $measuredTp, $Tp)
            if ($measuredTp -gt $Tp) { Write-Host 'WARN true peak exceeds the ceiling' -ForegroundColor Yellow }
        } else { Write-Host 'WARN loudness: true peak was not numeric' -ForegroundColor Yellow }
    } else {
        Write-Host 'WARN loudness: ffmpeg did not return loudnorm JSON' -ForegroundColor Yellow
    }
    Write-Host 'measured values are not a listening judgement.' -ForegroundColor Cyan
}
finally {
    if ($KeepTemp) {
        $kept = Join-Path $outDir 'mix-temp'
        if (-not (Test-Path -LiteralPath $kept)) { New-Item -ItemType Directory -Path $kept -Force | Out-Null }
        Get-ChildItem -LiteralPath $workDir -File -ErrorAction SilentlyContinue | Copy-Item -Destination $kept -Force
        Write-Host "kept intermediates in $kept" -ForegroundColor Cyan
    }
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}
