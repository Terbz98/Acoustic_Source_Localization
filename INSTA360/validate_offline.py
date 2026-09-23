"""
validate_offline.py -- does the Python/live path reproduce the MATLAB results?

Runs the recorded two-mic takes (the same list as test_all_takes.m) through
the exact estimator the live tracker uses, and prints one scoreboard against
the tape-measured ground truth.

The one real difference from MATLAB: the Zylia is fed its RAW 19-capsule file
(the live driver gives raw capsules; there is no ambisonic converter in the
loop) and steered with the rigid-sphere capsule model. Pass --sh to also run
the converted 16-channel ACN/SN3D files through the SH path, which is a
straight port of run_doa.m, to compare the two.

    .venv/bin/python validate_offline.py            # from INSTA360/
    .venv/bin/python validate_offline.py --sh

Recordings are read from <repo>/data/ if it exists, otherwise from the repo root.
"""

import use_project_python  # noqa: F401  (restarts on .venv/bin/python if needed)
import argparse
import os
import sys
import time

import numpy as np
import soundfile as sf

from doa_core import SrpArray, whole_file_map, zylia_config, zoom_config, wrap180, ZYLIA_RADIUS
from fusion import Triangulator, rig_layout

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
# recordings: <repo>/data/ if it exists, else the repo root (like matlab/setup_paths.m)
DATA = os.path.join(REPO, 'data') if os.path.isdir(os.path.join(REPO, 'data')) else REPO

# name, zylia raw, zoom, gt az, gt el, gt r (from MIDPOINT), yawB, layout,
# MATLAB result (az, el, r) from the 2026-08-18/21 scoreboard in README.md
TAKES = [
    ('11 Aug front voice', '2miczyliafront',       '2miczoomfront.WAV',        0.0,  0.0, 1.50,   4.75, 'LR', None),
    ('11 Aug front clap',  '2micclapzyliafront',   '2micclapzoomfront.WAV',    0.0,  0.0, 1.50,   4.75, 'LR', (-5.0, None, 2.78)),
    ('11 Aug back clap',   '2micclapzyliaback',    '2micclapzoomback.WAV',   180.0,  0.0, 1.50,   4.75, 'LR', (0.7, None, 1.56)),
    ('in front of ZYLIA',  '2micdirectfrontzylia1', '2micdirectfrontzoom1.WAV', -18.43, 0.0, 1.5811, 5.40, 'LR', (-0.7, None, 1.52)),
    ('in front of ZOOM',   '2micdirectfrontzylia2', '2micdirectfrontzoom2.WAV', 18.43, 0.0, 1.5811, 5.40, 'LR', (-2.7, None, 1.62)),
    ('centre + elevated',  '2micfrontelzylia',     '2micfrontelzoom.WAV',      0.0, 16.9, 1.568,  5.40, 'LR', (-0.7, 15.6, 1.66)),
    ('LEFT (FB)',          '2micleftzylia',        '2micleftzoom.WAV',        90.0,  0.0, 1.50,   0.0,  'FB', (6.2, None, 3.14)),
    ('RIGHT (BF)',         '2micrightzylia',       '2micrightzoom.WAV',      -90.0,  0.0, 1.50,   0.0,  'BF', (2.4, None, 2.40)),
]


def envelope_offset(a, fa, b, fb, max_lag=15.0, rate=200):
    """Coarse clock alignment on the loudness envelope (step 1 of
    align_two_mics.m). Returns tB = tA + offset."""
    def env(x, fs):
        q = int(fs // rate)
        n = x.size // q
        return np.sqrt((x[:n * q].reshape(n, q) ** 2).mean(1))
    ea, eb = env(a, fa), env(b, fb)
    ea = (ea - ea.mean()) / (np.linalg.norm(ea - ea.mean()) + 1e-12)
    eb = (eb - eb.mean()) / (np.linalg.norm(eb - eb.mean()) + 1e-12)
    n = 1 << int(np.ceil(np.log2(ea.size + eb.size)))
    c = np.fft.irfft(np.fft.rfft(eb, n) * np.conj(np.fft.rfft(ea, n)), n)
    lags = np.r_[np.arange(0, eb.size), np.arange(-(ea.size - 1), 0)]
    cc = np.r_[c[:eb.size], c[n - ea.size + 1:]]
    keep = np.abs(lags) <= max_lag * rate
    i = np.argmax(cc[keep])
    return lags[keep][i] / rate, cc[keep][i]


def run_take(t, use_sh=False, verbose=False):
    name, zf, of, gaz, gel, gr, yawB, layout, ml = t
    zfile = os.path.join(DATA, zf + ('_(ACN-SN3D-3).wav' if use_sh else '.wav'))
    ofile = os.path.join(DATA, of)
    if not (os.path.exists(zfile) and os.path.exists(ofile)):
        return None
    xz, fz = sf.read(zfile, dtype='float32', always_2d=True)
    xo, fo = sf.read(ofile, dtype='float32', always_2d=True)

    # trim both to their common span (align_two_mics.m, envelope step)
    off, r = envelope_offset(xz.mean(1) if xz.shape[1] == 19 else xz[:, 0], fz, xo[:, 0], fo)
    t0 = max(0.0, -off)
    t1 = min(xz.shape[0] / fz, xo.shape[0] / fo - off)
    xz = xz[int(t0 * fz):int(t1 * fz)]
    xo = xo[int((t0 + off) * fo):int((t1 + off) * fo)]

    if use_sh:
        zc = zylia_config(fs=fz, kind='sh', order=3, channels=tuple(range(16)))
    else:
        zc = zylia_config(fs=fz)
    zs = SrpArray(zc)
    os_ = SrpArray(zoom_config(fs=fo))
    mA = whole_file_map(zs, xz)
    mB = whole_file_map(os_, xo)

    B = 1.0
    posA, posB = rig_layout(layout, B)
    tri = Triangulator(posA, posB, zs.az_deg, yawA=0.0, yawB=yawB, span=6, step=0.02)
    fr = tri.fuse(mA['pAz'], mB['pAz'], mA['az'], mB['az'])

    zS = fr.rA * np.tan(np.radians(mA['el']))
    pos = np.r_[fr.pos, zS]
    rH = np.hypot(pos[0], pos[1])
    r = float(np.hypot(rH, zS))
    az = float(np.degrees(np.arctan2(pos[1], pos[0])))
    el = float(np.degrees(np.arctan2(zS, rH)))

    # what each mic should have seen
    g = gr * np.array([np.cos(np.radians(gel)) * np.cos(np.radians(gaz)),
                       np.cos(np.radians(gel)) * np.sin(np.radians(gaz)),
                       np.sin(np.radians(gel))])
    gA = np.degrees(np.arctan2(g[1] - posA[1], g[0] - posA[0]))
    return dict(name=name, az=az, el=el, r=r, gaz=gaz, gel=gel, gr=gr,
                azA=mA['az'], elA=mA['el'], azB=mB['az'], gA=gA,
                nA=mA['n_active'], nB=mB['n_active'], trusted=fr.trusted,
                warn=fr.warning, ml=ml, align_r=r)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sh', action='store_true',
                    help='also run the converted ACN/SN3D Zylia files through the SH path')
    args = ap.parse_args()
    modes = [False, True] if args.sh else [False]
    for use_sh in modes:
        print('\n' + '=' * 112)
        print('  Zylia path: ' + ('CONVERTED 16-ch ACN/SN3D, SH order 3 (port of run_doa.m)' if use_sh
                                   else 'RAW 19 capsules, rigid-sphere model (what the LIVE tracker uses)'))
        print('=' * 112)
        print(f"{'take':20s} {'zylia az':>9s} {'(truth)':>8s} {'el':>6s} {'| az':>7s} {'err':>6s} "
              f"{'el':>6s} {'err':>6s} {'r':>6s} {'err':>6s} | {'MATLAB az / el / r':>20s}  verdict")
        print('-' * 112)
        for t in TAKES:
            t0 = time.time()
            R = run_take(t, use_sh)
            if R is None:
                print(f'{t[0]:20s}  (files not found, skipped)')
                continue
            ml = R['ml']
            mls = '--' if ml is None else (f"{ml[0]:+.1f} / " + ('--' if ml[1] is None else f'{ml[1]:+.1f}')
                                           + f' / {ml[2]:.2f}')
            rs = f"{R['r']:6.2f} {100 * (R['r'] - R['gr']) / R['gr']:+5.0f}%" if R['trusted'] \
                else f"{'--':>6s} {'--':>6s}"
            print(f"{R['name']:20s} {R['azA']:+9.1f} {R['gA']:+8.1f} {R['elA']:+6.1f} "
                  f"{R['az']:+7.1f} {float(wrap180(R['az'] - R['gaz'])):+6.1f} "
                  f"{R['el']:+6.1f} {R['el'] - R['gel']:+6.1f} {rs} | {mls:>20s}  "
                  f"{'TRUSTED' if R['trusted'] else 'rejected'}  ({time.time() - t0:.0f}s)")
            if R['warn']:
                print(f"{'':22s}-> {R['warn']}")
    print('\naz/el/r are of the SOURCE from the midpoint of the two mics; "zylia az" is the\n'
          'Zylia\'s own bearing and "(truth)" what it should have read. MATLAB column from\n'
          'the README scoreboard (distance there is also from the midpoint).')


if __name__ == '__main__':
    main()
