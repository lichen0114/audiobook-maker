#!/usr/bin/env python3
"""Patch mlx-audio's Kokoro istftnet vocoder for a length-drift crash.

`SineGen._f02sine` upsamples the F0 with a down/up `interpolate` round-trip
whose rounding drifts a few samples from the input length for certain frame
counts. The drifted sine tensor then broadcast-mismatches `uv`/`noise` in
`SineGen.__call__`, crashing conversion with:

    [broadcast_shapes] Shapes (1,609600,1) and (1,609900,9) cannot be broadcast.

This forces `_f02sine`'s output back to the input F0 length (crop or pad),
which is what every downstream op expects. Idempotent — safe to re-run.

Usage: python patch_mlx.py /path/to/site-packages   (or a python that can
       import mlx_audio, passed as the interpreter running this script).
"""
import sys
from pathlib import Path

MARKER = "# ABM-LENFIX"

ANCHOR = "            sines = mx.cos(i_phase * 2 * mx.pi)\n        return sines\n"
REPLACEMENT = (
    "            sines = mx.cos(i_phase * 2 * mx.pi)\n"
    "        " + MARKER + ": the down/up interpolate round-trip can drift a few\n"
    "        # samples; force the sine length back to the input f0 length so the\n"
    "        # elementwise ops in __call__ never broadcast-mismatch.\n"
    "        _abm_T = f0_values.shape[1]\n"
    "        if sines.shape[1] != _abm_T:\n"
    "            if sines.shape[1] > _abm_T:\n"
    "                sines = sines[:, :_abm_T, :]\n"
    "            else:\n"
    "                sines = mx.pad(sines, ((0, 0), (0, _abm_T - sines.shape[1]), (0, 0)))\n"
    "        return sines\n"
)


def find_istftnet(site_packages: Path) -> Path:
    p = site_packages / "mlx_audio" / "tts" / "models" / "kokoro" / "istftnet.py"
    if not p.exists():
        raise SystemExit(f"istftnet.py not found under {site_packages}")
    return p


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_mlx.py <site-packages-dir>")
    path = find_istftnet(Path(sys.argv[1]))
    src = path.read_text()
    if MARKER in src:
        print(f"already patched: {path}")
        return 0
    if ANCHOR not in src:
        raise SystemExit(f"anchor not found in {path}; mlx-audio layout changed — update patch_mlx.py")
    path.write_text(src.replace(ANCHOR, REPLACEMENT, 1))
    print(f"patched: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
