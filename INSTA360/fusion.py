"""
fusion.py -- source POSITION from the two arrays' azimuth maps.

Port of triangulate.m (fuse + its guards). Not two peak bearings crossed: each
array contributes its whole accumulated azimuth map, and the two are
multiplied over a grid of candidate source positions. A slightly-off frame
widens the ridge instead of moving the answer.

Everything that depends only on the rig geometry (which azimuth each grid
point sits at, as seen from each mic) is precomputed once, so a fusion is a
couple of array lookups and one multiply -- cheap enough to run ten times a
second.

Rig frame (same as main_2mic.m): x = forward (the look direction both mics
point along), y = left, z = up, metres, origin = midpoint of the two mics.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from doa_core import wrap180


@dataclass
class FusionResult:
    pos: np.ndarray          # [x, y] metres, rig frame
    rA: float                # distance from mic A (Zylia)
    rB: float                # distance from mic B (Zoom)
    azA: float               # mic A bearing in the RIG frame (yaw removed)
    azB: float
    sep: float               # parallax between the two rays at the answer
    forward: bool            # do the two peak bearings cross in front of both?
    trusted: bool
    warning: str
    S: np.ndarray            # the fused likelihood map (for display)


class Triangulator:
    def __init__(self, posA, posB, az_deg, yawA=0.0, yawB=0.0,
                 span=None, step=None, mask_r=0.25):
        """posA/posB: [x, y] of mic A (Zylia) and mic B (Zoom), metres.
        az_deg: the azimuth grid of the maps that will be passed in.
        yawA/yawB: how far each mic's OWN zero is rotated from the rig's +x,
        in degrees, i.e. a mic reads (true bearing + yaw). Only yawB - yawA
        affects distance (see check_mic_yaw.m); the absolute values matter
        for pointing the camera."""
        self.posA = np.asarray(posA, float)[:2]
        self.posB = np.asarray(posB, float)[:2]
        self.B = float(np.linalg.norm(self.posB - self.posA))
        if self.B < 1e-3:
            raise ValueError('the two mic positions are the same point -- '
                             'triangulation needs a baseline')
        self.az_deg = np.asarray(az_deg, float)
        self.yawA, self.yawB = float(yawA), float(yawB)
        B = self.B
        span = span if span is not None else max(4 * B, 4.0)
        step = step if step is not None else min(0.03, B / 40)
        mid = (self.posA + self.posB) / 2
        self.xg = mid[0] + np.arange(-span, span + step / 2, step)
        self.yg = mid[1] + np.arange(-span, span + step / 2, step)
        X, Y = np.meshgrid(self.xg, self.yg, indexing='ij')
        self.X, self.Y = X, Y
        # which fractional map index each grid point lands on, per mic, with
        # the mic's yaw folded in: rig bearing phi is read from the mic's own
        # map at phi + yaw.
        self._iA = self._lookup(np.degrees(np.arctan2(Y - self.posA[1], X - self.posA[0])) + self.yawA)
        self._iB = self._lookup(np.degrees(np.arctan2(Y - self.posB[1], X - self.posB[0])) + self.yawB)
        self.mask = ((np.hypot(X - self.posA[0], Y - self.posA[1]) < mask_r) |
                     (np.hypot(X - self.posB[0], Y - self.posB[1]) < mask_r))

    def _lookup(self, phi_deg):
        d = self.az_deg[1] - self.az_deg[0]
        f = np.mod(phi_deg - self.az_deg[0], 360.0) / d
        i0 = np.floor(f).astype(int) % self.az_deg.size
        return i0, (i0 + 1) % self.az_deg.size, (f - np.floor(f)).astype(np.float32)

    @staticmethod
    def _interp(P, look):
        i0, i1, fr = look
        return P[i0] * (1 - fr) + P[i1] * fr

    def fuse(self, pA, pB, azA_peak, azB_peak):
        """pA/pB: azimuth power profiles (max over el), normalised to peak 1,
        on self.az_deg, in each mic's OWN frame. azA_peak/azB_peak: their
        refined peaks (deg, own frame)."""
        S = self._interp(pA, self._iA) * self._interp(pB, self._iB)
        S[self.mask] = 0
        k = int(np.argmax(S))
        ia, ib = np.unravel_index(k, S.shape)
        pos = np.array([self.xg[ia], self.yg[ib]])
        rA = float(np.linalg.norm(pos - self.posA))
        rB = float(np.linalg.norm(pos - self.posB))
        vA, vB = pos - self.posA, pos - self.posB
        sep = abs(float(wrap180(np.degrees(np.arctan2(vA[1], vA[0]) - np.arctan2(vB[1], vB[0])))))

        # rig-frame bearings of the two raw peaks
        aA = float(wrap180(azA_peak - self.yawA))
        aB = float(wrap180(azB_peak - self.yawB))

        # ---- the guards of triangulate.m -----------------------------------
        warn = []
        dA = np.array([np.cos(np.radians(aA)), np.sin(np.radians(aA))])
        dB = np.array([np.cos(np.radians(aB)), np.sin(np.radians(aB))])
        M = np.column_stack([dA, -dB])
        if abs(np.linalg.det(M)) < 1e-9:
            s = np.array([-1.0, -1.0])
        else:
            s = np.linalg.solve(M, self.posB - self.posA)
        forward = bool(np.all(s > 0))
        if not forward:
            warn.append('bearings do not cross in front of both mics '
                        '(source near the blind axis through the two mics?)')
        elif rA < 0.5 * self.B or rB < 0.5 * self.B:
            warn.append('peak sits against the mask around a mic')
        if rA > 3 * self.B:
            warn.append(f'r/B = {rA / self.B:.1f} > 3: rays nearly parallel, '
                        'widen the baseline for this range')
        elif sep < 10:
            warn.append(f'parallax only {sep:.1f} deg')
        return FusionResult(pos=pos, rA=rA, rB=rB, azA=aA, azB=aB, sep=sep,
                            forward=forward, trusted=not warn,
                            warning='; '.join(warn), S=S)


def rig_layout(layout, B):
    """main_2mic.m section 2: where the two mics stand. Returns posA (Zylia),
    posB (Zoom)."""
    layout = layout.upper()
    if layout == 'LR':        # side by side, Zylia at -y (rig right), Zoom at +y
        return np.array([0, -B / 2]), np.array([0, B / 2])
    if layout == 'FB':        # Zylia in front (+x), Zoom behind
        return np.array([B / 2, 0]), np.array([-B / 2, 0])
    if layout == 'BF':        # Zoom in front, Zylia behind
        return np.array([-B / 2, 0]), np.array([B / 2, 0])
    raise ValueError(f"layout must be 'LR', 'FB' or 'BF', got {layout!r}")
