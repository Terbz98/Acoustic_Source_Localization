"""
sound_map.py -- where sound is coming from, painted onto the 360-degree picture.

The radar in the tracker window shows the sound from above (left-right only).
This is the same idea for the 360 strip: the Zylia's full direction map
(left-right AND up-down) is kept up to date frame by frame and drawn over the
X4 panorama as a heat map, so the room lights up where the sound is and fades
when it goes quiet.

The Zylia stands 0.5 m to the side of the camera, so a sound 1.5 m away is
seen at up to ~20 degrees different angles from the two. Each panorama
direction is therefore looked up in the Zylia's map at the point where it
meets the current distance estimate (the tracker's source position), i.e. the
map is re-drawn as the CAMERA would see it.
"""

import numpy as np


class MapAccumulator2D:
    """Decisiveness-weighted sum of contrast-normalised az x el maps with the
    same exponential forgetting as doa_core.MapAccumulator (tau_s)."""

    def __init__(self, shape, frame_rate, tau_s=0.6):
        self.M = np.zeros(shape, np.float32)
        self.wsum = 0.0
        self.decay = 1.0 if np.isinf(tau_s) else float(np.exp(-1.0 / (max(tau_s, 1e-3) * frame_rate)))

    def step(self, n_frames, P=None, w=None):
        """Advance n_frames (gated or not); add the active frames' maps P
        (T, nAz, nEl) weighted by w (T,)."""
        if n_frames > 0 and self.decay < 1.0:
            d = self.decay ** n_frames
            self.M *= d
            self.wsum *= d
        if P is not None and len(P):
            T = P.shape[0]
            flat = P.reshape(T, -1)
            lo = flat.min(axis=1, keepdims=True)
            rng = flat.max(axis=1, keepdims=True) - lo
            m = np.where(rng > 0, (flat - lo) / np.where(rng > 0, rng, 1), 0)
            with np.errstate(divide='ignore', over='ignore', invalid='ignore'):   # Accelerate false alarms
                self.M += (np.asarray(w, np.float32) @ m.astype(np.float32)).reshape(self.M.shape)
            self.wsum += float(np.sum(w))

    def map(self):
        mx = float(self.M.max())
        return self.M / mx if mx > 0 else self.M.copy()


def camera_values(M, az_deg, el_deg, posA, yawA, src, cam_pos, w, h, az_left, deg_per_px, el_top, mirror=False):
    """Values of the Zylia map M (nAz x nEl, own frame) for a w x h grid of
    panorama pixels as seen from the camera.

    Pixel (x, y): rig azimuth = az_left - x * deg_per_px (sign flipped if the
    picture is mirrored), elevation = el_top - y * deg_per_px. src is the
    current source position (rig frame, metres): the distance from the camera
    to it is where each pixel's ray is followed out to."""
    x = np.arange(w)
    y = np.arange(h)
    az = az_left - (x + 0.5) * deg_per_px * (-1 if mirror else 1)
    el = el_top - (y + 0.5) * deg_per_px
    A, E = np.meshgrid(np.radians(az), np.radians(el))
    cam = np.asarray(cam_pos, float)
    r = max(float(np.linalg.norm(np.asarray(src, float) - cam)), 0.3)
    P = np.stack([np.cos(E) * np.cos(A), np.cos(E) * np.sin(A), np.sin(E)], -1) * r + cam
    pa = np.r_[np.asarray(posA, float)[:2], 0.0]
    v = P - pa
    azz = np.degrees(np.arctan2(v[..., 1], v[..., 0])) + yawA          # in the Zylia's own frame
    elz = np.degrees(np.arctan2(v[..., 2], np.hypot(v[..., 0], v[..., 1])))
    # bilinear lookup, azimuth wraps
    da = az_deg[1] - az_deg[0]
    fa = np.mod(azz - az_deg[0], 360.0) / da
    i0 = np.floor(fa).astype(int) % len(az_deg)
    i1 = (i0 + 1) % len(az_deg)
    ta = fa - np.floor(fa)
    de = el_deg[1] - el_deg[0]
    fe = (elz - el_deg[0]) / de
    inside = (fe >= 0) & (fe <= len(el_deg) - 1)
    fe = np.clip(fe, 0, len(el_deg) - 1 - 1e-6)
    j0 = np.floor(fe).astype(int)
    te = fe - j0
    j1 = np.minimum(j0 + 1, len(el_deg) - 1)
    val = ((M[i0, j0] * (1 - ta) + M[i1, j0] * ta) * (1 - te) +
           (M[i0, j1] * (1 - ta) + M[i1, j1] * ta) * te)
    return np.where(inside, val, 0.0).astype(np.float32)


def paint(img, values, strength, floor=0.45, max_alpha=0.8):
    """Blend an inferno heat map of values (0..1, any size) over img (BGR,
    uint8) in place. Below `floor` nothing is drawn; strength (0..1) fades
    the whole overlay when there is little recent sound."""
    import cv2
    if strength <= 0.01:
        return img
    h, w = img.shape[:2]
    v = cv2.resize(values, (w, h), interpolation=cv2.INTER_LINEAR)
    a = np.clip((v - floor) / (1 - floor), 0, 1) * (max_alpha * min(strength, 1.0))
    heat = cv2.applyColorMap((np.clip(v, 0, 1) * 255).astype(np.uint8), cv2.COLORMAP_INFERNO)
    a3 = a[..., None]
    img[:] = (img.astype(np.float32) * (1 - a3) + heat.astype(np.float32) * a3).astype(np.uint8)
    return img
