"""
analyze_recording.py -- the three figures of main_2mic.m, for any recording.

MATLAB's main_2mic.m ends with three figures: the per-frame estimates, each
mic's direction score (a polar plot) and the fused top-down position map. The
live tracker draws the live versions of these in its window but saves none of
them. This script draws them afterwards from the WAV files the tracker records
(R key or --record), or from the old MATLAB takes, with the same estimator as
the live tracker (doa_core.py, fusion.py).

From INSTA360/:

    .venv/bin/python analyze_recording.py recordings/live_20260928_153408              # whole recording
    .venv/bin/python analyze_recording.py recordings/live_20260928_153408 --sound 118  # one sound
    .venv/bin/python analyze_recording.py recordings/live_20260928_153408 --from 148 --to 181
    .venv/bin/python analyze_recording.py ../2micdirectfrontzylia1.wav ../2micdirectfrontzoom1.WAV \\
            --truth -18.43 0 1.5811 --yaw-zoom 5.4

--sound N picks sound N from the sound list the tracker saved in logs/ (the
same numbers as in the window and the CSV). The figures are saved as PNGs in
logs/figures/; add --show to also open them in windows, like MATLAB.

For a recording where the sound moves (like a whole live session), figures 2
and 3 add up everything in the chosen time, so pick one sound or a short
stretch to get one position; figure 1 is useful over any length.
"""

import use_project_python  # noqa: F401  (restarts on .venv/bin/python if needed)

import argparse
import csv
import datetime
import glob
import json
import os
import sys

import numpy as np
import soundfile as sf

import rig_config as RC
from doa_core import (Framer, LiveGate, MapAccumulator, SrpArray, frame_weights_and_norm,
                      profile_peaks, az360, wrap180, zoom_config, zylia_config)
from fusion import Triangulator, rig_layout

HERE = os.path.dirname(os.path.abspath(__file__))

# Zylia orange and Zoom teal, as in the tracker's radar. Checked with the
# data-viz palette validator (light, on white, all pairs): every check passes.
ZYLIA_C, ZOOM_C = '#E07A22', '#0F8FA3'
INK, INK2, MUTED, GRID, AXIS, RED = '#1E2B36', '#52514E', '#898781', '#E1E0D9', '#C3C2B7', '#C0392B'
CHUNK_S = 5.0                                   # audio is read this much at a time


# ======================= inputs ==========================================
def find_inputs(paths):
    """A recording stem (recordings/live_<stamp>, or any of its files), or a
    Zylia file and a Zoom file. Returns zylia, zoom, sync json, name."""
    if len(paths) == 1:
        stem = paths[0]
        for suf in ('_zylia19.wav', '_zoom_ambix.wav', '_zoom_fuma.wav', '_x4_stereo.wav',
                    '_sync.json', '_video.mp4'):
            if stem.endswith(suf):
                stem = stem[:-len(suf)]
        zf = stem + '_zylia19.wav'
        of = next((p for p in (stem + '_zoom_ambix.wav', stem + '_zoom_fuma.wav') if os.path.exists(p)),
                  None)
        sync = stem + '_sync.json' if os.path.exists(stem + '_sync.json') else None
        if not os.path.exists(zf):
            sys.exit(f'No Zylia recording found at {zf}')
        return zf, of, sync, os.path.basename(stem)
    if len(paths) == 2:
        zf, of = paths
        return zf, of, None, os.path.splitext(os.path.basename(zf))[0].replace('_(ACN-SN3D-3)', '')
    sys.exit('Give a recording (recordings/live_<date>_<time>) or a Zylia file and a Zoom file.')


def zoom_offset(zf, of, sync):
    """Seconds to add to a Zylia-file time to get the same moment in the Zoom
    file. Exact from _sync.json; otherwise matched on the loudness envelopes
    (align_two_mics.m, first step) over the first minute."""
    if sync:
        st = json.load(open(sync))['start_wall_s']
        if 'zylia' in st and 'zoom' in st:
            return st['zylia'] - st['zoom'], "from the recording's timing file"
    from validate_offline import envelope_offset
    a, fa = sf.read(zf, frames=60 * sf.info(zf).samplerate, dtype='float32', always_2d=True)
    b, fb = sf.read(of, frames=60 * sf.info(of).samplerate, dtype='float32', always_2d=True)
    off, _ = envelope_offset(a[:, :19].mean(1) if a.shape[1] >= 19 else a[:, 0], fa, b[:, 0], fb)
    return off, 'matched on the loudness of the two files'


def sound_window(n, sync, log):
    """Start/end (Zylia-file seconds) of sound n from the tracker's sound list."""
    if not sync:
        sys.exit('--sound needs a recording made by the tracker (with its _sync.json).')
    S = json.load(open(sync))
    t_stream0, t_file0 = S.get('zylia_stream_start_wall_s'), S['start_wall_s'].get('zylia')
    if t_stream0 is None or t_file0 is None:
        sys.exit('The timing file has no stream start time; use --from / --to instead.')
    if log is None:              # the sound list whose name is closest to the stream start
        cands = []
        for p in glob.glob(os.path.join(HERE, 'logs', 'sounds_*.csv')):
            try:
                t = datetime.datetime.strptime(os.path.basename(p)[7:22], '%Y%m%d_%H%M%S').timestamp()
            except ValueError:
                continue
            cands.append((abs(t - t_stream0), p))
        if not cands or min(cands)[0] > 30:
            sys.exit('Could not find the sound list for this recording; pass it with --log.')
        log = min(cands)[1]
    row = next((r for r in csv.DictReader(open(log)) if int(r['sound']) == n), None)
    if row is None:
        sys.exit(f'Sound #{n} is not in {log}')
    t0 = float(row['time_s']) - (t_file0 - t_stream0)
    t1 = t0 + float(row['duration_s'])
    if t1 < 0:
        sys.exit(f'Sound #{n} happened before the recording started (R was pressed later).')
    return t0 - 0.1, t1 + 0.1, row


# ======================= analysis ========================================
def analyse(srp, path, t0, t1, gate_mode='live', history_s=20.0):
    """Frames of one array between t0 and t1 (seconds in this file): the
    loudness gates, each active frame's own peak (the per-frame estimates) and
    the decisiveness-weighted sum of all of them (the accumulated profiles
    that the position comes from).

    gate_mode 'live': exactly the live tracker's gate (LiveGate over the
    previous history_s seconds, fed a couple of frames at a time), so the
    numbers match what the tracker logged. 'file': az_power_map.m's gate,
    levels taken over the whole window, as MATLAB does on a take."""
    cfg = srp.cfg
    info = sf.info(path)
    fs = info.samplerate
    w0, w1 = t0, t1
    if gate_mode == 'live':
        t0 = t0 - history_s                  # the gate needs the history before the window
    i0, i1 = max(0, int(round(t0 * fs))), min(info.frames, int(round(t1 * fs)))
    framer = Framer(cfg.frame_len, cfg.hop, len(cfg.channels))
    F_all, E_all, clip_all = [], [], []
    chunk = int(CHUNK_S * fs)
    for c0 in range(i0, i1, chunk):
        x, _ = sf.read(path, start=c0, stop=min(i1, c0 + chunk), dtype='float32', always_2d=True)
        frames = framer.push(x[:, list(cfg.channels)])
        if not len(frames):
            continue
        clip_all.append(np.abs(frames).max(axis=(1, 2)) > cfg.clip_level)
        T, L, C = frames.shape
        xs = srp.prepare(frames.reshape(T * L, C))     # AmbiX -> ACN/N3D for the Zoom
        F, E = srp.spectra(xs.reshape(T, L, -1))
        F_all.append(F)
        E_all.append(E)
    if not E_all:
        sys.exit(f'{os.path.basename(path)}: nothing to analyse between {t0:.2f} and {t1:.2f} s')
    F, E, clip = np.concatenate(F_all), np.concatenate(E_all), np.concatenate(clip_all)
    t = i0 / fs + (np.arange(E.size) * cfg.hop + cfg.frame_len / 2) / fs
    inside = (t >= w0) & (t <= w1)                   # the history only sets the gate levels
    if gate_mode == 'live':
        g = LiveGate(fs / cfg.hop, RC.ENERGY_GATE_DB, RC.SNR_GATE_DB, history_s=history_s)
        loud_enough = np.zeros(E.size, bool)
        for k in range(0, E.size, 2):                 # live, audio arrives ~2 frames at a time
            loud_enough[k:k + 2] = g(E[k:k + 2])[0]
    else:
        noise, loud = np.quantile(E[inside], 0.10), np.quantile(E[inside], 0.95)
        loud_enough = E >= max(loud * 10 ** (RC.ENERGY_GATE_DB / 20), noise * 10 ** (RC.SNR_GATE_DB / 20))
    F, E, clip, t, loud_enough = F[inside], E[inside], clip[inside], t[inside], loud_enough[inside]
    active = loud_enough & ~clip
    ia = np.flatnonzero(active)
    az_f = np.full(E.size, np.nan)
    el_f = np.full(E.size, np.nan)
    acc = MapAccumulator(srp.az_deg.size, srp.el_deg.size, 1.0, tau_s=np.inf)
    for k0 in range(0, ia.size, 256):
        k = ia[k0:k0 + 256]
        P = srp.maps(F[k])
        a, e = np.unravel_index(P.reshape(len(k), -1).argmax(axis=1), srp.shape)
        az_f[k] = srp.az_deg[a]
        el_f[k] = srp.el_deg[e]
        pAz, pEl, w = frame_weights_and_norm(P)
        acc.step(0, pAz, pEl, w)
    pAz, pEl = acc.profiles()
    az, el = profile_peaks(pAz, pEl, srp.az_deg, srp.el_deg)
    return dict(t=t, active=active, az_f=az_f, el_f=el_f, pAz=pAz, pEl=pEl, az=az, el=el,
                az_deg=srp.az_deg, n_active=int(active.sum()), n_clip=int(clip.sum()))


def per_frame_distance(A, B, posA, posB):
    """Cross the two mics' bearings frame by frame (main_2mic.m per_frame_range):
    frames active on both at the same moment, crossings in front of both mics
    only. Distance from the midpoint, with the Zylia's elevation, like the
    tracker's 'dist'."""
    ta, tb = A['t'][A['active']], B['t'][B['active']]
    if not ta.size or not tb.size:
        return np.array([]), np.array([])
    azA, elA = A['az_f'][A['active']], A['el_f'][A['active']]
    azB = B['az_f'][B['active']]
    j = np.clip(np.searchsorted(tb, ta), 1, tb.size - 1)
    j = np.where(np.abs(tb[j - 1] - ta) < np.abs(tb[j] - ta), j - 1, j)
    same = np.abs(tb[j] - ta) < 0.006                  # the same 21 ms frame on both clocks
    mid = (posA + posB) / 2
    t, r = [], []
    for k in np.flatnonzero(same):
        aA, aB = np.radians(azA[k] - A['yaw']), np.radians(azB[j[k]] - B['yaw'])
        dA, dB = np.array([np.cos(aA), np.sin(aA)]), np.array([np.cos(aB), np.sin(aB)])
        M = np.column_stack([dA, -dB])
        if abs(np.linalg.det(M)) < 1e-6:
            continue
        s = np.linalg.solve(M, posB - posA)
        if s[0] <= 0 or s[1] <= 0:
            continue
        p = posA + s[0] * dA
        t.append(ta[k])
        r.append(float(np.hypot(np.linalg.norm(p - mid), s[0] * np.tan(np.radians(elA[k])))))
    return np.array(t), np.array(r)


# ======================= figures =========================================
def style(ax):
    for sp in ('top', 'right'):
        ax.spines[sp].set_visible(False)
    for sp in ('left', 'bottom'):
        ax.spines[sp].set_color(AXIS)
    ax.tick_params(colors=MUTED, length=0)
    ax.grid(True, color=GRID, lw=0.8)
    ax.set_axisbelow(True)


def mmss(x, _=None):
    m, s = divmod(max(x, 0), 60)
    return f'{int(m)}:{int(s):02d}'


def fig_per_frame(plt, A, B, dist_t, dist_r, res, truth, label):
    fig, ax = plt.subplots(3, 1, figsize=(11, 8.2), sharex=True,
                           gridspec_kw={'height_ratios': [1.25, 1, 1]})
    fig.subplots_adjust(left=0.11, right=0.97, top=0.88, bottom=0.08, hspace=0.18)
    long = A['t'][-1] - A['t'][0] > 30
    ms = 5 if long else 16
    for D, c, name in ((A, ZYLIA_C, 'Zylia'), (B, ZOOM_C, 'Zoom')):
        if D is None:
            continue
        a = D['active']
        ax[0].scatter(D['t'][a], (D['az_f'][a] - D['yaw']) % 360, s=ms, c=c, lw=0, alpha=0.75, label=name)
        ax[1].scatter(D['t'][a], D['el_f'][a], s=ms, c=c, lw=0, alpha=0.75, label=name)
    if truth is not None:
        ax[0].axhline(truth['azA'] % 360, color=ZYLIA_C, ls='--', lw=1.2)
        ax[0].axhline(truth['azB'] % 360, color=ZOOM_C, ls='--', lw=1.2)
        ax[1].axhline(truth['el'], color=INK2, ls='--', lw=1.2)
    ax[0].set_ylim(-10, 370)
    ax[0].set_yticks([0, 90, 180, 270, 360])
    ax[0].set_yticklabels(['front 0°', 'left 90°', 'behind 180°', 'right 270°', 'front 360°'])
    ax[0].set_ylabel('azimuth', color=INK2)
    ax[0].legend(loc='upper right', markerscale=2.2 if long else 1.2, fontsize=10.5, ncol=2,
                 frameon=True, facecolor='white', edgecolor='none', framealpha=1)
    ax[1].set_ylabel('up–down (°)', color=INK2)
    if dist_r.size:
        ax[2].scatter(dist_t, dist_r, s=ms, c=INK2, lw=0, alpha=0.55, label='per frame')
    if res['trusted'] and not long:          # one position means nothing over a long, moving recording
        ax[2].axhline(res['r'], color=INK, lw=1.6, label=f"from the fused map: {res['r']:.2f} m")
    if truth is not None:
        ax[2].axhline(truth['r'], color=RED, ls='--', lw=1.2, label=f"truth: {truth['r']:.2f} m")
    ax[2].set_ylim(0, 5)
    ax[2].set_ylabel('distance (m)', color=INK2)
    if dist_r.size or res['trusted'] or truth is not None:
        ax[2].legend(loc='upper right', fontsize=10.5, ncol=3,
                     frameon=True, facecolor='white', edgecolor='none', framealpha=1)
    if long:
        from matplotlib.ticker import FuncFormatter
        ax[2].xaxis.set_major_formatter(FuncFormatter(mmss))
        ax[2].set_xlabel('time in the recording (minutes:seconds)', color=INK2)
    else:
        ax[2].set_xlabel('time in the recording (seconds)', color=INK2)
    for a in ax:
        style(a)
    med = f'median {np.median(dist_r):.2f} m' if dist_r.size else 'no crossings'
    fig.suptitle(f'Per-frame estimates\n{label}\n'
                 f'each dot is one 21 ms frame that passed the loudness gates  ·  per-frame distance: {med}',
                 color=INK, fontsize=12)
    return fig


def fig_polar(plt, A, B, truth, label):
    fig = plt.figure(figsize=(7.4, 7.8))
    ax = fig.add_subplot(projection='polar')
    ax.set_theta_zero_location('N')                   # front at the top
    ax.set_theta_direction(1)                         # counter-clockwise = to the left
    for D, c, name in ((A, ZYLIA_C, 'Zylia'), (B, ZOOM_C, 'Zoom')):
        if D is None:
            continue
        th = np.radians(np.r_[D['az_deg'], D['az_deg'][:1]] - D['yaw'])     # into the rig frame
        ax.plot(th, np.r_[D['pAz'], D['pAz'][:1]], color=c, lw=2,
                label=f"{name}: peak {az360(D['az'] - D['yaw']):.1f}°")
    if truth is not None:
        for g, c in ((truth['azA'], ZYLIA_C), (truth['azB'], ZOOM_C)):
            ax.plot([np.radians(g)] * 2, [0, 1.05], color=c, ls='--', lw=1.2)
    ax.set_rlim(0, 1.05)
    ax.set_rticks([0.25, 0.5, 0.75, 1.0])
    ax.set_yticklabels([])
    ax.set_thetagrids([0, 45, 90, 135, 180, 225, 270, 315],
                      ['front 0°', '45°', 'left 90°', '135°', 'behind 180°', '225°', 'right 270°', '315°'], color=INK2)
    ax.grid(color=GRID)
    ax.spines['polar'].set_color(AXIS)
    ax.legend(loc='upper center', bbox_to_anchor=(0.5, -0.06), frameon=False, ncol=2, fontsize=10.5)
    ax.set_title(f'How well each direction matches what each mic heard\n{label}\n'
                 'each mic points at the sound from where it stands, so the two peaks differ',
                 color=INK, fontsize=11.5, pad=20)
    fig.subplots_adjust(bottom=0.12, top=0.8)
    return fig


def fig_map(plt, tri, res, posA, posB, truth, label, has_zoom):
    from matplotlib.colors import LinearSegmentedColormap
    fig, ax = plt.subplots(figsize=(7.6, 7.8))
    cmap = LinearSegmentedColormap.from_list('teal', ['#FFFFFF', '#BFE3EA', '#3AA2B5', '#0B4F5C'])
    S = res['S'] / max(float(res['S'].max()), 1e-12)
    img = S[::-1, ::-1]                   # rows: front at the top; columns: left on the left
    ext = [-tri.yg.max(), -tri.yg.min(), tri.xg.min(), tri.xg.max()]
    im = ax.imshow(img, extent=ext, cmap=cmap, vmin=0, vmax=1, interpolation='bilinear')
    cb = fig.colorbar(im, ax=ax, fraction=0.046, pad=0.03)
    cb.set_label('how much both mics agree (1 = most)', color=INK2)
    cb.outline.set_visible(False)
    cb.ax.tick_params(colors=MUTED, length=0)
    for p, name, c in ((posA, 'Zylia', ZYLIA_C), (posB, 'Zoom', ZOOM_C)):
        ax.plot(-p[1], p[0], 'o', ms=11, mfc=c, mec='white', mew=2)
        ax.annotate(name, (-p[1], p[0]), xytext=(0, -18), textcoords='offset points', ha='center',
                    color=INK, fontsize=10.5)
    txt = ''
    if has_zoom:
        pos = res['pos']
        ax.plot(-pos[1], pos[0], '+', ms=18, mew=2.5, color=INK)
        txt = (f"+ estimate: {res['r']:.2f} m away ({float(np.hypot(*pos)):.2f} m along the floor, "
               f"{res['r'] * np.sin(np.radians(res['el'])):+.2f} m up)" if res['trusted']
               else '+ best spot (distance not trusted)')
    else:
        ax.text(0, 1.0, 'no Zoom recording, so no distance', ha='center', color=INK2)
    if truth is not None:
        ax.plot(-truth['y'], truth['x'], 'x', ms=14, mew=2.5, color=RED)
        txt += f"     × truth: {truth['r']:.2f} m"
    ax.set_xlim(-3.5, 3.5)
    ax.set_ylim(-3.5, 3.5)
    ax.set_aspect('equal')
    ax.set_xlabel('←  left      metres      right  →', color=INK2)
    ax.set_ylabel('←  behind      metres      front  →', color=INK2)
    style(ax)
    ax.grid(False)
    ax.set_title(f'Where the sound is, seen from above\n{label}\n{txt}', color=INK, fontsize=11.5)
    return fig


# ======================= main ============================================
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('inputs', nargs='*',
                    help='recordings/live_<date>_<time>, or ZYLIA.wav ZOOM.wav (default: the newest recording)')
    ap.add_argument('--sound', type=int, help='just this sound, by its number in the sound list')
    ap.add_argument('--log', help='the sound list (logs/sounds_*.csv); found by itself if left out')
    ap.add_argument('--from', dest='t_from', type=float, help='start, seconds into the recording')
    ap.add_argument('--to', dest='t_to', type=float, help='end, seconds into the recording')
    ap.add_argument('--truth', nargs=3, type=float, metavar=('AZ', 'EL', 'R'),
                    help='where the sound really was: az (0-360, 90 = left, 270 = right; -90 also works), el (deg) and distance (m) from the midpoint')
    ap.add_argument('--layout', default=RC.LAYOUT, help=f'rig layout (default {RC.LAYOUT}, rig_config.py)')
    ap.add_argument('--baseline', type=float, default=RC.BASELINE_M, help='metres between the mics')
    ap.add_argument('--yaw-zylia', type=float, default=RC.YAW_ZYLIA_DEG)
    ap.add_argument('--yaw-zoom', type=float, default=RC.YAW_ZOOM_DEG)
    ap.add_argument('--out', default=os.path.join(HERE, 'logs', 'figures'), help='folder for the PNGs')
    ap.add_argument('--show', action='store_true', help='also open the figures in windows')
    args = ap.parse_args()

    import matplotlib
    if not args.show:
        matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    plt.rcParams.update({'font.family': 'Arial', 'font.size': 11.5, 'axes.labelcolor': INK2})

    if not args.inputs:                 # e.g. the Run button: take the newest recording
        rec = sorted(glob.glob(os.path.join(HERE, 'recordings', 'live_*_zylia19.wav')))
        if not rec:
            sys.exit('No recordings in recordings/ yet. Record with R in the tracker, or give two WAV files.')
        args.inputs = [rec[-1]]
        print('No recording named, so using the newest one.')
    zf, of, sync, name = find_inputs(args.inputs)
    gate_mode = 'live' if sync else 'file'
    fz = sf.info(zf)
    end = fz.frames / fz.samplerate
    off, how = (0.0, '') if of is None else zoom_offset(zf, of, sync)
    if of is not None:
        fo = sf.info(of)
        end = min(end, fo.frames / fo.samplerate - off)      # the part both files cover
    start = max(0.0, -off)
    t0, t1, what = start, end, 'whole recording'
    if args.sound is not None:
        t0, t1, row = sound_window(args.sound, sync, args.log)
        what = (f"sound #{args.sound} at {row['clock']}: the tracker said az {az360(float(row['azimuth_deg'])):.1f}°, "
                f"el {float(row['elevation_deg']):+.1f}°, "
                + (f"{float(row['distance_m']):.2f} m" if row['distance_m'] else 'no distance'))
    if args.t_from is not None or args.t_to is not None:
        t0 = args.t_from if args.t_from is not None else t0
        t1 = args.t_to if args.t_to is not None else t1
        what = f'{mmss(t0)} to {mmss(t1)}'
    t0, t1 = max(t0, start), min(t1, end)
    if t1 - t0 < 0.1:
        sys.exit(f'The window {t0:.2f}-{t1:.2f} s is outside the recording.')
    label = f'{name}  ·  {what}'

    print(f'Zylia : {zf}')
    if of:
        print(f'Zoom  : {of}   (Zoom time = Zylia time {off:+.3f} s, {how})')
    print(f'Window: {t0:.2f} to {t1:.2f} s  ({what})')

    nz = fz.channels
    if nz >= 19:
        zc = zylia_config(fs=fz.samplerate)
    elif nz == 16:
        zc = zylia_config(fs=fz.samplerate, kind='sh', order=3, channels=tuple(range(16)),
                          in_format='ambix', f_band=(1000, 12000))
    else:
        sys.exit(f'{zf}: {nz} channels -- expected the raw 19-capsule file or the converted 16-channel one')
    print('Analysing the Zylia...', end=' ', flush=True)
    zs = SrpArray(zc)
    A = analyse(zs, zf, t0, t1, gate_mode)
    A['yaw'] = args.yaw_zylia
    print(f"{A['n_active']} frames used.")
    if A['n_active'] == 0:
        sys.exit('No Zylia frame in this window passed the loudness gates -- try a longer window.')
    B = None
    if of:
        print('Analysing the Zoom...', end=' ', flush=True)
        srpB = SrpArray(zoom_config(fs=sf.info(of).samplerate,
                                    in_format='fuma' if 'fuma' in of.lower() else 'ambix'))
        B = analyse(srpB, of, t0 + off, t1 + off, gate_mode)
        B['t'] = B['t'] - off                                  # on the Zylia's clock
        B['yaw'] = args.yaw_zoom
        print(f"{B['n_active']} frames used ({B['n_clip']} clipped frames left out).")

    posA, posB = rig_layout(args.layout, args.baseline)
    tri = Triangulator(posA, posB, zs.az_deg, yawA=args.yaw_zylia, yawB=args.yaw_zoom, span=4.0, step=0.02)
    if B is not None:
        fr = tri.fuse(A['pAz'], B['pAz'], A['az'], B['az'])
        zS = fr.rA * np.tan(np.radians(A['el']))
        rH = float(np.hypot(*fr.pos))
        res = dict(pos=fr.pos, r=float(np.hypot(rH, zS)), az=float(np.degrees(np.arctan2(fr.pos[1], fr.pos[0]))),
                   el=float(np.degrees(np.arctan2(zS, rH))), trusted=fr.trusted, warning=fr.warning, S=fr.S)
        dist_t, dist_r = per_frame_distance(A, B, posA, posB)
    else:
        res = dict(pos=np.zeros(2), r=float('nan'), az=float(wrap180(A['az'] - args.yaw_zylia)), el=A['el'],
                   trusted=False, warning='no Zoom recording', S=np.zeros((tri.xg.size, tri.yg.size)))
        dist_t, dist_r = np.array([]), np.array([])

    truth = None
    if args.truth:
        gaz, gel, gr = args.truth
        g = gr * np.array([np.cos(np.radians(gel)) * np.cos(np.radians(gaz)),
                           np.cos(np.radians(gel)) * np.sin(np.radians(gaz)), np.sin(np.radians(gel))])
        truth = dict(az=gaz, el=gel, r=gr, x=g[0], y=g[1],
                     azA=float(np.degrees(np.arctan2(g[1] - posA[1], g[0] - posA[0]))),
                     azB=float(np.degrees(np.arctan2(g[1] - posB[1], g[0] - posB[0]))))

    print('\n=============== SOURCE, from the midpoint of the two mics ===============')
    rs = f"{res['r']:.2f} m" if res['trusted'] else f"--  ({res['warning']})"
    print(f"Estimate : az {az360(res['az']):6.1f} deg | el {res['el']:+6.1f} deg | r {rs}")
    if truth is not None:
        print(f"Truth    : az {az360(truth['az']):6.1f} deg | el {truth['el']:+6.1f} deg | r {truth['r']:.2f} m")
        print(f"Error    : az {float(wrap180(res['az'] - truth['az'])):+7.1f} deg | "
              f"el {res['el'] - truth['el']:+6.1f} deg | r {res['r'] - truth['r']:+.2f} m")
    print(f"Per mic  : Zylia {az360(A['az'] - A['yaw']):.1f} deg (el {A['el']:+.1f})"
          + (f", Zoom {az360(B['az'] - B['yaw']):.1f} deg" if B is not None else ''))
    if dist_r.size:
        print(f'Per frame: {dist_r.size} crossings, median distance {np.median(dist_r):.2f} m')

    os.makedirs(args.out, exist_ok=True)
    tag = name
    if args.sound is not None:
        tag += f'_sound{args.sound:03d}'
    if args.t_from is not None or args.t_to is not None:
        tag += f'_{t0:.0f}-{t1:.0f}s'
    figs = [(fig_per_frame(plt, A, B, dist_t, dist_r, res, truth, label), '1_per_frame'),
            (fig_polar(plt, A, B, truth, label), '2_direction_scores'),
            (fig_map(plt, tri, res, posA, posB, truth, label, B is not None), '3_position_map')]
    print()
    for f, k in figs:
        p = os.path.join(args.out, f'{tag}_{k}.png')
        f.savefig(p, dpi=150, facecolor='white')
        print(f'Saved {p}')
    if args.show:
        plt.show()


if __name__ == '__main__':
    main()
