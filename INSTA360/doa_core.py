"""
doa_core.py -- direction of arrival for ONE spherical array, frame by frame.

This is a Python port of the validated MATLAB code in ../matlab/:

    run_doa.m / az_power_map.m     frequency-domain steered-response power (SRP)
    build_steering_matrix.m        SH steering vectors, frequency-dependent order
    real_sh_matrix.m               real ACN/N3D spherical harmonics
    convert_to_acn_n3d.m           AmbiX / FuMa  ->  ACN/N3D
    estimate_distance.m            rigid-sphere capsule model of the ZM-1

WHY THE ZYLIA IS STEERED IN THE CAPSULE DOMAIN LIVE
Offline, the Zylia went through ZYLIA Ambisonics Converter first and run_doa
worked on the 16-channel ACN/SN3D file. Live, the ZM-1 driver hands us the 19
RAW capsule signals, and there is no converter in the loop. So instead of
encoding to ambisonics and steering there, the SRP steers the capsules
directly with the exact rigid-sphere model from estimate_distance.m
(capsule_tf): same sphere, same 0.056 m radius that was calibrated from the
recordings, same point source at 1.5 m. That is the model an ambisonic encoder
is itself derived from, minus the regularised radial filters, so it loses
nothing. validate_offline.py checks it against the MATLAB results on the old
raw 19-channel takes.

The Zoom H3-VR hands us 4-channel AmbiX (or FuMa) live, so its path is the
MATLAB one unchanged: convert to ACN/N3D, steer with order-1 SH.

Conventions (identical to the MATLAB project):
    azimuth   degrees, 0 = the array's front (+x), POSITIVE TO THE LEFT (+y)
    elevation degrees, 0 = horizontal, positive up
"""

from __future__ import annotations

import collections
import math
from dataclasses import dataclass, field

import numpy as np
from scipy.special import lpmv, spherical_jn, spherical_yn

C_SOUND = 343.0

# ---------------------------------------------------------------------------
# ZYLIA ZM-1 geometry -- copied from estimate_distance.m (zylia_geom).
# Rows are capsules in the channel order of the raw recording, [az el] in rad.
# Source: SAF __Zylia1D_coords_rad. Radius 0.056 m was MEASURED from the
# recordings (GCC-PHAT delays match the rigid sphere at corr 0.99), not the
# 0.049 m of the SAF preset.
# ---------------------------------------------------------------------------
ZYLIA_CAPS_AZEL = np.array([
    [0.0,                  1.57079632679490],
    [0.00305809444245928,  0.840254037451382],
    [2.09600986753364,     0.840126252832125],
    [-2.09336058192593,    0.840886905122138],
    [-1.43409959239697,    0.338967177556435],
    [-0.656487391713457,   0.339152933310760],
    [0.661232814211584,    0.338858655681573],
    [1.43624308141539,     0.339058915910358],
    [2.75545932621978,     0.339167630604397],
    [-2.75063229463181,    0.339281599533891],
    [-2.48035983937821,   -0.338858655681573],
    [-1.70534957217440,   -0.339058915910358],
    [-0.386133327370014,  -0.339167630604397],
    [0.390960358957982,   -0.339281599533891],
    [1.70749306119282,    -0.338967177556435],
    [2.48510526187634,    -0.339152933310760],
    [-3.13853455914733,   -0.840254037451382],
    [-1.04558278605616,   -0.840126252832125],
    [1.04823207166387,    -0.840886905122138],
])
ZYLIA_RADIUS = 0.056


def _quiet_matmul():
    # numpy 2.0 on Apple Accelerate raises spurious divide/overflow FP flags
    # inside matmul even when every result is finite (numpy issue #26669).
    # The results are verified correct; only the bogus warnings are hidden.
    return np.errstate(divide='ignore', over='ignore', invalid='ignore')


# ===================== special functions ==================================
def unit_vectors(az, el):
    """az, el in radians (any shape) -> (..., 3) unit vectors."""
    az = np.asarray(az, float)
    el = np.asarray(el, float)
    return np.stack([np.cos(el) * np.cos(az),
                     np.cos(el) * np.sin(az),
                     np.sin(el)], axis=-1)


def sph_h2(n, x, derivative=False):
    """Spherical Hankel function of the second kind, same as sph_hankel2.m."""
    x = np.maximum(np.asarray(x, float), 1e-6)
    return (spherical_jn(n, x, derivative) - 1j * spherical_yn(n, x, derivative))


def real_sh_matrix(order, az, el):
    """Real ACN / N3D spherical harmonics, port of real_sh_matrix.m.
    az, el in radians, 1-D length K.  Returns ((order+1)^2, K)."""
    az = np.ravel(az)
    el = np.ravel(el)
    Y = np.zeros(((order + 1) ** 2, az.size))
    x = np.sin(el)
    for n in range(order + 1):
        for m in range(-n, n + 1):
            am = abs(m)
            # scipy's lpmv includes the Condon-Shortley phase, like MATLAB's
            # legendre(); remove it exactly as real_sh_matrix.m does.
            P = ((-1) ** am) * lpmv(am, n, x)
            c = np.sqrt((2 * n + 1) * math.factorial(n - am) / math.factorial(n + am))
            if m != 0:
                c *= np.sqrt(2)
            trig = np.sin(am * az) if m < 0 else np.cos(am * az)
            Y[n * n + n + m, :] = c * P * trig
    return Y


def ambi_to_acn_n3d(x, fmt, order):
    """Port of convert_to_acn_n3d.m.  x: (samples, channels)."""
    nCh = (order + 1) ** 2
    if x.shape[1] < nCh:
        raise ValueError(f"{x.shape[1]} channels but order {order} needs {nCh}. "
                         "Is the recorder in 4ch Ambisonics mode?")
    x = x[:, :nCh]
    fmt = fmt.lower()
    if fmt == 'ambix':
        b = x
    elif fmt == 'fuma':
        if order != 1:
            raise ValueError('FuMa conversion is implemented for 1st order only.')
        b = np.stack([x[:, 0] * np.sqrt(2), x[:, 2], x[:, 3], x[:, 1]], axis=1)
    else:
        raise ValueError(f'unknown ambisonic format "{fmt}" (use ambix or fuma)')
    n_of_acn = np.floor(np.sqrt(np.arange(nCh)))
    return b * np.sqrt(2 * n_of_acn + 1)


# ===================== steering matrices ==================================
def sh_steering(order, mic_radius, freqs, grid_az, grid_el, r_steer, c=C_SOUND):
    """Port of build_steering_matrix.m.  Returns W (nF, nCh, K) complex,
    each column unit-norm.  Frequency-dependent order when mic_radius > 0."""
    nCh = (order + 1) ** 2
    K = grid_az.size
    Y = real_sh_matrix(order, grid_az, grid_el)                 # nCh x K
    n_of_acn = np.floor(np.sqrt(np.arange(nCh))).astype(int)
    if mic_radius > 0:
        f_cut = np.arange(order + 1) * c / (2 * np.pi * mic_radius)
    else:
        f_cut = np.zeros(order + 1)
    W = np.zeros((freqs.size, nCh, K), complex)
    for fi, f in enumerate(freqs):
        kf = 2 * np.pi * f / c
        h0 = sph_h2(0, kf * r_steer)
        Wf = np.zeros((nCh, K), complex)
        for n in range(order + 1):
            if f < f_cut[n]:
                continue                          # order n not valid yet here
            Rn = (1j) ** (-n) * sph_h2(n, kf * r_steer) / h0
            rows = n_of_acn == n
            Wf[rows, :] = Y[rows, :] * Rn
        nrm = np.linalg.norm(Wf, axis=0)
        nrm[nrm == 0] = 1
        W[fi] = Wf / nrm
    return W


def rigid_sphere_capsule_steering(caps_azel, a, freqs, grid_az, grid_el, r_steer,
                                  c=C_SOUND):
    """Port of capsule_tf in estimate_distance.m, for a whole direction grid.
    Pressure at each capsule of a rigid sphere (radius a) from a point source
    at distance r_steer:
        p_q = sum_n (2n+1)/(4pi) h_n(kr) b_n(ka) P_n(cos gamma_q),
        b_n(x) = -1i / (x^2 h_n'(x)).
    Returns W (nF, Q, K), each column unit-norm."""
    k = 2 * np.pi * np.asarray(freqs, float) / c
    k[k == 0] = 1e-6
    ka = k * a
    N = int(min(40, np.ceil(ka.max() + 4.05 * ka.max() ** (1 / 3) + 3)))

    uQ = unit_vectors(caps_azel[:, 0], caps_azel[:, 1])           # Q x 3
    uS = unit_vectors(grid_az, grid_el)                            # K x 3
    with _quiet_matmul():
        cosG = np.clip(uQ @ uS.T, -1, 1)                           # Q x K

    # Legendre P_n(cos gamma), n = 0..N, by recursion
    P = np.empty((N + 1,) + cosG.shape)
    P[0] = 1.0
    if N >= 1:
        P[1] = cosG
    for n in range(1, N):
        P[n + 1] = ((2 * n + 1) * cosG * P[n] - n * P[n - 1]) / (n + 1)

    coef = np.empty((k.size, N + 1), complex)                      # nF x (N+1)
    for n in range(N + 1):
        Hp = sph_h2(n, ka, derivative=True)
        bn = -1j / (ka ** 2 * Hp)
        bn[~np.isfinite(bn)] = 0
        coef[:, n] = (2 * n + 1) / (4 * np.pi) * sph_h2(n, k * r_steer) * bn

    Q, K = cosG.shape
    with _quiet_matmul():
        W = (coef @ P.reshape(N + 1, Q * K)).reshape(k.size, Q, K)
    nrm = np.linalg.norm(W, axis=1, keepdims=True)
    nrm[nrm == 0] = 1
    return W / nrm


# ===================== one array =========================================
@dataclass
class ArrayConfig:
    """Everything that describes ONE microphone for the SRP.  Defaults for the
    two mics in this project are built by zylia_config() / zoom_config()."""
    name: str
    kind: str                     # 'capsule' (raw ZM-1) or 'sh' (ambisonic)
    fs: float = 48000
    frame_len: int = 1024         # ~21 ms at 48 kHz, as in main_2mic.m
    hop: int = 512
    f_band: tuple = (1000, 12000)
    n_bins: int = 60
    order: int = 1                # SH order ('sh' only)
    mic_radius: float = 0.0       # 'sh': order cut-on radius; 'capsule': sphere radius
    in_format: str = 'ambix'      # 'sh' only: 'ambix' or 'fuma'
    channels: tuple = ()          # which device channels to use (0-based)
    az_step_deg: float = 2.0
    el_grid_deg: tuple = tuple(range(-40, 65, 5))
    r_steer: float = 1.5          # steering distance, as main_2mic.m (rGrid = 1.5)
    whiten: bool = False          # per-bin normalisation (SRP-PHAT-like)
    clip_level: float = 0.985     # az_power_map.m drops frames with a sample above this


def zylia_config(fs=48000, **kw):
    # 1-8 kHz for the raw-capsule path: swept against the seven recorded takes
    # (1-12k, 1-8k, 1.5-10k, 0.7-6k; with and without whitening), all within
    # ~0.5 deg of each other; 1-8k plain gave the best az + el together
    # (2.6 / 1.6 deg RMS). The converted-SH path keeps MATLAB's 1-12 kHz.
    c = ArrayConfig(name='Zylia ZM-1', kind='capsule', fs=fs,
                    f_band=(1000, 8000), mic_radius=ZYLIA_RADIUS,
                    channels=tuple(range(19)))
    for k, v in kw.items():
        setattr(c, k, v)
    return c


def zoom_config(fs=48000, in_format='ambix', **kw):
    c = ArrayConfig(name='Zoom H3-VR', kind='sh', fs=fs, order=1,
                    f_band=(800, 4000), mic_radius=0.0, in_format=in_format,
                    channels=(0, 1, 2, 3))
    for k, v in kw.items():
        setattr(c, k, v)
    return c


class SrpArray:
    """Precomputes the steering matrix once, then turns frames into maps.

    maps(frames) -> per-frame SRP power over the (az, el) grid, exactly the
    P = sum_f |W_f^H x_f|^2 of run_doa.m.  Everything is vectorised over a
    block of frames so the live loop can keep up."""

    def __init__(self, cfg: ArrayConfig, c=C_SOUND):
        self.cfg = cfg
        L = cfg.frame_len
        self.win = (0.5 * (1 - np.cos(2 * np.pi * np.arange(L) / L))).astype(np.float32)
        fAx = np.arange(L // 2 + 1) * cfg.fs / L
        in_band = np.flatnonzero((fAx >= cfg.f_band[0]) & (fAx <= cfg.f_band[1]))
        if in_band.size == 0:
            raise ValueError(f'no FFT bins inside f_band {cfg.f_band}')
        # same bin picking as run_doa.m:  unique(inBand(round(linspace(...))))
        pick = np.round(np.linspace(0, in_band.size - 1,
                                    min(cfg.n_bins, in_band.size))).astype(int)
        self.sel = np.unique(in_band[pick])
        self.freqs = fAx[self.sel]

        self.az_deg = np.arange(0, 360, cfg.az_step_deg)
        self.el_deg = np.asarray(cfg.el_grid_deg, float)
        AZ, EL = np.meshgrid(np.deg2rad(self.az_deg), np.deg2rad(self.el_deg),
                             indexing='ij')                    # nAz x nEl
        gaz, gel = AZ.ravel(), EL.ravel()
        if cfg.kind == 'capsule':
            caps = ZYLIA_CAPS_AZEL[:len(cfg.channels)]
            W = rigid_sphere_capsule_steering(caps, cfg.mic_radius, self.freqs,
                                              gaz, gel, cfg.r_steer, c)
        elif cfg.kind == 'sh':
            W = sh_steering(cfg.order, cfg.mic_radius, self.freqs, gaz, gel,
                            cfg.r_steer, c)
        else:
            raise ValueError(cfg.kind)
        # stored as W^H so a batched matmul gives W^H x directly: (nF, K, nCh)
        self.WH = np.ascontiguousarray(np.conj(np.transpose(W, (0, 2, 1)))).astype(np.complex64)
        self.shape = (self.az_deg.size, self.el_deg.size)

    # -- raw device samples -> the signals the steering matrix expects -------
    def prepare(self, x):
        """x: (samples, device_channels) float.  Returns (samples, nCh)."""
        cfg = self.cfg
        x = x[:, list(cfg.channels)]
        if cfg.kind == 'sh':
            x = ambi_to_acn_n3d(x, cfg.in_format, cfg.order)
        return x.astype(np.float32, copy=False)

    def spectra(self, frames):
        """frames: (T, L, nCh) -> in-band spectra (T, nF, nCh) and the in-band
        omni level E (T,) that run_doa / az_power_map gate on."""
        F = np.fft.rfft(frames * self.win[None, :, None], axis=1)[:, self.sel, :]
        if self.cfg.kind == 'sh':
            omni = F[:, :, 0]
        else:
            omni = F.mean(axis=2)            # raw capsules -> omni (align_two_mics.m)
        E = np.sqrt(np.mean(np.abs(omni) ** 2, axis=1))
        return F.astype(np.complex64), E

    def maps(self, F):
        """F: (T, nF, nCh) -> SRP power (T, nAz, nEl)."""
        if F.shape[0] == 0:
            return np.zeros((0,) + self.shape, np.float32)
        if self.cfg.whiten:
            F = F / (np.linalg.norm(F, axis=2, keepdims=True) + 1e-12)
        X = np.transpose(F, (1, 2, 0))                         # nF x nCh x T
        with _quiet_matmul():
            Y = np.matmul(self.WH, X)                          # nF x K x T
        P = np.sum(Y.real ** 2 + Y.imag ** 2, axis=0)          # K x T
        return P.T.reshape((F.shape[0],) + self.shape).astype(np.float32)


# ===================== per-frame normalisation (az_power_map.m) ===========
def _contrast(a):
    """0 at each row's own floor, 1 at its own peak (flat rows -> 0)."""
    lo = a.min(axis=1, keepdims=True)
    rng = a.max(axis=1, keepdims=True) - lo
    return np.where(rng > 0, (a - lo) / np.where(rng > 0, rng, 1), 0), rng[:, 0] > 0


def frame_weights_and_norm(P):
    """P: (T, nAz, nEl) raw SRP maps -> exactly what az_power_map.m keeps:

        pAz  (T, nAz)  azimuth profile, max over elevation, contrast-normalised
        pEl  (T, nEl)  elevation profile, max over azimuth, contrast-normalised
        w    (T,)      decisiveness: (peak - median) / median of the az profile

    A diffuse frame (flat map) gets w ~ 0 and is nearly ignored; a clean direct
    arrival dominates. Elevation is taken from its OWN marginal, as MATLAB
    does -- a joint 2-D peak reads ~8 deg high on the elevated clap take."""
    pAz = P.max(axis=2)                                        # T x nAz
    pEl = P.max(axis=1)                                        # T x nEl
    md = np.median(pAz, axis=1)
    w = (pAz.max(axis=1) - md) / np.maximum(md, 1e-30)
    pAz, ok = _contrast(pAz)
    pEl, _ = _contrast(pEl)
    w = np.where(ok, w, 0)
    return pAz.astype(np.float32), pEl.astype(np.float32), w.astype(np.float32)


def parab(x0, dx, Pm, P0, Pp):
    """Parabolic peak refinement, port of parab() in run_doa.m."""
    den = 2 * Pp - 4 * P0 + 2 * Pm
    if abs(den) < 1e-12 * max(abs(Pm), abs(P0), abs(Pp), 1):
        return x0
    off = -(Pp - Pm) / den
    return x0 + max(min(off, 1), -1) * dx


def profile_peaks(pAz, pEl, az_deg, el_deg):
    """Refined peaks of accumulated azimuth / elevation profiles.
    Returns az in [-180, 180) and el, in degrees."""
    ia = int(np.argmax(pAz))
    nAz = az_deg.size
    dAz = az_deg[1] - az_deg[0]
    az = parab(az_deg[ia], dAz, pAz[(ia - 1) % nAz], pAz[ia], pAz[(ia + 1) % nAz])
    ie = int(np.argmax(pEl))
    if 0 < ie < el_deg.size - 1:
        el = parab(el_deg[ie], el_deg[1] - el_deg[0], pEl[ie - 1], pEl[ie], pEl[ie + 1])
    else:
        el = el_deg[ie]
    return float(wrap180(az)), float(el)


def wrap180(x):
    return (np.asarray(x) + 180) % 360 - 180


# ===================== streaming pieces ===================================
class Framer:
    """Collects arbitrary-length chunks and hands back whole overlapping
    frames (T, L, nCh), hop apart, plus how many frames have been emitted."""

    def __init__(self, frame_len, hop, n_ch):
        self.L, self.hop = frame_len, hop
        self.buf = np.zeros((0, n_ch), np.float32)
        self.count = 0

    def push(self, x):
        self.buf = np.concatenate([self.buf, x.astype(np.float32, copy=False)])
        n = self.buf.shape[0]
        if n < self.L:
            return np.zeros((0, self.L, self.buf.shape[1]), np.float32)
        T = (n - self.L) // self.hop + 1
        idx = np.arange(self.L)[None, :] + self.hop * np.arange(T)[:, None]
        frames = self.buf[idx]
        self.buf = self.buf[T * self.hop:]
        self.count += T
        return frames


class LiveGate:
    """The two gates of az_power_map.m, made causal.

    A frame passes if its in-band level is BOTH within energy_gate_db of the
    loud level (95th percentile, so a clap does not silence the speech) AND at
    least snr_gate_db over this session's own noise floor (10th percentile).
    Offline those percentiles were taken over the whole file; live they are
    taken over the last history_s seconds."""

    def __init__(self, frame_rate, energy_gate_db=-25, snr_gate_db=10,
                 history_s=10.0, abs_floor=1e-7):
        self.hist = collections.deque(maxlen=max(10, int(history_s * frame_rate)))
        self.rel = 10 ** (energy_gate_db / 20)
        self.snr = 10 ** (snr_gate_db / 20)
        self.abs_floor = abs_floor
        self.noise = None
        self.loud = None
        self._n = 0

    def __call__(self, E):
        self.hist.extend(E.tolist())
        self._n += len(E)
        if self.noise is None or self._n >= 20:
            h = np.asarray(self.hist)
            self.noise = float(np.quantile(h, 0.10))
            self.loud = float(np.quantile(h, 0.95))
            self._n = 0
        gate = max(self.loud * self.rel, self.noise * self.snr, self.abs_floor)
        if len(self.hist) < 20:              # need some history before trusting it
            return np.zeros(len(E), bool), gate
        return E >= gate, gate

    @property
    def snr_db(self):
        if not self.hist or not self.noise:
            return 0.0
        return 20 * np.log10(max(self.hist[-1], 1e-30) / max(self.noise, 1e-30))


class MapAccumulator:
    """Accumulates the weighted, contrast-normalised azimuth and elevation
    profiles with exponential forgetting (time constant tau_s).

    tau_s = inf reproduces the whole-file sum of az_power_map.m exactly; a
    finite tau (live) lets the answer follow a talker who moves. 0.6 s means a
    frame's vote has faded to 1/e after 0.6 s."""

    def __init__(self, n_az, n_el, frame_rate, tau_s=0.6):
        self.A = np.zeros(n_az)
        self.E = np.zeros(n_el)
        self.wsum = 0.0
        if np.isinf(tau_s):
            self.decay = 1.0
        else:
            self.decay = float(np.exp(-1.0 / (max(tau_s, 1e-3) * frame_rate)))
        self.frame = 0
        self.last_active_frame = -10 ** 9

    def step(self, n_frames, pAz=None, pEl=None, w=None):
        """Advance by n_frames (every frame, gated or not), adding the active
        ones' profiles weighted by w."""
        if n_frames > 0 and self.decay < 1.0:
            d = self.decay ** n_frames
            self.A *= d
            self.E *= d
            self.wsum *= d
        if w is not None and len(w):
            with _quiet_matmul():
                self.A += w @ pAz
                self.E += w @ pEl
            self.wsum += float(np.sum(w))
            if np.any(w > 0):
                self.last_active_frame = self.frame + n_frames
        self.frame += n_frames

    def profiles(self):
        a = self.A / self.A.max() if self.A.max() > 0 else self.A.copy()
        e = self.E / self.E.max() if self.E.max() > 0 else self.E.copy()
        return a, e


# ===================== whole-file helper (validation) =====================
def whole_file_map(srp: SrpArray, x, energy_gate_db=-25, snr_gate_db=10):
    """Offline equivalent of az_power_map.m on a whole signal x (samples, ch):
    file-global gates, clipped-frame rejection, decisiveness weighting.
    Returns the accumulated azimuth / elevation profiles and their peaks."""
    cfg = srp.cfg
    xs = srp.prepare(x)
    clip = np.any(np.abs(x[:, list(cfg.channels)]) > cfg.clip_level, axis=1)
    L, hop = cfg.frame_len, cfg.hop
    T = (xs.shape[0] - L) // hop + 1
    F_all, E_all = [], []
    for t0 in range(0, T, 256):
        idx = np.arange(L)[None, :] + hop * np.arange(t0, min(T, t0 + 256))[:, None]
        F, E = srp.spectra(xs[idx])
        F_all.append(F)
        E_all.append(E)
    F = np.concatenate(F_all)
    E = np.concatenate(E_all)
    noise = np.quantile(E, 0.10)
    loud = np.quantile(E, 0.95)
    gate = max(loud * 10 ** (energy_gate_db / 20), noise * 10 ** (snr_gate_db / 20))
    fclip = np.array([clip[t * hop:t * hop + L].any() for t in range(T)])
    active = (E >= gate) & ~fclip
    acc = MapAccumulator(srp.az_deg.size, srp.el_deg.size, 1.0, tau_s=np.inf)
    ia = np.flatnonzero(active)
    for k0 in range(0, ia.size, 128):
        pAz, pEl, w = frame_weights_and_norm(srp.maps(F[ia[k0:k0 + 128]]))
        acc.step(0, pAz, pEl, w)
    pAz, pEl = acc.profiles()
    az, el = profile_peaks(pAz, pEl, srp.az_deg, srp.el_deg)
    return dict(az=az, el=el, pAz=pAz, pEl=pEl,
                n_active=int(active.sum()), n_clip=int(fclip.sum()),
                snr_db=float(20 * np.log10(E.max() / max(noise, 1e-30))))
