#!/usr/bin/env python
"""Measure the median f0 of two vocal takes and report the semitone shift.

Purpose: the pitch shift for a cover is a measurement, not a guess. Feed the
separated source vocal and a clean reference clip of the target timbre; take the
ratio of their median f0 and convert it to semitones.

Output is one JSON object on stdout so a caller can parse it without scraping
prose. Diagnostic hints go to stderr and into the `warnings` array.

Requires librosa (pyin) + soundfile. Install into the conversion environment:
    py -3.12 -m pip install librosa soundfile
"""

from __future__ import annotations

import argparse
import json
import math
import sys

# pyin is only meaningful inside a plausible singing range; wider bounds let
# octave errors through, narrower ones drop falsetto and low male notes.
DEFAULT_FMIN = 65.0
DEFAULT_FMAX = 1200.0

# Ratios this close to an octave multiple mean the tracker locked onto a
# harmonic instead of the fundamental.
OCTAVE_RATIOS = (0.5, 1.5, 2.0)
OCTAVE_TOLERANCE = 0.03


def fail(message: str, code: int = 2) -> None:
    """Report a blocking problem as JSON and exit non-zero."""
    json.dump({"ok": False, "error": message}, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    sys.exit(code)


def load_median_f0(path: str, fmin: float, fmax: float) -> dict:
    """Return median/voiced-frame stats for one file."""
    import librosa  # imported late so the error message stays actionable
    import numpy as np

    y, sr = librosa.load(path, sr=22050, mono=True)
    if y.size == 0:
        raise ValueError(f"{path}: decoded to zero samples")

    f0, voiced_flag, _voiced_prob = librosa.pyin(
        y,
        fmin=fmin,
        fmax=fmax,
        sr=sr,
        frame_length=2048,
    )
    voiced = f0[voiced_flag & np.isfinite(f0)]
    if voiced.size == 0:
        raise ValueError(f"{path}: no voiced frames detected in {fmin}-{fmax} Hz")

    return {
        "path": path,
        "median_hz": float(np.median(voiced)),
        "p10_hz": float(np.percentile(voiced, 10)),
        "p90_hz": float(np.percentile(voiced, 90)),
        "voiced_frames": int(voiced.size),
        "voiced_ratio": float(voiced.size / max(f0.size, 1)),
        "duration_s": float(librosa.get_duration(y=y, sr=sr)),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, help="separated vocal of the song being covered")
    parser.add_argument("--reference", required=True, help="clean clip of the target timbre (3-30 s)")
    parser.add_argument("--fmin", type=float, default=DEFAULT_FMIN)
    parser.add_argument("--fmax", type=float, default=DEFAULT_FMAX)
    parser.add_argument(
        "--max-semitones",
        type=float,
        default=12.0,
        help="refuse to report beyond this magnitude (default 12: one octave)",
    )
    args = parser.parse_args()

    try:
        src = load_median_f0(args.source, args.fmin, args.fmax)
        ref = load_median_f0(args.reference, args.fmin, args.fmax)
    except ImportError as exc:
        fail(f"missing dependency: {exc}. Run: py -3.12 -m pip install librosa soundfile")
    except Exception as exc:  # noqa: BLE001 - surfaced to the caller as JSON
        fail(str(exc))

    ratio = ref["median_hz"] / src["median_hz"]
    semitones = 12.0 * math.log2(ratio)
    rounded = int(round(semitones))
    warnings: list[str] = []

    if src["voiced_ratio"] < 0.2:
        warnings.append(
            "source vocal has few voiced frames; separation may be poor or the clip may be instrumental"
        )
    if ref["duration_s"] < 3.0:
        warnings.append("reference shorter than 3 s; median f0 is unstable")
    if ref["duration_s"] > 60.0:
        warnings.append("reference longer than 60 s; trim to the most representative phrase")

    for target in OCTAVE_RATIOS:
        if abs(ratio - target) <= OCTAVE_TOLERANCE:
            warnings.append(
                f"ratio {ratio:.3f} sits on a harmonic of {target}; verify by ear, the tracker may have locked onto an overtone"
            )
            break

    if abs(rounded) > args.max_semitones:
        warnings.append(
            f"shift {rounded:+d} semitones exceeds one octave; downward shifts build metallic artefacts, "
            "re-check the reference or pick a closer register"
        )
    if rounded < 0:
        warnings.append(
            "downward shift: every semitone down deepens the comb filter. Prefer shifting up when the register allows"
        )
    if rounded == 0:
        warnings.append("zero shift is a real result; still A/B a 10 s take, do not assume it is correct")

    result = {
        "ok": True,
        "source": src,
        "reference": ref,
        "ratio": round(ratio, 4),
        "semitones_exact": round(semitones, 3),
        "semitones": rounded,
        "warnings": warnings,
        "reminder": "the final judgement is whether it stays in tune with the accompaniment, not this number",
    }
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
