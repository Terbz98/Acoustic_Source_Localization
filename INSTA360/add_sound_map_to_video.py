"""
add_sound_map_to_video.py -- redo the 360 strip of a recorded window video
with the sound heat map (sound_map.py), as a NEW file next to the original.

The tracker's window video shows a green circle (where the view points) and a
red cross (where the sound is) on the 360 strip. This replays the recorded
audio through the tracker's own pipeline (same gate, same 0.6 s memory),
paints the az x el sound map over the strip of every video frame, removes the
old circle and cross, and keeps the original sound, moved by the difference
between how late the X4's picture and its microphone are
(rig_config.X4_PICTURE_DELAY_S minus X4_AUDIO_DELAY_S: the picture is later,
so the sound is moved later) so sound and picture line up.

    .venv/bin/python add_sound_map_to_video.py recordings/live_20260928_153408
    -> recordings/live_20260928_153408_video_soundmap.mp4   (the original is untouched)
"""

import use_project_python  # noqa: F401  (restarts on .venv/bin/python if needed)

import json
import os
import sys
import time

import cv2
import numpy as np
import soundfile as sf

import rig_config as RC
from doa_core import (Framer, LiveGate, MapAccumulator, SrpArray, frame_weights_and_norm,
                      profile_peaks, zoom_config, zylia_config)
from fusion import Triangulator, rig_layout
from sound_map import MapAccumulator2D, camera_values, paint

# the window the tracker films (gui_loop): canvas 2750 x 1590 at 2x; the 360
# strip is its bottom-left 1760 x 600, cut from a 1760 x 880 panorama 140 rows down
CANVAS_W, STRIP_X1, STRIP_Y0, PANO_W, PANO_TOP = 2750, 1760, 990, 1760, 140


def replay(path, srp, t_query, gate_hist_s=20.0, tau_s=RC.TAU_S, keep_2d=False, start=0.0):
    """Feed one recorded array through the live pipeline and return its state
    at each time in t_query (seconds in this file): az profile, 2-D map,
    evidence. Same gate and memory as ArrayTracker in live_tracker.py."""
    cfg = srp.cfg
    fs = sf.info(path).samplerate
    rate = fs / cfg.hop
    framer = Framer(cfg.frame_len, cfg.hop, len(cfg.channels))
    gate = LiveGate(rate, RC.ENERGY_GATE_DB, RC.SNR_GATE_DB, history_s=gate_hist_s)
    acc = MapAccumulator(srp.az_deg.size, srp.el_deg.size, rate, tau_s)
    acc2 = MapAccumulator2D(srp.shape, rate, tau_s) if keep_2d else None
    out, q, n_frames = [], 0, 0
    t_query = np.asarray(t_query)
    for blk in sf.blocks(path, blocksize=1024, dtype='float32', always_2d=True,
                         start=int(max(0.0, start) * fs)):
        frames = framer.push(blk[:, list(cfg.channels)])
        T = len(frames)
        if T:
            clip = np.abs(frames).max(axis=(1, 2)) > cfg.clip_level
            xs = srp.prepare(frames.reshape(T * cfg.frame_len, -1)).reshape(T, cfg.frame_len, -1)
            F, E = srp.spectra(xs)
            active, _ = gate(E)
            idx = np.flatnonzero(active & ~clip)
            if idx.size:
                P = srp.maps(F[idx])
                pAz, pEl, w = frame_weights_and_norm(P)
                acc.step(T, pAz, pEl, w)
                if acc2 is not None:
                    acc2.step(T, P, w)
            else:
                acc.step(T)
                if acc2 is not None:
                    acc2.step(T)
            n_frames += T
        t_now = max(0.0, start) + n_frames / rate
        while q < len(t_query) and t_query[q] <= t_now:
            pAz, pEl = acc.profiles()
            out.append(dict(pAz=pAz.copy(), pEl=pEl.copy(), wsum=acc.wsum,
                            map2d=None if acc2 is None else acc2.map(),
                            w2=0.0 if acc2 is None else acc2.wsum))
            q += 1
    while len(out) < len(t_query):
        out.append(out[-1])
    return out


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    stem = sys.argv[1]
    for suf in ('_video.mp4', '_zylia19.wav', '_sync.json'):
        stem = stem[:-len(suf)] if stem.endswith(suf) else stem
    video, sync = stem + '_video.mp4', stem + '_sync.json'
    zf, of = stem + '_zylia19.wav', stem + '_zoom_ambix.wav'
    out_path = stem + '_video_soundmap.mp4'
    for p in (video, sync, zf):
        if not os.path.exists(p):
            sys.exit(f'Missing {p}')
    S = json.load(open(sync))
    st = S['start_wall_s']
    v0 = S['video_start_wall_s']

    cap = cv2.VideoCapture(video)
    fps = cap.get(cv2.CAP_PROP_FPS)
    n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    W, H = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    s = W / CANVAS_W                                        # video pixels per window pixel
    t_video = np.arange(n) / fps
    delay = getattr(RC, 'X4_PICTURE_DELAY_S', 0.0)     # the picture shows the room this much late
    # the original's sound is the X4 mic, placed at its own (late) timestamps
    shift = getattr(RC, 'X4_AUDIO_DELAY_S', 0.0) - delay
    print(f'{os.path.basename(video)}: {n} frames, {W}x{H}, {fps:.0f} fps')

    t0 = time.time()
    print('Replaying the Zylia...', end=' ', flush=True)
    zs = SrpArray(zylia_config(fs=sf.info(zf).samplerate))
    Z = replay(zf, zs, t_video - delay + (v0 - st['zylia']), keep_2d=True)
    print(f'done ({time.time() - t0:.0f} s).')
    O = None
    if os.path.exists(of) and 'zoom' in st:
        t0 = time.time()
        print('Replaying the Zoom...', end=' ', flush=True)
        osr = SrpArray(zoom_config(fs=sf.info(of).samplerate, in_format=RC.ZOOM_FORMAT))
        O = replay(of, osr, t_video - delay + (v0 - st['zoom']))
        print(f'done ({time.time() - t0:.0f} s).')

    posA, posB = rig_layout(RC.LAYOUT, RC.BASELINE_M)
    tri = Triangulator(posA, posB, zs.az_deg, yawA=RC.YAW_ZYLIA_DEG, yawB=RC.YAW_ZOOM_DEG)
    cam = np.asarray(RC.CAMERA_POS_M, float)

    # the strip in video pixels, and the directions its edges stand for
    x1, y0 = int(round(STRIP_X1 * s)), int(round(STRIP_Y0 * s))
    el_top = 90.0 - PANO_TOP / (PANO_W / 2) * 180.0
    gw = 220
    gh = int(round(gw * (H - y0) / x1))
    deg_px = 360.0 / gw
    yaw = RC.CAMERA_YAW_DEG

    tmp = out_path[:-4] + '_silent.mp4'
    wr = cv2.VideoWriter(tmp, cv2.VideoWriter_fourcc(*'mp4v'), fps, (W, H))
    t0 = time.time()
    last_src = cam + np.array([2.0, 0, 0])
    for k in range(n):
        ok, fr = cap.read()
        if not ok:
            break
        strip = fr[y0:H, 0:x1]
        # remove the old green circle and red cross (bright pure colours only;
        # the room's lime chair and dark red walls are not touched)
        b, g, r = [strip[..., i].astype(int) for i in range(3)]
        mask = (((g > 170) & (g - r > 60) & (g - b > 60)) | ((r > 190) & (r - g > 90) & (r - b > 90)))
        if mask.any():
            mask = cv2.dilate(mask.astype(np.uint8) * 255, np.ones((5, 5), np.uint8))
            strip[:] = cv2.inpaint(strip, mask, 3, cv2.INPAINT_TELEA)
        z = Z[k]
        azZ, elZ = profile_peaks(z['pAz'], z['pEl'], zs.az_deg, zs.el_deg)
        src = None
        if O is not None and z['wsum'] > 0 and O[k]['wsum'] > 0:
            azO, _ = profile_peaks(O[k]['pAz'], O[k]['pEl'], zs.az_deg, zs.el_deg)
            f = tri.fuse(z['pAz'], O[k]['pAz'], azZ, azO)
            if f.trusted:
                src = np.r_[f.pos, f.rA * np.tan(np.radians(elZ))]
        if src is None and z['wsum'] > 0:                   # direction only: 2 m out, as the tracker does
            a, e = np.radians(azZ - RC.YAW_ZYLIA_DEG), np.radians(elZ)
            src = np.r_[posA, 0.0] + RC.FALLBACK_DISTANCE_M * np.array(
                [np.cos(e) * np.cos(a), np.cos(e) * np.sin(a), np.sin(e)])
        if src is not None:
            last_src = src
        vals = camera_values(z['map2d'], zs.az_deg, zs.el_deg, posA, RC.YAW_ZYLIA_DEG, last_src, cam,
                             gw, gh, yaw + 180.0, deg_px, el_top, RC.CAMERA_MIRROR)
        paint(strip, vals, z['w2'] / max(RC.MIN_EVIDENCE, 1e-3))
        wr.write(fr)
        if k % 300 == 0:
            print(f'  frame {k}/{n}  ({time.time() - t0:.0f} s)', flush=True)
    wr.release()

    print('Adding the original sound...', end=' ', flush=True)
    import AVFoundation as AVF
    import CoreMedia as CM
    from Foundation import NSURL
    va = AVF.AVURLAsset.URLAssetWithURL_options_(NSURL.fileURLWithPath_(os.path.abspath(tmp)), None)
    oa = AVF.AVURLAsset.URLAssetWithURL_options_(NSURL.fileURLWithPath_(os.path.abspath(video)), None)
    comp = AVF.AVMutableComposition.composition()
    dur = CM.CMTimeMinimum(va.duration(), oa.duration())
    rng = CM.CMTimeRangeMake(CM.kCMTimeZero, dur)
    d = CM.CMTimeMakeWithSeconds(abs(shift), 600)
    tv = comp.addMutableTrackWithMediaType_preferredTrackID_(AVF.AVMediaTypeVideo, 0)
    tv.insertTimeRange_ofTrack_atTime_error_(rng, va.tracksWithMediaType_(AVF.AVMediaTypeVideo)[0],
                                             CM.kCMTimeZero, None)
    aud = oa.tracksWithMediaType_(AVF.AVMediaTypeAudio)
    if aud:          # the sound moved `shift` earlier (later if negative), to line up with the picture
        ta = comp.addMutableTrackWithMediaType_preferredTrackID_(AVF.AVMediaTypeAudio, 0)
        if shift >= 0:
            ta.insertTimeRange_ofTrack_atTime_error_(
                CM.CMTimeRangeMake(d, CM.CMTimeSubtract(oa.duration(), d)), aud[0], CM.kCMTimeZero, None)
        else:
            ta.insertTimeRange_ofTrack_atTime_error_(
                CM.CMTimeRangeMake(CM.kCMTimeZero, CM.CMTimeSubtract(dur, d)), aud[0], d, None)
    if os.path.exists(out_path):
        os.remove(out_path)
    ex = AVF.AVAssetExportSession.alloc().initWithAsset_presetName_(comp, AVF.AVAssetExportPresetHighestQuality)
    ex.setOutputURL_(NSURL.fileURLWithPath_(os.path.abspath(out_path)))
    ex.setOutputFileType_(AVF.AVFileTypeMPEG4)
    ex.exportAsynchronouslyWithCompletionHandler_(lambda: None)
    while ex.status() in (0, 1, 2):
        time.sleep(0.2)
    if ex.status() != 3:
        sys.exit(f'Export failed: {ex.error()}  (the silent version is kept: {tmp})')
    os.remove(tmp)
    print(f'done.\nSaved {out_path}')


if __name__ == '__main__':
    main()
