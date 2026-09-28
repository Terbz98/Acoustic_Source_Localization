"""
live_tracker.py -- LIVE sound localisation with the Zylia ZM-1 + Zoom H3-VR,
steering a virtual camera cut out of the Insta360 X4's 360 video.

    per mic   : SRP power maps, frame by frame        (doa_core.py  = run_doa.m / az_power_map.m)
    distance  : the two maps fused over the room      (fusion.py    = triangulate.m)
    camera    : perspective view reframed at (az, el) (camera_view.py)

Edit rig_config.py for your setup first. Then, from INSTA360/:

    .venv/bin/python live_tracker.py --list-devices     # are both mics there?
    .venv/bin/python live_tracker.py --no-camera        # audio only: radar view
    .venv/bin/python live_tracker.py                    # audio + X4 (Webcam mode)
    .venv/bin/python live_tracker.py --record           # ALSO record every mic + a window video to recordings/
    .venv/bin/python live_tracker.py --calibrate 1.5 0  # measure the mic yaws (see README)
    .venv/bin/python live_tracker.py --replay ../2micdirectfrontzylia1.wav ../2micdirectfrontzoom1.WAV

Keys in the window:  Q quit   R start/stop recording   C clear maps
                     - = zoom out/in   B look out of the other side   U upside-down
"""

from __future__ import annotations

import use_project_python  # noqa: F401  (restarts on .venv/bin/python if needed)

import argparse
import collections
import csv
import datetime
import json
import os
import queue
import socket
import sys
import threading
import time

import numpy as np

import rig_config as RC
from doa_core import (ArrayConfig, Framer, LiveGate, MapAccumulator, SrpArray,
                      ambi_to_acn_n3d, frame_weights_and_norm, profile_peaks,
                      wrap180, zoom_config, zylia_config)
from fusion import Triangulator, rig_layout

HERE = os.path.dirname(os.path.abspath(__file__))


# ======================= audio sources ===================================
def find_device(sub, min_ch):
    import sounddevice as sd
    devs = sd.query_devices()
    for i, d in enumerate(devs):
        if sub.lower() in d['name'].lower() and d['max_input_channels'] > 0:
            if d['max_input_channels'] < min_ch:
                raise SystemExit(
                    f'"{d["name"]}" offers only {d["max_input_channels"]} input channels, '
                    f'need {min_ch}.\n' + {
                        'zylia': '  Zylia: is the ZM-1 driver extension approved? (System Settings > '
                                 'General > Login Items & Extensions > Driver Extensions)',
                        'h3-vr': '  H3-VR: Menu > USB > Audio I/F > "4ch Ambisonics" (not Stereo).',
                    }.get(sub.lower(), ''))
            return i, d['name']
    names = '\n'.join(f'   {i}: {d["name"]} ({d["max_input_channels"]} in)'
                      for i, d in enumerate(devs) if d['max_input_channels'] > 0)
    raise SystemExit(f'No input device matching "{sub}". Inputs I can see:\n{names}')


class LiveInput:
    """One CoreAudio device. The callback only copies; all maths happens in
    the processing thread, so the audio thread never stalls."""

    def __init__(self, sub, n_ch, fs):
        import sounddevice as sd
        self.index, self.name = find_device(sub, n_ch)
        self.fs = fs
        self.n_ch = n_ch
        self.q = queue.Queue()
        self.overflows = 0
        self.t0_wall = None         # wall-clock time of the stream's first sample
        self.delivered = 0          # samples handed out by get() so far
        self.chunk_t0 = None        # wall-clock time of the first sample of the last get()
        self.stream = sd.InputStream(device=self.index, channels=n_ch, samplerate=fs,
                                     dtype='float32', latency='low', callback=self._cb)

    def _cb(self, indata, frames, t, status):
        if self.t0_wall is None:
            self.t0_wall = time.time() - frames / self.fs
        if status and status.input_overflow:
            self.overflows += 1
        self.q.put(indata.copy())

    def start(self):
        self.stream.start()

    def stop(self):
        self.stream.stop()
        self.stream.close()

    def get(self):
        out = []
        try:
            while True:
                out.append(self.q.get_nowait())
        except queue.Empty:
            pass
        if not out:
            return None
        x = np.concatenate(out)
        self.chunk_t0 = (self.t0_wall or time.time()) + self.delivered / self.fs
        self.delivered += len(x)
        return x

    exhausted = False


class FileInput:
    """A recording played back through the exact live path. Pull-based, so
    both files advance by the same amount of AUDIO time per step."""

    def __init__(self, path, start_s=0.0):
        import soundfile as sf
        self.f = sf.SoundFile(path)
        self.name = os.path.basename(path)
        self.fs = self.f.samplerate
        self.n_ch = self.f.channels
        self.f.seek(max(0, int(round(start_s * self.fs))))
        self.exhausted = False
        self.overflows = 0

    def start(self):
        pass

    def stop(self):
        self.f.close()

    def read_seconds(self, sec):
        x = self.f.read(int(round(sec * self.fs)), dtype='float32', always_2d=True)
        if x.shape[0] == 0:
            self.exhausted = True
            return None
        return x


# ======================= one array, live =================================
class ArrayTracker:
    def __init__(self, cfg: ArrayConfig, tau_s):
        self.cfg = cfg
        self.srp = SrpArray(cfg)
        self.frame_rate = cfg.fs / cfg.hop
        self.framer = Framer(cfg.frame_len, cfg.hop, len(cfg.channels))
        self.gate = LiveGate(self.frame_rate, RC.ENERGY_GATE_DB, RC.SNR_GATE_DB, history_s=20.0)
        self.acc = MapAccumulator(self.srp.az_deg.size, self.srp.el_deg.size,
                                  self.frame_rate, tau_s)
        self.level_db = -120.0
        self.n_clip = 0
        self.n_active = 0
        self.recent = collections.deque(maxlen=int(4 * self.frame_rate))   # (t, pAz, pEl, w)

    @property
    def t_now(self):
        return self.acc.frame / self.frame_rate

    def profiles_between(self, t0, t1):
        """Weighted az/el profiles of this mic's active frames in [t0, t1]."""
        A = np.zeros(self.srp.az_deg.size)
        E = np.zeros(self.srp.el_deg.size)
        wsum, n = 0.0, 0
        for t, pa, pe, w in list(self.recent):
            if t0 <= t <= t1:
                A += w * pa
                E += w * pe
                wsum += w
                n += 1
        if wsum <= 0:
            return None
        return A / A.max(), E / max(E.max(), 1e-30), wsum, n

    def feed(self, x):
        cfg = self.cfg
        frames = self.framer.push(x[:, list(cfg.channels)])
        T = frames.shape[0]
        if T == 0:
            return
        clip = np.abs(frames).max(axis=(1, 2)) > cfg.clip_level
        if cfg.kind == 'sh':
            frames = ambi_to_acn_n3d(frames.reshape(-1, frames.shape[2]), cfg.in_format,
                                     cfg.order).reshape(T, cfg.frame_len, -1).astype(np.float32)
        F, E = self.srp.spectra(frames)
        active, _ = self.gate(E)
        active &= ~clip
        self.n_clip += int(clip.sum())
        self.level_db = 20 * np.log10(np.sqrt(np.mean(frames[-1] ** 2)) + 1e-12)
        idx = np.flatnonzero(active)
        f0 = self.acc.frame
        if idx.size:
            pAz, pEl, w = frame_weights_and_norm(self.srp.maps(F[idx]))
            self.acc.step(T, pAz, pEl, w)
            self.n_active += idx.size
            # remembered briefly so each separate sound can be analysed on its own
            t = (f0 + idx + 0.5) / self.frame_rate
            self.recent.extend(zip(t, pAz, pEl, w))
        else:
            self.acc.step(T)

    def snapshot(self, hold_s, min_evidence=0.0):
        pAz, pEl = self.acc.profiles()
        fresh = (self.acc.frame - self.acc.last_active_frame) < hold_s * self.frame_rate
        az, el = profile_peaks(pAz, pEl, self.srp.az_deg, self.srp.el_deg) if self.acc.wsum > 0 \
            else (np.nan, np.nan)
        # "fresh" = recent sound AND enough of it. A lone click or a clap's
        # reverberant tail leaves evidence ~1-2; a talker builds 5-50. Without
        # this, every door click would yank the camera round for a second.
        fresh = fresh and self.acc.wsum > max(min_evidence, 0.0) and self.acc.wsum > 0
        return dict(az=az, el=el, pAz=pAz, pEl=pEl, fresh=bool(fresh),
                    evidence=float(self.acc.wsum),
                    level_db=float(self.level_db), snr_db=float(self.gate.snr_db),
                    n_active=self.n_active, n_clip=self.n_clip)

    def clear(self):
        self.acc.A[:] = 0
        self.acc.E[:] = 0
        self.acc.wsum = 0


# ======================= the tracker =====================================
def dir_vec(az_deg, el_deg):
    a, e = np.radians(az_deg), np.radians(el_deg)
    return np.array([np.cos(e) * np.cos(a), np.cos(e) * np.sin(a), np.sin(e)])


class Tracker:
    def __init__(self, zsrc, osrc, args):
        self.args = args
        self.zsrc, self.osrc = zsrc, osrc
        self.fs_z = zsrc.fs
        tau = np.inf if args.calibrate else args.tau

        # Zylia: raw capsules live; a converted 16-ch file in replay is fine too
        if zsrc.n_ch >= 19:
            zc = zylia_config(fs=zsrc.fs)
        elif zsrc.n_ch == 16:
            zc = zylia_config(fs=zsrc.fs, kind='sh', order=3, channels=tuple(range(16)),
                              in_format='ambix', f_band=(1000, 12000))
        else:
            raise SystemExit(f'Zylia source has {zsrc.n_ch} channels; need 19 raw or 16 ACN.')
        self.zyl = ArrayTracker(zc, tau)
        self.zoom = ArrayTracker(zoom_config(fs=osrc.fs, in_format=args.zoom_format), tau) \
            if osrc is not None else None

        self.posA, self.posB = rig_layout(RC.LAYOUT, RC.BASELINE_M)
        self.tri = Triangulator(self.posA, self.posB, self.zyl.srp.az_deg,
                                yawA=RC.YAW_ZYLIA_DEG, yawB=RC.YAW_ZOOM_DEG) \
            if self.zoom is not None else None
        self.cam_pos = np.asarray(RC.CAMERA_POS_M, float)
        self.state = None
        self.recorder = None
        self.x4src = None           # the X4's own stereo mic: recorded for the video, not analysed
        self.stop_evt = threading.Event()
        self.publish_every = max(1, int(self.zyl.frame_rate / args.update_hz))
        self._next_pub = self.publish_every
        self._last_print = 0.0
        self.history = []
        self.sounds = None          # set in main()
        self.udp = None
        if args.udp:
            host, port = args.udp.rsplit(':', 1)
            self.udp = (socket.socket(socket.AF_INET, socket.SOCK_DGRAM), (host, int(port)))

    # -------------------------------------------------------------------
    def run(self):
        """Processing loop (its own thread)."""
        srcs = [(self.zsrc, self.zyl, 'zylia')]
        if self.zoom is not None:
            srcs.append((self.osrc, self.zoom, 'zoom'))
        replay = isinstance(self.zsrc, FileInput)
        step_s = 0.02
        t_audio, t_wall0 = 0.0, time.time()
        while not self.stop_evt.is_set():
            got = False
            for src, trk, tag in srcs:
                x = src.read_seconds(step_s) if replay else src.get()
                if x is None or not len(x):
                    continue
                got = True
                if self.recorder is not None:
                    self.recorder.write(tag, x, getattr(src, 'chunk_t0', None))
                trk.feed(x)
            if self.x4src is not None:
                x = self.x4src.get()
                if x is not None and self.recorder is not None:
                    self.recorder.write('x4', x, self.x4src.chunk_t0)
            if self.zyl.acc.frame >= self._next_pub:
                self._next_pub = self.zyl.acc.frame + self.publish_every
                self.publish()
            if replay:
                if all(s.exhausted for s, _, _ in srcs):
                    self.publish(final=True)
                    self.stop_evt.set()
                    break
                t_audio += step_s
                if not self.args.fast:
                    lag = t_audio - (time.time() - t_wall0)
                    if lag > 0:
                        time.sleep(lag)
            elif not got:
                time.sleep(0.003)

    # -------------------------------------------------------------------
    def locate(self, azZ, elZ, fr):
        """Zylia bearing (+ fusion result, if any) -> source position in the
        rig frame, how it was obtained, and az / el / r from the midpoint."""
        if fr is not None and fr.trusted:
            src = np.r_[fr.pos, fr.rA * np.tan(np.radians(elZ))]
            mode = 'triangulated'
        else:
            azr = azZ - RC.YAW_ZYLIA_DEG
            src = np.r_[self.posA, 0.0] + RC.FALLBACK_DISTANCE_M * dir_vec(azr, elZ)
            mode = 'direction only' if fr is None else 'direction only (' + fr.warning + ')'
        rH = np.hypot(src[0], src[1])
        v = src - self.cam_pos
        return dict(src=src, mode=mode,
                    az=float(np.degrees(np.arctan2(src[1], src[0]))),
                    el=float(np.degrees(np.arctan2(src[2], rH))),
                    r=float(np.linalg.norm(src)) if mode == 'triangulated' else None,
                    cam_az=float(np.degrees(np.arctan2(v[1], v[0]))),
                    cam_el=float(np.degrees(np.arctan2(v[2], np.hypot(v[0], v[1])))))

    def publish(self, final=False):
        zs = self.zyl.snapshot(RC.HOLD_S, RC.MIN_EVIDENCE)
        os_ = self.zoom.snapshot(RC.HOLD_S) if self.zoom is not None else None
        ev = self.sounds.update() if self.sounds is not None else None
        prev = self.state or {}
        st = dict(t=self.zyl.t_now, zylia=zs, zoom=os_, fusion=prev.get('fusion'),
                  src=prev.get('src'), mode=prev.get('mode', 'waiting'),
                  cam_az=prev.get('cam_az'), cam_el=prev.get('cam_el'),
                  az=prev.get('az'), el=prev.get('el'), r=prev.get('r'), fresh=False,
                  overflows=self.zsrc.overflows + (self.osrc.overflows if self.osrc else 0),
                  recording=self.recorder.path_hint if self.recorder else None,
                  sounds=self.sounds.events[-8:] if self.sounds is not None else [])
        if zs['fresh']:
            # a sustained source (talking): the running estimate
            fr = None
            if os_ is not None and os_['fresh']:
                fr = self.tri.fuse(zs['pAz'], os_['pAz'], zs['az'], os_['az'])
            st.update(self.locate(zs['az'], zs['el'], fr), fresh=True, fusion=fr)
        elif ev is not None:
            # a short sound that just ended (a clap): too brief to build up the
            # running estimate, so aim at it directly
            st.update({k: ev[k] for k in ('src', 'mode', 'az', 'el', 'r', 'cam_az', 'cam_el')},
                      fresh=True, fusion=ev['fusion'])
        self.state = st
        if st['fresh']:
            self.history.append((st['t'], st['az'], st['el'], st['r'], st['mode']))
        self._report(st, final)

    def _report(self, st, final):
        if self.udp and st['fresh']:
            msg = {k: st[k] for k in ('t', 'az', 'el', 'r', 'cam_az', 'cam_el', 'mode')}
            try:
                self.udp[0].sendto(json.dumps(msg).encode(), self.udp[1])
            except OSError:
                pass
        if not self.args.verbose:
            return                         # the per-sound lines are printed by SoundEvents
        now = time.time()
        if not final and now - self._last_print < self.args.print_every:
            return
        self._last_print = now
        zs, os_ = st['zylia'], st['zoom']
        if st['fresh']:
            r = f"r {st['r']:.2f} m" if st['r'] is not None else 'r   --  '
            line = (f"[{st['t']:7.1f}s] az {st['az']:+7.1f}  el {st['el']:+5.1f}  {r}  "
                    f"| Zylia {zs['az']:+7.1f}/{zs['el']:+5.1f}")
            if os_ is not None:
                line += f"  Zoom {os_['az']:+7.1f}" if os_['fresh'] else '  Zoom  (quiet)'
            line += f"  | cam {st['cam_az']:+6.1f}/{st['cam_el']:+5.1f}  {st['mode']}"
        else:
            line = (f"[{st['t']:7.1f}s] listening...  Zylia {zs['level_db']:5.0f} dBFS"
                    + (f"  Zoom {os_['level_db']:5.0f} dBFS" if os_ is not None else ''))
        if st['overflows']:
            line += f"  !! {st['overflows']} audio overflows"
        print(line, flush=True)


# ======================= one line per sound ==============================
class SoundEvents:
    """Splits what the Zylia hears into separate SOUNDS -- a clap, a word, a
    knock -- and localises each one on its own. Every sound gets one line in
    the Terminal, a row in the window's list, and a row in a CSV file you can
    open in Excel afterwards.

    A sound starts at the first frame that passes the gates and ends after
    GAP_S of nothing. Continuous talking is cut every MAX_S so it still gives
    a steady stream of lines. Very short blips (fewer than MIN_FRAMES frames,
    or almost no directional evidence) are ignored."""

    GAP_S = 0.25
    MAX_S = 1.5
    MIN_FRAMES = 3
    MIN_EVIDENCE = 0.5

    def __init__(self, tracker, csv_path=None):
        self.tr = tracker
        self.events = []
        self.t_open = None
        self.t_last = None
        self.closed_until = -1.0
        self.csv_path = csv_path
        self._f = self._w = None
        if csv_path:
            os.makedirs(os.path.dirname(csv_path), exist_ok=True)
            self._f = open(csv_path, 'w', newline='')
            self._w = csv.writer(self._f)
            self._w.writerow(['sound', 'clock', 'time_s', 'duration_s', 'azimuth_deg',
                              'elevation_deg', 'distance_m', 'how', 'zylia_az_deg',
                              'zylia_el_deg', 'zoom_az_deg', 'frames', 'evidence'])
            self._f.flush()

    def update(self):
        """Call regularly. Returns the sound that just ended, if one did."""
        zyl = self.tr.zyl
        rec = zyl.recent
        if not rec:
            return None
        t_active = rec[-1][0]
        if self.t_open is None and t_active > self.closed_until:
            self.t_open = next(t for t, *_ in rec if t > self.closed_until)
        if self.t_open is None:
            return None
        if t_active > self.closed_until:
            self.t_last = max(self.t_last or t_active, t_active)
        now = zyl.t_now
        if now - self.t_last > self.GAP_S or self.t_last - self.t_open > self.MAX_S:
            t0, t1 = self.t_open, min(self.t_last, self.t_open + self.MAX_S)
            self.t_open, self.t_last, self.closed_until = None, None, t1
            return self._finish(t0, t1)
        return None

    def _finish(self, t0, t1):
        tr = self.tr
        z = tr.zyl.profiles_between(t0, t1)
        if z is None or z[3] < self.MIN_FRAMES or z[2] < self.MIN_EVIDENCE:
            return None
        azZ, elZ = profile_peaks(z[0], z[1], tr.zyl.srp.az_deg, tr.zyl.srp.el_deg)
        fr, azO = None, None
        if tr.zoom is not None:
            o = tr.zoom.profiles_between(t0 - 0.1, t1 + 0.1)     # the two clocks differ by ms
            if o is not None:
                azO, _ = profile_peaks(o[0], o[1], tr.zoom.srp.az_deg, tr.zoom.srp.el_deg)
                fr = tr.tri.fuse(z[0], o[0], azZ, azO)
        loc = tr.locate(azZ, elZ, fr)
        ev = dict(loc, n=len(self.events) + 1, t=t0, dur=t1 - t0,
                  clock=datetime.datetime.now().strftime('%H:%M:%S'),
                  zylia_az=azZ, zylia_el=elZ, zoom_az=azO, frames=z[3],
                  evidence=z[2], fusion=fr)
        self.events.append(ev)
        self._print(ev)
        if self._w is not None:
            self._w.writerow([ev['n'], ev['clock'], f"{t0:.2f}", f"{ev['dur']:.2f}",
                              f"{ev['az']:.1f}", f"{ev['el']:.1f}",
                              '' if ev['r'] is None else f"{ev['r']:.2f}",
                              ev['mode'], f"{azZ:.1f}", f"{elZ:.1f}",
                              '' if azO is None else f"{azO:.1f}", z[3], f"{z[2]:.1f}"])
            self._f.flush()
        return ev

    @staticmethod
    def line(ev):
        r = f"{ev['r']:.2f} m" if ev['r'] is not None else '  --  '
        return (f"#{ev['n']:<3d} az {ev['az']:+6.1f}   el {ev['el']:+5.1f}   dist {r}")

    def _print(self, ev):
        why = ''
        if ev['r'] is None:
            if ev['fusion'] is None:
                why = '   (no distance: the Zoom heard nothing usable)'
            elif not ev['fusion'].forward:
                why = '   (no distance: the two mics disagree -- sound near the line through both mics?)'
            else:
                why = '   (no distance: too far / too far to the side for this baseline)'
        print(f"[{ev['clock']}] SOUND {self.line(ev)}   ({ev['dur']:.2f} s){why}", flush=True)

    def close(self):
        if self._f is not None:
            self._f.close()
            if self.events:
                print(f'\n{len(self.events)} sounds saved to {self.csv_path}')


# ======================= recording =======================================
class Recorder:
    """Writes the raw streams to WAV while tracking. Zylia: the 19 raw
    capsules (open in ZYLIA Studio / convert with ZYLIA Ambisonics Converter
    to feed main_2mic.m). Zoom: 4-ch AmbiX, like the recorder's own files.
    X4: its own stereo microphone, used as the sound of the window video.
    On close it writes the start time of every file (_sync.json) and, if the
    window was filmed, joins video and sound into one MP4."""

    def __init__(self, folder, zsrc, osrc, zoom_format, x4src=None):
        import soundfile as sf
        os.makedirs(folder, exist_ok=True)
        stamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
        self.folder, self.stamp = folder, stamp
        self.files = {'zylia': sf.SoundFile(os.path.join(folder, f'live_{stamp}_zylia19.wav'), 'w',
                                            int(zsrc.fs), 19, 'PCM_24')}
        if osrc is not None:
            self.files['zoom'] = sf.SoundFile(
                os.path.join(folder, f'live_{stamp}_zoom_{zoom_format}.wav'), 'w',
                int(osrc.fs), 4, 'PCM_24')
        if x4src is not None:
            self.files['x4'] = sf.SoundFile(os.path.join(folder, f'live_{stamp}_x4_stereo.wav'), 'w',
                                            int(x4src.fs), 2, 'PCM_24')
        self.path_hint = os.path.join(folder, f'live_{stamp}_*')
        self.t_start = {}           # wall-clock time of each file's first sample
        self.zsrc = zsrc
        self.video = None           # (path, start time) of the window video, set by the GUI
        self._lock = threading.Lock()

    def write(self, tag, x, t0=None):
        with self._lock:
            f = self.files.get(tag)
            if f is not None and not f.closed:
                if tag not in self.t_start:
                    self.t_start[tag] = t0 if t0 is not None else time.time() - len(x) / f.samplerate
                f.write(x[:, :f.channels])

    def close(self):
        with self._lock:
            for f in self.files.values():
                f.close()
        print(f'Saved {self.path_hint}')
        # timing of every file, so sounds (time_s in the CSV = Zylia stream
        # time) can be found in the audio files and in the video later
        sync = dict(files={k: os.path.basename(f.name) for k, f in self.files.items()},
                    start_wall_s=self.t_start,
                    zylia_stream_start_wall_s=getattr(self.zsrc, 't0_wall', None),
                    video=None if self.video is None else os.path.basename(self.video[0]),
                    video_start_wall_s=None if self.video is None else self.video[1])
        with open(os.path.join(self.folder, f'live_{self.stamp}_sync.json'), 'w') as fh:
            json.dump(sync, fh, indent=2)
        if self.video is not None:
            try:
                add_sound_to_video(self)
            except Exception as e:
                print(f'Could not add the sound to the video ({e}); the silent video '
                      f'and the WAV files are still saved.')


class WindowVideo:
    """Screen recording of the tracker window (what you see), saved next to
    the audio while recording. Written at FPS by a background thread so the
    window never waits for the video encoder."""

    FPS = 15

    def __init__(self, path, size):
        import cv2
        self.path, self.size = path, size
        self.w = cv2.VideoWriter(path, cv2.VideoWriter_fourcc(*'mp4v'), self.FPS, size)
        self.q = queue.Queue(maxsize=4)
        self.t0 = self.t_next = time.time()
        self.owed = 0
        self.th = threading.Thread(target=self._run, daemon=True)
        self.th.start()

    def offer(self, canvas):
        now = time.time()
        if now < self.t_next:
            return
        # repeat the frame if the window fell behind, so the video keeps real time
        n = 1 + int((now - self.t_next) * self.FPS)
        self.t_next += n / self.FPS
        self.owed += n
        self.last = canvas
        try:
            self.q.put_nowait((canvas, self.owed))
            self.owed = 0
        except queue.Full:
            pass

    def _run(self):
        import cv2
        while True:
            item = self.q.get()
            if item is None:
                break
            img, n = item
            img = cv2.resize(img, self.size, interpolation=cv2.INTER_AREA)
            for _ in range(n):
                self.w.write(img)
        self.w.release()

    def close(self):
        if self.owed:                   # frames still owed when the queue was full
            self.q.put((self.last, self.owed))
        self.q.put(None)
        self.th.join(timeout=30)
        print(f'Saved {self.path}')


def add_sound_to_video(rec):
    """Silent window video + recorded audio -> one MP4 with sound (H.264 +
    AAC, plays in QuickTime, Keynote, PowerPoint). Uses macOS's own
    AVFoundation, so no ffmpeg is needed. Sound: the X4's own stereo mic
    (recorded from the camera's spot, like any video), else the Zoom as
    stereo (left / right virtual mics), else the Zylia's capsules summed."""
    import soundfile as sf
    import AVFoundation as AVF
    import CoreMedia as CM
    from Foundation import NSURL
    vpath, vt0 = rec.video
    tag = next((t for t in ('x4', 'zoom', 'zylia') if t in rec.t_start), None)
    if tag is None:
        raise RuntimeError('no audio was recorded')
    x, fs = sf.read(rec.files[tag].name, dtype='float32', always_2d=True)
    if tag == 'x4':
        mix = x[:, :2].copy()
    elif tag == 'zoom':                     # AmbiX W, Y -> left / right cardioids
        mix = 0.5 * np.stack([x[:, 0] + x[:, 1], x[:, 0] - x[:, 1]], 1)
    else:
        m = x[:, :19].mean(1)
        mix = np.stack([m, m], 1)
    lag = int(round((rec.t_start[tag] - vt0) * fs))   # audio start relative to video start
    mix = mix[-lag:] if lag < 0 else np.vstack([np.zeros((lag, 2), np.float32), mix])
    peak = float(np.max(np.abs(mix))) if len(mix) else 0.0
    if peak > 0:
        mix *= min(10 ** (-1 / 20) / peak, 100.0)     # loud enough to hear, never clipped
    tmp_wav = vpath[:-4] + '_sound.wav'
    sf.write(tmp_wav, mix, fs, 'PCM_16')
    out = vpath.replace('_silent.mp4', '.mp4')
    if os.path.exists(out):
        os.remove(out)
    print(f'Adding the sound ({tag} mic) to the video...', end=' ', flush=True)
    va = AVF.AVURLAsset.URLAssetWithURL_options_(NSURL.fileURLWithPath_(vpath), None)
    aa = AVF.AVURLAsset.URLAssetWithURL_options_(NSURL.fileURLWithPath_(tmp_wav), None)
    comp = AVF.AVMutableComposition.composition()
    dur = va.duration()
    rng = CM.CMTimeRangeMake(CM.kCMTimeZero, dur)
    for asset, kind in ((va, AVF.AVMediaTypeVideo), (aa, AVF.AVMediaTypeAudio)):
        src = asset.tracksWithMediaType_(kind)
        if not src:
            raise RuntimeError(f'no {kind} track')
        tr = comp.addMutableTrackWithMediaType_preferredTrackID_(kind, 0)
        r = rng if kind == AVF.AVMediaTypeVideo else CM.CMTimeRangeMake(
            CM.kCMTimeZero, CM.CMTimeMinimum(dur, asset.duration()))
        ok, err = tr.insertTimeRange_ofTrack_atTime_error_(r, src[0], CM.kCMTimeZero, None)
        if not ok:
            raise RuntimeError(str(err))
    ex = AVF.AVAssetExportSession.alloc().initWithAsset_presetName_(
        comp, AVF.AVAssetExportPresetHighestQuality)
    ex.setOutputURL_(NSURL.fileURLWithPath_(out))
    ex.setOutputFileType_(AVF.AVFileTypeMPEG4)
    ex.exportAsynchronouslyWithCompletionHandler_(lambda: None)
    while ex.status() in (0, 1, 2):       # unknown, waiting, exporting
        time.sleep(0.2)
    if ex.status() != 3:                  # completed
        raise RuntimeError(str(ex.error()))
    os.remove(tmp_wav)
    os.remove(vpath)
    print(f'done.\nSaved {out}')


def save_sound_pictures(folder, ev, frame, view, canvas):
    """One set of pictures per detected sound, for checking results and for
    slides: the whole 360 frame from the X4 at that moment, the camera view
    pointed exactly at the sound, and the whole tracker window."""
    import cv2
    os.makedirs(folder, exist_ok=True)
    r = 'nodist' if ev['r'] is None else f"{ev['r']:.2f}m"
    base = os.path.join(folder, f"sound_{ev['n']:03d}_az{ev['az']:+.0f}_el{ev['el']:+.0f}_{r}")
    if frame is not None:
        cv2.imwrite(base + '_360.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 92])
    if view is not None:
        cv2.imwrite(base + '_view.jpg', view, [cv2.IMWRITE_JPEG_QUALITY, 92])
    if canvas is not None:
        cv2.imwrite(base + '_window.jpg', canvas, [cv2.IMWRITE_JPEG_QUALITY, 88])


# ======================= calibration =====================================
def calibrate(tracker, x, y, z, duration):
    """Source held still at a KNOWN rig position (x, y, z) for `duration` s.
    Accumulate everything (tau = inf) and report each mic's yaw = measured
    bearing - expected bearing. That is YAW_ZYLIA_DEG / YAW_ZOOM_DEG.

    The README of the MATLAB project warns about this, rightly: a yaw FITTED
    to a known position makes THAT position come out right by construction.
    It is still the correct way to set the rig up -- just check the result on
    a DIFFERENT tape-measured position before believing a distance."""
    print(f'CALIBRATION: keep the sound at x={x} m (forward), y={y} m (left), '
          f'z={z} m (up) for {duration:.0f} s. Talk or clap steadily...')
    th = threading.Thread(target=tracker.run, daemon=True)
    th.start()
    t0 = time.time()
    while time.time() - t0 < duration and th.is_alive():
        time.sleep(0.5)
    tracker.stop_evt.set()
    th.join(timeout=2)
    zs = tracker.zyl.snapshot(1e9)
    src = np.array([x, y, z], float)
    rows = [('Zylia', zs, tracker.posA, 'YAW_ZYLIA_DEG')]
    if tracker.zoom is not None:
        rows.append(('Zoom', tracker.zoom.snapshot(1e9), tracker.posB, 'YAW_ZOOM_DEG'))
    print('\n  mic      measured  expected    yaw   frames')
    out = {}
    for name, s, p, key in rows:
        v = src - np.r_[p, 0]
        exp_az = float(np.degrees(np.arctan2(v[1], v[0])))
        yaw = float(wrap180(s['az'] - exp_az))
        out[key] = yaw
        exp_el = float(np.degrees(np.arctan2(v[2], np.hypot(v[0], v[1]))))
        print(f"  {name:6s} {s['az']:+9.2f} {exp_az:+9.2f} {yaw:+7.2f}   {s['n_active']:6d}"
              f"   (el {s['el']:+.1f}, expected {exp_el:+.1f})")
    if min(s['n_active'] for _, s, _, _ in rows) < 100:
        print('\n  !! Few frames passed the gates -- make more (steady) sound and redo it.')
    print('\nPut these in rig_config.py:')
    for k, v in out.items():
        print(f'  {k} = {v:.2f}')
    if len(out) == 2:
        print(f'\n  relative yaw (Zoom - Zylia) = {out["YAW_ZOOM_DEG"] - out["YAW_ZYLIA_DEG"]:+.2f} deg '
              '-- this is the number distance depends on.\n'
              '  (2026-08 sessions: +4.0 to +5.4. Much bigger means a mic is turned.)')


# ======================= GUI =============================================
# ---- drawing helpers: plain bright text on dark panels, never on the video ----
# Everything is drawn at K times the window size in points and shown in a
# window of the normal size, so on a Retina screen (K = 2) every drawn pixel
# lands on exactly one screen pixel. Drawing at 1x and letting macOS double it
# is what made the text blurry.
FONT = 2          # cv2.FONT_HERSHEY_DUPLEX (a cleaner stroke than SIMPLEX)
WHITE, GREY, DIM = (240, 240, 240), (185, 185, 185), (130, 130, 130)
GREEN, ORANGE, CYAN, RED = (100, 235, 100), (0, 170, 255), (255, 210, 60), (90, 90, 255)
K = 1


def screen_scale():
    """2 on a Retina screen, 1 otherwise (largest of the connected screens)."""
    try:
        from AppKit import NSScreen
        return max(1, int(round(max(sc.backingScaleFactor() for sc in NSScreen.screens()))))
    except Exception:
        return 1


def text(img, s, org, col=WHITE, scale=0.5):
    """org and scale in window points; drawn at K x."""
    import cv2
    cv2.putText(img, s, (int(org[0] * K), int(org[1] * K)), FONT, scale * K, col, K, cv2.LINE_AA)


def short_mode(mode, fusion):
    if mode == 'triangulated':
        return 'distance from both mics (triangulated)'
    if mode.startswith('direction only'):
        if fusion is None:
            return 'direction only -- the Zoom heard nothing usable'
        if not fusion.forward:
            return 'direction only -- the two mics disagree'
        return 'direction only -- too far / too far to the side'
    return mode


def draw_radar(st, tracker, size=495, span_m=3.0, cam_yaw=0.0):
    """Top view. size in points; the image is size*K pixels."""
    import cv2
    n = size * K
    img = np.full((n, n, 3), 22, np.uint8)
    s = size / (2 * span_m)                          # points per metre
    cx, cy = size / 2, size / 2
    lw = K                                           # 1-point lines

    def P(x, y):                                     # metres -> pixel (K x)
        return int(round((cx - y * s) * K)), int(round((cy - x * s) * K))

    fr = st['fusion'] if st else None
    if fr is not None:
        tri = tracker.tri
        ix = (tri.xg >= -span_m) & (tri.xg <= span_m)
        iy = (tri.yg >= -span_m) & (tri.yg <= span_m)
        S = fr.S[np.ix_(ix, iy)][::-1, ::-1]           # rows: +x at top, cols: +y at left
        S = S / S.max() if S.max() > 0 else S
        heat = cv2.applyColorMap((S * 255).astype(np.uint8), cv2.COLORMAP_INFERNO)
        heat = cv2.resize(heat, (n, n), interpolation=cv2.INTER_LINEAR)
        a = cv2.resize(S.astype(np.float32), (n, n))[..., None] * 0.7
        img = (img * (1 - a) + heat * a).astype(np.uint8)

    c0 = (int(cx * K), int(cy * K))
    cv2.line(img, (c0[0], 0), (c0[0], n), (55, 55, 55), lw)
    cv2.line(img, (0, c0[1]), (n, c0[1]), (55, 55, 55), lw)
    for r in (1, 2, 3):
        cv2.circle(img, c0, int(r * s * K), (75, 75, 75), lw, cv2.LINE_AA)
        text(img, f'{r} m', (cx + 5, cy + r * s - 5), DIM, 0.4)      # below centre, clear of the front
    text(img, 'FRONT', (cx + 6, 16), GREY, 0.45)
    text(img, 'LEFT', (6, cy - 8), GREY, 0.45)
    text(img, 'RIGHT', (size - 52, cy - 8), GREY, 0.45)
    text(img, 'top view', (6, size - 8), DIM, 0.4)

    mics = [('Zylia', tracker.posA, RC.YAW_ZYLIA_DEG, ORANGE, st['zylia'] if st else None)]
    if tracker.zoom is not None:
        mics.append(('Zoom', tracker.posB, RC.YAW_ZOOM_DEG, CYAN, st['zoom'] if st else None))
    az_grid = tracker.zyl.srp.az_deg
    for name, p, yaw, col, snap in mics:
        if snap is not None and snap['pAz'].max() > 0:
            ang = np.radians(az_grid - yaw)
            rr = 0.12 + 0.45 * snap['pAz']
            pts = np.array([P(p[0] + r * np.cos(a), p[1] + r * np.sin(a)) for a, r in zip(ang, rr)])
            cv2.polylines(img, [pts], True, col, lw, cv2.LINE_AA)
            if snap['fresh']:
                a = np.radians(snap['az'] - yaw)
                cv2.line(img, P(*p), P(p[0] + 4 * np.cos(a), p[1] + 4 * np.sin(a)), col, lw, cv2.LINE_AA)
        cv2.circle(img, P(*p), 7 * K, col, -1, cv2.LINE_AA)
        q = P(*p)
        text(img, name, (q[0] / K - 20, q[1] / K + 24), col, 0.45)    # under the mic dot

    cp = tracker.cam_pos
    c = P(cp[0], cp[1])
    cv2.rectangle(img, (c[0] - 5 * K, c[1] - 5 * K), (c[0] + 5 * K, c[1] + 5 * K), WHITE, lw)
    a = np.radians(cam_yaw)
    cv2.arrowedLine(img, c, P(cp[0] + 0.35 * np.cos(a), cp[1] + 0.35 * np.sin(a)), WHITE, lw, cv2.LINE_AA)

    if st and st.get('sounds'):                       # the last few sounds, numbered
        cur = st['src']
        for e in st['sounds'][-6:]:
            q = P(e['src'][0], e['src'][1])
            cv2.circle(img, q, 4 * K, (0, 200, 255), -1, cv2.LINE_AA)
            near = cur is not None and np.hypot(*(np.asarray(e['src'][:2]) - cur[:2])) < 0.4
            if not near:                              # keep the distance label readable
                text(img, str(e['n']), (q[0] / K + 6, q[1] / K - 6), (0, 200, 255), 0.4)
    if st and st['src'] is not None:
        col = GREEN if st['fresh'] else DIM
        q = P(st['src'][0], st['src'][1])
        cv2.circle(img, q, 10 * K, col, 2 * K, cv2.LINE_AA)
        if st['r'] is not None:
            text(img, f"{st['r']:.2f} m", (q[0] / K + 14, q[1] / K + 16), col, 0.5)
    return img


def draw_info(st, w, h, view_line, cam_status):
    """Every piece of text in the window, in one panel, one line each.
    w, h in points."""
    img = np.full((h * K, w * K, 3), 34, np.uint8)
    y = [26]

    def put(s, col=WHITE, scale=0.47, dy=21):
        text(img, s, (12, y[0]), col, scale)
        y[0] += dy

    if st and st['fresh']:
        r = f"{st['r']:.2f} m" if st['r'] is not None else '--'
        put(f"SOUND   az {st['az']:+.1f}   el {st['el']:+.1f}   dist {r}", GREEN, 0.55, 24)
        put(short_mode(st['mode'], st['fusion']), GREY)
    else:
        put('listening...', GREY, 0.55, 24)
        put('clap or talk near the mics', DIM)
    put(view_line, WHITE)
    if st:
        lvl = f"levels   Zylia {st['zylia']['level_db']:.0f} dB"
        if st['zoom'] is not None:
            lvl += f"   Zoom {st['zoom']['level_db']:.0f} dB"
            if st['zoom']['n_clip']:
                lvl += '  (Zoom clipping: lower its gain)'
        put(lvl, GREY)
    status = f'X4: {cam_status}'
    if st and st['recording']:
        status = 'RECORDING   ' + status
    if st and st['overflows']:
        status += f"   {st['overflows']} audio overflows"
    put(status, RED if (st and st['recording']) else GREY)

    y[0] += 6
    put('LAST SOUNDS', DIM, 0.45)
    evs = (st or {}).get('sounds') or []
    for e in list(reversed(evs))[:4]:
        put(SoundEvents.line(e), GREEN if e is evs[-1] else GREY)

    text(img, 'Q quit    R record    C clear    - / = zoom', (12, h - 30), DIM, 0.42)
    text(img, 'B look out of the other side    U upside-down', (12, h - 10), DIM, 0.42)
    return img


def gui_loop(tracker, cam, reframer, args):
    import cv2
    global K
    from camera_view import panorama_xy
    K = screen_scale()
    win = 'Sound tracker'
    # WINDOW_NORMAL + resizeWindow: the K-times-larger image is shown in a
    # normal-size window, i.e. at the screen's full resolution.
    cv2.namedWindow(win, cv2.WINDOW_NORMAL | cv2.WINDOW_KEEPRATIO)
    # Camera direction and mirroring come from rig_config.py (fixed per rig);
    # B and U are the only live camera controls.
    cam_yaw, mirror = RC.CAMERA_YAW_DEG, RC.CAMERA_MIRROR
    upside = getattr(RC, 'CAMERA_UPSIDE_DOWN', False)
    other_side = False
    Wv, H = RC.VIEW_SIZE
    Hb = 300                                        # bottom row: panorama strip + text panel
    W_all, H_all = Wv + H, H + Hb
    k_fit = min(1.0, args.max_width / W_all)
    cv2.resizeWindow(win, int(W_all * k_fit), int(H_all * k_fit))
    look = dir_vec(0, 0)
    canvas = None
    saved_frame = False
    video = None
    sounds = tracker.sounds
    pic_dir = sounds.csv_path[:-4] if sounds is not None and sounds.csv_path else None
    n_pics = 0                                      # sounds already photographed
    t_prev = time.time()
    while not tracker.stop_evt.is_set():
        st = tracker.state
        now = time.time()
        dt, t_prev = now - t_prev, now
        if st and st['cam_az'] is not None:
            tgt = dir_vec(st['cam_az'], st['cam_el'])
            look = look + (tgt - look) * (1 - np.exp(-dt / max(RC.SMOOTH_S, 1e-3)))
            look /= np.linalg.norm(look)
        laz = float(np.degrees(np.arctan2(look[1], look[0])))
        lel = float(np.degrees(np.arcsin(np.clip(look[2], -1, 1))))
        yaw_now = cam_yaw + (180.0 if other_side else 0.0)

        radar = draw_radar(st, tracker, size=H, cam_yaw=yaw_now)
        frame = cam.latest() if cam is not None else None
        if frame is not None and not saved_frame and not args.camera_file:
            # one picture from the X4, to check the projection/orientation later
            os.makedirs(os.path.join(HERE, 'logs'), exist_ok=True)
            p = os.path.join(HERE, 'logs', 'x4_frame.jpg')
            cv2.imwrite(p, frame)
            print(f'X4 picture received ({frame.shape[1]}x{frame.shape[0]}), one saved to {p}')
            saved_frame = True

        if frame is not None:
            view = reframer.render(frame, laz, lel, yaw_now, mirror, upside)
            view = cv2.resize(view, (Wv * K, H * K), interpolation=cv2.INTER_LINEAR)
            cv2.drawMarker(view, (Wv * K // 2, H * K // 2), GREEN, cv2.MARKER_CROSS, 26 * K, K, cv2.LINE_AA)
            # whole 360 panorama, turned the same way as the view, middle band
            # only (about +-60 deg of elevation)
            pw = Wv * K
            pano = cv2.resize(frame, (pw, pw // 2), interpolation=cv2.INTER_AREA)
            if upside:
                pano = cv2.flip(pano, -1)
            if mirror:
                pano = cv2.flip(pano, 1)
            top = (pw // 2 - Hb * K) // 2
            pano = np.ascontiguousarray(pano[top:top + Hb * K])
            px, py = panorama_xy(laz, lel, pw, pw // 2, yaw_now)
            cv2.circle(pano, (px, py - top), 14 * K, GREEN, 2 * K, cv2.LINE_AA)
            if st and st['cam_az'] is not None:
                qx, qy = panorama_xy(st['cam_az'], st['cam_el'], pw, pw // 2, yaw_now)
                cv2.drawMarker(pano, (qx, qy - top), RED, cv2.MARKER_TILTED_CROSS, 16 * K, 2 * K,
                               cv2.LINE_AA)
            fov = reframer.hfov
        else:
            view = np.full((H * K, Wv * K, 3), 18, np.uint8)
            pano = np.full((Hb * K, Wv * K, 3), 18, np.uint8)
            msg = 'camera off (--no-camera)' if cam is None else getattr(cam, 'status', 'waiting...')
            text(view, 'X4: ' + msg, (20, H // 2), GREY, 0.6)
            fov = reframer.hfov if reframer is not None else RC.VIEW_FOV_DEG

        view_line = (f"view  az {round(laz) + 0:+d}  el {round(lel) + 0:+d}   zoom {fov:.0f} deg"
                     f"{'   other side' if other_side else ''}{'   upside-down' if upside else ''}")
        cam_status = getattr(cam, 'status', 'connected') if cam is not None else 'off'
        info = draw_info(st, H, Hb, view_line, cam_status)
        canvas = np.vstack([np.hstack([view, radar]), np.hstack([pano, info])])
        cv2.imshow(win, canvas)

        if pic_dir is not None and len(sounds.events) > n_pics:
            for ev in sounds.events[n_pics:]:
                shot = None
                if frame is not None and ev.get('cam_az') is not None:
                    shot = reframer.render(frame, ev['cam_az'], ev['cam_el'], yaw_now, mirror, upside)
                try:
                    save_sound_pictures(pic_dir, ev, frame, shot, canvas)
                except Exception as e:
                    print(f'  (could not save pictures of sound {ev["n"]}: {e})')
            n_pics = len(sounds.events)

        # screen video of the window while recording (R / --record)
        if tracker.recorder is not None and video is None:
            rec = tracker.recorder
            video = WindowVideo(os.path.join(rec.folder, f'live_{rec.stamp}_video_silent.mp4'),
                                (canvas.shape[1] // 2 // 2 * 2, canvas.shape[0] // 2 // 2 * 2))
            rec.video = (video.path, video.t0)
        if video is not None:
            video.offer(canvas)

        key = cv2.waitKey(15) & 0xFF
        if key in (ord('q'), 27):
            break
        elif key == ord('b'):                       # look out of the other side of the X4
            other_side = not other_side
        elif key == ord('u'):
            upside = not upside
        elif key == ord('-') and reframer is not None:
            reframer.set_view(RC.VIEW_SIZE, min(150, reframer.hfov + 10))
        elif key == ord('=') and reframer is not None:
            reframer.set_view(RC.VIEW_SIZE, max(30, reframer.hfov - 10))
        elif key == ord('c'):
            tracker.zyl.clear()
            if tracker.zoom is not None:
                tracker.zoom.clear()
        elif key == ord('r') and not isinstance(tracker.zsrc, FileInput):
            if tracker.recorder is None:
                tracker.recorder = Recorder(args.record_dir, tracker.zsrc, tracker.osrc, args.zoom_format,
                                            tracker.x4src)
                print('Recording to', tracker.recorder.path_hint)
            else:
                rec, tracker.recorder = tracker.recorder, None
                if video is not None:           # finish the video before adding its sound
                    video.close()
                    video = None
                rec.close()
    tracker.stop_evt.set()
    if video is not None:
        video.close()
    if pic_dir is not None and n_pics:
        print(f'Pictures of every sound saved to {pic_dir}/')
    if args.snapshot and canvas is not None:
        cv2.imwrite(args.snapshot, canvas)
    cv2.destroyAllWindows()
    if other_side or upside != getattr(RC, 'CAMERA_UPSIDE_DOWN', False):
        print(f'\nCamera settings changed live -- to keep them, put in rig_config.py:\n'
              f'  CAMERA_YAW_DEG = {float(wrap180(yaw_now)):.1f}\n'
              f'  CAMERA_UPSIDE_DOWN = {upside}')


def replay_summary(hist, truth_az=None):
    if not hist:
        print('\nNo estimates -- nothing passed the gates.')
        return
    az = np.array([h[1] for h in hist])
    el = np.array([h[2] for h in hist])
    r = np.array([h[3] for h in hist if h[3] is not None])
    # azimuth percentiles taken around the circular mean, so a source at
    # 180 deg does not get split into -179 and +179
    mu = np.degrees(np.angle(np.mean(np.exp(1j * np.radians(az)))))
    azu = wrap180(az - mu) + mu
    q = lambda v: np.percentile(v, [25, 50, 75])
    print(f'\nREPLAY SUMMARY over {len(hist)} live updates '
          f'({len(r)} with a trusted distance):')
    print('             25%   median      75%')
    a = [float(wrap180(v)) for v in q(azu)]
    print(f'  az   {a[0]:+8.1f} {a[1]:+8.1f} {a[2]:+8.1f} deg')
    e = q(el)
    print(f'  el   {e[0]:+8.1f} {e[1]:+8.1f} {e[2]:+8.1f} deg')
    if len(r):
        d = q(r)
        print(f'  r    {d[0]:8.2f} {d[1]:8.2f} {d[2]:8.2f} m')
    if truth_az is not None:
        bad = np.abs(wrap180(az - truth_az)) > 30
        print(f'  updates more than 30 deg off the true azimuth: {bad.sum()} of {len(az)}')


# ======================= main ============================================
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--list-devices', action='store_true')
    ap.add_argument('--no-camera', action='store_true', help='audio only (radar view)')
    ap.add_argument('--headless', action='store_true', help='no window, just print')
    ap.add_argument('--zylia-only', action='store_true', help='ignore the Zoom (no distance)')
    ap.add_argument('--record', action='store_true', help='save both mics while tracking')
    ap.add_argument('--record-dir', default=os.path.join(HERE, 'recordings'))
    ap.add_argument('--replay', nargs='+', metavar='WAV',
                    help='ZYLIA.wav [ZOOM.wav]: run recordings through the live path')
    ap.add_argument('--offset', type=float, default=None,
                    help='replay: tZoom = tZylia + OFFSET s (default: found automatically)')
    ap.add_argument('--fast', action='store_true', help='replay as fast as possible')
    ap.add_argument('--truth-az', type=float, default=None,
                    help='replay: true source azimuth, to count gross outliers')
    ap.add_argument('--calibrate', nargs='+', type=float, metavar='M',
                    help='X Y [Z]: source at this rig position (m) -> measure mic yaws')
    ap.add_argument('--duration', type=float, default=15.0, help='calibration length (s)')
    ap.add_argument('--tau', type=float, default=RC.TAU_S, help='map memory (s)')
    ap.add_argument('--update-hz', type=float, default=10.0)
    ap.add_argument('--verbose', action='store_true',
                    help='also print the running estimate every --print-every s')
    ap.add_argument('--print-every', type=float, default=0.5, help='(with --verbose) line interval (s)')
    ap.add_argument('--no-log', action='store_true', help='do not save the list of sounds to logs/')
    ap.add_argument('--zoom-format', default=RC.ZOOM_FORMAT, choices=['ambix', 'fuma'])
    ap.add_argument('--camera-index', type=int, default=RC.CAMERA_INDEX)
    ap.add_argument('--projection', default=RC.CAMERA_PROJECTION, choices=['equirect', 'dualfisheye'])
    ap.add_argument('--udp', default=None, metavar='HOST:PORT',
                    help='also send each estimate as JSON over UDP, e.g. 127.0.0.1:9870')
    ap.add_argument('--max-width', type=int, default=1400)
    ap.add_argument('--seconds', type=float, default=None, help='stop by itself after this long')
    ap.add_argument('--camera-file', default=None, help='use an image/video instead of the X4 (testing)')
    ap.add_argument('--snapshot', default=None, help='save the last window image here on exit')
    args = ap.parse_args()

    if args.list_devices:
        import sounddevice as sd
        print(sd.query_devices())
        return

    use_zoom = RC.USE_ZOOM and not args.zylia_only
    if args.replay:
        zf = args.replay[0]
        of = args.replay[1] if len(args.replay) > 1 and use_zoom else None
        off = args.offset
        if of is not None and off is None:
            from validate_offline import envelope_offset
            import soundfile as sf
            a, fa = sf.read(zf, dtype='float32', always_2d=True, frames=int(60 * 48000))
            b, fb = sf.read(of, dtype='float32', always_2d=True, frames=int(60 * 48000))
            off, _ = envelope_offset(a[:, :19].mean(1) if a.shape[1] >= 19 else a[:, 0], fa, b[:, 0], fb)
            print(f'replay: Zoom clock = Zylia clock {off:+.3f} s (envelope match)')
        off = off or 0.0
        zsrc = FileInput(zf, max(0.0, -off))
        osrc = FileInput(of, max(0.0, off)) if of else None
    else:
        zsrc = LiveInput(RC.ZYLIA_DEVICE, 19, RC.SAMPLE_RATE)
        osrc = LiveInput(RC.ZOOM_DEVICE, 4, RC.SAMPLE_RATE) if use_zoom else None
        print(f'Zylia : {zsrc.name}')
        if osrc:
            print(f'Zoom  : {osrc.name}  ({args.zoom_format})')

    print('Building steering matrices...', end=' ', flush=True)
    tracker = Tracker(zsrc, osrc, args)
    print('done.')
    x4src = None
    if not args.replay and not args.calibrate:
        try:                                    # the X4 in Webcam mode is also a stereo mic
            x4src = LiveInput(RC.CAMERA_NAME, 2, RC.SAMPLE_RATE)
            print(f'X4 mic: {x4src.name} (the sound of the recorded video)')
        except (SystemExit, Exception):
            x4src = None
    tracker.x4src = x4src
    print(f'Rig: {RC.LAYOUT}, baseline {RC.BASELINE_M:.2f} m, yaw Zylia {RC.YAW_ZYLIA_DEG:+.2f}, '
          f'Zoom {RC.YAW_ZOOM_DEG:+.2f}' if use_zoom else 'Zylia only: direction, no distance')

    if args.record and not args.replay:
        tracker.recorder = Recorder(args.record_dir, zsrc, osrc, args.zoom_format, x4src)
        print('Recording to', tracker.recorder.path_hint)

    if not args.calibrate:
        stamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
        log = None if args.no_log else os.path.join(HERE, 'logs', f'sounds_{stamp}.csv')
        tracker.sounds = SoundEvents(tracker, log)
        print('\nListening. Every sound (clap, word, knock...) gets one line below:'
              '\n  az = left(+)/right(-) of straight ahead, el = up(+)/down(-), '
              'dist = distance from the middle of the two mics.'
              + (f'\n  Also saved to {log}' if log else '') + '\n', flush=True)

    for s in (zsrc, osrc, x4src):
        if s is not None:
            s.start()
    try:
        if args.calibrate:
            c = list(args.calibrate) + [0.0] * (3 - len(args.calibrate))
            calibrate(tracker, c[0], c[1], c[2], args.duration)
            return
        th = threading.Thread(target=tracker.run, daemon=True)
        th.start()
        if args.seconds:
            threading.Timer(args.seconds, tracker.stop_evt.set).start()
        if args.headless:
            try:
                while th.is_alive():
                    time.sleep(0.2)
            except KeyboardInterrupt:
                pass
        else:
            cam = reframer = None
            if args.camera_file:
                from camera_view import Reframer, StillCamera
                cam = StillCamera(args.camera_file)
                reframer = Reframer(RC.VIEW_SIZE, RC.VIEW_FOV_DEG, args.projection,
                                    RC.DUALFISHEYE_FOV_DEG)
            elif not args.no_camera:
                from camera_view import Reframer, open_panorama_camera
                try:
                    cam = open_panorama_camera(RC.CAMERA_NAME, RC.CAMERA_REQUEST_SIZE,
                                               args.camera_index)
                    print(f'Camera: {getattr(cam, "name", "index %s" % args.camera_index)} '
                          f'at {RC.CAMERA_REQUEST_SIZE[0]}x{RC.CAMERA_REQUEST_SIZE[1]}')
                    reframer = Reframer(RC.VIEW_SIZE, RC.VIEW_FOV_DEG, args.projection,
                                        RC.DUALFISHEYE_FOV_DEG)
                except Exception as e:                    # no X4 -> still track, radar only
                    print(f'Camera not available ({e}). Continuing with the radar view only.')
                    cam = None
            try:
                gui_loop(tracker, cam, reframer, args)
            finally:
                if cam is not None:
                    cam.close()
        tracker.stop_evt.set()
        th.join(timeout=2)
        if args.replay:
            replay_summary(tracker.history, args.truth_az)
    finally:
        for s in (zsrc, osrc, x4src):
            if s is not None:
                s.stop()
        if tracker.recorder is not None:
            tracker.recorder.close()
        if tracker.sounds is not None:
            tracker.sounds.close()


if __name__ == '__main__':
    main()
