"""
camera_view.py -- the Insta360 X4 as a USB webcam, and a virtual camera that
"looks" wherever the sound is.

The X4 cannot physically turn, and it does not need to: it already sees all
360 degrees. So "point the camera at the sound" means REFRAMING -- cutting a
normal perspective view out of the panorama, centred on the estimated
direction. That is what the Insta360 app's reframe does in post; here it is
done live from the webcam stream.

Put the X4 in Webcam mode: plug in USB-C, and on the camera's screen choose
"Webcam" in the USB-mode prompt. It then appears to the Mac as a UVC camera
offering 1920x1080 and 2880x1440 (the 2:1 panorama), both 30 fps.

WHY NOT PLAIN OPENCV FOR CAPTURE: on macOS, cv2.VideoCapture cannot choose a
camera's format -- it takes the default (1920x1080 on the X4) and rescales, and
its index order does not reliably match the device list. So the X4 is opened
by NAME through AVFoundation (pyobjc) with the 2880x1440 format selected
explicitly. OpenCV is still used for everything after the frame arrives.

Run these from the macOS Terminal app (it needs Camera permission):
    .venv/bin/python camera_view.py --list                  # cameras and their formats
    .venv/bin/python camera_view.py --list --save x4.jpg    # also save one X4 frame
    .venv/bin/python camera_view.py --test                  # show it, drag to look around
"""

from __future__ import annotations

import use_project_python  # noqa: F401  (restarts on .venv/bin/python if needed)

import argparse
import threading
import time

import cv2
import numpy as np


# ======================= capture: AVFoundation ===========================
def _avf():
    import AVFoundation as AV
    import CoreMedia as CM
    return AV, CM


def list_avf_cameras():
    """[(name, [(w, h, max_fps), ...], active (w, h))] for every video device.
    Listing needs no camera permission."""
    AV, CM = _avf()
    kinds = [getattr(AV, t) for t in ('AVCaptureDeviceTypeExternal',
                                      'AVCaptureDeviceTypeExternalUnknown',
                                      'AVCaptureDeviceTypeBuiltInWideAngleCamera',
                                      'AVCaptureDeviceTypeContinuityCamera')
             if hasattr(AV, t)]
    ds = AV.AVCaptureDeviceDiscoverySession.discoverySessionWithDeviceTypes_mediaType_position_(
        kinds, AV.AVMediaTypeVideo, AV.AVCaptureDevicePositionUnspecified)
    out = []
    for d in ds.devices():
        fmts = []
        for f in d.formats():
            dim = CM.CMVideoFormatDescriptionGetDimensions(f.formatDescription())
            fps = max((r.maxFrameRate() for r in f.videoSupportedFrameRateRanges()), default=0)
            if (dim.width, dim.height, round(fps)) not in [(a, b, round(c)) for a, b, c in fmts]:
                fmts.append((dim.width, dim.height, fps))
        a = CM.CMVideoFormatDescriptionGetDimensions(d.activeFormat().formatDescription())
        out.append((d, str(d.localizedName()), fmts, (a.width, a.height)))
    return out


def camera_permission(wait_s=30):
    """Ask for (and wait for) camera permission. True if granted."""
    AV, _ = _avf()
    st = AV.AVCaptureDevice.authorizationStatusForMediaType_(AV.AVMediaTypeVideo)
    if st == 3:                                   # authorized
        return True
    if st in (1, 2):                              # restricted / denied
        print('Camera access is DENIED for the app running this script. Turn it on in '
              'System Settings > Privacy & Security > Camera (Terminal / VS Code), '
              'then quit and reopen that app.')
        return False
    done = threading.Event()
    res = {}

    def handler(granted):
        res['ok'] = bool(granted)
        done.set()

    print('>>> If a pop-up asks to let this app use the CAMERA, click OK/Allow.', flush=True)
    AV.AVCaptureDevice.requestAccessForMediaType_completionHandler_(AV.AVMediaTypeVideo, handler)
    t0 = time.time()
    while not done.is_set() and time.time() - t0 < wait_s:
        time.sleep(0.1)
    if not res.get('ok'):
        print('No camera permission. If no pop-up appeared, this app cannot ask for it '
              '(Claude cannot) -- run from the macOS Terminal app instead.')
    return bool(res.get('ok'))


_SINK = None


def _sink_class():
    """The frame-receiving delegate. An Objective-C class can only be defined
    ONCE per process, so it is made here once and reused by every AVFCamera
    (reconnecting the X4 creates a new AVFCamera)."""
    global _SINK
    if _SINK is not None:
        return _SINK
    import Quartz
    from Foundation import NSObject
    _, CM = _avf()

    class X4FrameSink(NSObject):
        def captureOutput_didOutputSampleBuffer_fromConnection_(self, out, sbuf, conn):
            owner = getattr(self, 'owner', None)
            pb = CM.CMSampleBufferGetImageBuffer(sbuf)
            if owner is None or pb is None:
                return
            Quartz.CVPixelBufferLockBaseAddress(pb, 1)
            try:
                h = Quartz.CVPixelBufferGetHeight(pb)
                w = Quartz.CVPixelBufferGetWidth(pb)
                bpr = Quartz.CVPixelBufferGetBytesPerRow(pb)
                buf = Quartz.CVPixelBufferGetBaseAddress(pb).as_buffer(bpr * h)
                img = np.frombuffer(buf, np.uint8).reshape(h, bpr // 4, 4)[:, :w, :3].copy()
            finally:
                Quartz.CVPixelBufferUnlockBaseAddress(pb, 1)
            with owner._lock:
                owner.frame = img
                owner.t_frame = time.time()
            owner._n += 1
            now = time.time()
            if now - owner._t0 > 1.0:
                owner.fps = owner._n / (now - owner._t0)
                owner._n, owner._t0 = 0, now

    _SINK = X4FrameSink
    return _SINK


class AVFCamera:
    """Opens a camera by (part of) its name with a chosen resolution and keeps
    the newest frame (BGR numpy) ready. Same interface as CameraThread:
    latest(), fps, close()."""

    def __init__(self, name='Insta360', size=(2880, 1440)):
        import Quartz
        import libdispatch
        AV, CM = _avf()
        if not camera_permission():
            raise RuntimeError('no camera permission')
        dev = next((d for d, n, _, _ in list_avf_cameras() if name.lower() in n.lower()), None)
        if dev is None:
            raise RuntimeError(f'no camera named "{name}" -- is the X4 on and in Webcam mode?')
        self.name = str(dev.localizedName())
        fmt = None
        for f in dev.formats():
            dim = CM.CMVideoFormatDescriptionGetDimensions(f.formatDescription())
            if (dim.width, dim.height) == tuple(size):
                fmt = f
        if fmt is None:
            raise RuntimeError(f'{self.name} does not offer {size[0]}x{size[1]}')

        self.frame = None
        self.t_frame = 0.0
        self.fps = 0.0
        self._n, self._t0 = 0, time.time()
        self._lock = threading.Lock()
        self._sink = _sink_class().alloc().init()
        self._sink.owner = self
        s = AV.AVCaptureSession.alloc().init()
        # On macOS a session re-applies its preset (-> the camera's default
        # 1920x1080) when it starts, and InputPriority is not supported. The
        # documented way round it: set the format with the device LOCKED and
        # keep it locked until the session is running. Verified on the X4.
        ok, err = dev.lockForConfiguration_(None)
        if not ok:
            raise RuntimeError(f'cannot configure {self.name}: {err}')
        dev.setActiveFormat_(fmt)
        inp, err = AV.AVCaptureDeviceInput.deviceInputWithDevice_error_(dev, None)
        if inp is None:
            dev.unlockForConfiguration()
            raise RuntimeError(f'cannot open {self.name}: {err}')
        s.addInput_(inp)
        out = AV.AVCaptureVideoDataOutput.alloc().init()
        out.setVideoSettings_({Quartz.kCVPixelBufferPixelFormatTypeKey:
                               Quartz.kCVPixelFormatType_32BGRA})
        out.setAlwaysDiscardsLateVideoFrames_(True)
        self._queue = libdispatch.dispatch_queue_create(b'x4.frames', None)
        out.setSampleBufferDelegate_queue_(self._sink, self._queue)
        s.addOutput_(out)
        s.startRunning()
        dev.unlockForConfiguration()
        if self._active(dev, CM) != tuple(size):      # belt and braces: set it again live
            dev.lockForConfiguration_(None)
            dev.setActiveFormat_(fmt)
            dev.unlockForConfiguration()
        self._session, self._out, self._dev = s, out, dev

    @staticmethod
    def _active(dev, CM):
        d = CM.CMVideoFormatDescriptionGetDimensions(dev.activeFormat().formatDescription())
        return (d.width, d.height)

    def latest(self):
        with self._lock:
            return self.frame

    def close(self):
        self._session.stopRunning()
        self._sink.owner = None


def open_panorama_camera(name='Insta360', size=(2880, 1440), index=None):
    """The X4 by name through AVFoundation; OpenCV by index only if asked."""
    if index is not None:
        return CameraThread(index, size)
    return AVFCamera(name, size)


class AutoCamera:
    """The X4, kept alive. Opens it in the background and re-opens it whenever
    it disappears or stops sending frames (the X4 sleeps, powers off, or is
    re-plugged), so the tracker never has to be restarted for the camera.
    `status` says what is going on, for the window."""

    RETRY_S = 3.0
    STALE_S = 3.0

    def __init__(self, name='Insta360', size=(2880, 1440), index=None):
        self.name, self.size, self.index = name, size, index
        self.cam = None
        self.status = 'looking for the X4...'
        self.fps = 0.0
        self._stop = threading.Event()
        self._th = threading.Thread(target=self._run, daemon=True)
        self._th.start()

    def _run(self):
        denied = False
        while not self._stop.is_set():
            if self.cam is None:
                try:
                    self.cam = open_panorama_camera(self.name, self.size, self.index)
                    self.status = f'connected ({self.size[0]}x{self.size[1]})'
                    self._opened = time.time()
                except Exception as e:
                    msg = str(e)
                    denied = 'permission' in msg
                    self.status = ('no camera permission -- run from the Terminal app / '
                                   'allow Camera in Privacy & Security') if denied else \
                        f'X4 not found -- is it on and in Webcam mode? (retrying)'
                    self._stop.wait(30.0 if denied else self.RETRY_S)
                    continue
            else:
                t_last = getattr(self.cam, 't_frame', time.time())
                ref = max(t_last, getattr(self, '_opened', 0.0))
                if time.time() - ref > self.STALE_S:
                    self.status = 'X4 stopped sending pictures -- reconnecting...'
                    try:
                        self.cam.close()
                    except Exception:
                        pass
                    self.cam = None
                    continue
                self.fps = getattr(self.cam, 'fps', 0.0)
            self._stop.wait(0.5)

    def latest(self):
        c = self.cam
        if c is None:
            return None
        if time.time() - max(getattr(c, 't_frame', time.time()), getattr(self, '_opened', 0)) > self.STALE_S:
            return None
        return c.latest()

    def close(self):
        self._stop.set()
        if self.cam is not None:
            try:
                self.cam.close()
            except Exception:
                pass


# ======================= capture: OpenCV by index (fallback) =============
class CameraThread:
    """OpenCV capture by index. Only used with an explicit --camera-index:
    on macOS it cannot pick the camera's format (see the header)."""

    def __init__(self, index, size=(2880, 1440)):
        self.cap = cv2.VideoCapture(index, cv2.CAP_AVFOUNDATION)
        if not self.cap.isOpened():
            raise RuntimeError(f'could not open camera index {index}')
        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, size[0])
        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, size[1])
        self.frame = None
        self.fps = 0.0
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._th = threading.Thread(target=self._run, daemon=True)
        self._th.start()

    def _run(self):
        n, t0 = 0, time.time()
        while not self._stop.is_set():
            ok, fr = self.cap.read()
            if not ok:
                time.sleep(0.01)
                continue
            with self._lock:
                self.frame = fr
                self.t_frame = time.time()
            n += 1
            if time.time() - t0 > 1.0:
                self.fps, n, t0 = n / (time.time() - t0), 0, time.time()

    def latest(self):
        with self._lock:
            return self.frame

    def close(self):
        self._stop.set()
        self._th.join(timeout=1.0)
        self.cap.release()


class StillCamera:
    """Stands in for the X4 with an image or video file -- for testing the
    whole display without the camera attached."""

    def __init__(self, path):
        self.cap = cv2.VideoCapture(path)
        ok, self.frame = self.cap.read()
        if not ok:
            raise RuntimeError(f'cannot read {path}')
        self.fps = 0.0

    def latest(self):
        ok, fr = self.cap.read()
        if ok:
            self.frame = fr
        else:
            self.cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
        return self.frame

    def close(self):
        self.cap.release()


# ======================= reframing =======================================
class Reframer:
    """Perspective view of a 360 frame, looking at (az, el).

    Angles follow the rig convention: az degrees, positive to the LEFT, el
    positive up. `yaw` is the rig azimuth at the centre of the panorama
    (CAMERA_YAW_DEG); `mirror` flips the panorama's left/right."""

    def __init__(self, out_size=(960, 540), hfov_deg=90.0, projection='equirect',
                 fisheye_fov_deg=200.0):
        self.projection = projection
        self.fisheye_fov = np.radians(fisheye_fov_deg)
        self.set_view(out_size, hfov_deg)

    def set_view(self, out_size, hfov_deg):
        self.W, self.H = out_size
        self.hfov = hfov_deg
        f = (self.W / 2) / np.tan(np.radians(hfov_deg) / 2)
        u, v = np.meshgrid(np.arange(self.W) + 0.5, np.arange(self.H) + 0.5)
        # camera-frame rays: x forward, y LEFT (so screen-right is -y), z up
        rays = np.stack([np.full_like(u, f), -(u - self.W / 2), -(v - self.H / 2)], -1)
        self.rays = (rays / np.linalg.norm(rays, axis=-1, keepdims=True)).reshape(-1, 3).astype(np.float32)

    def maps(self, az_deg, el_deg, src_w, src_h, yaw_deg=0.0, mirror=False, upside_down=False):
        a, e = np.radians(az_deg - yaw_deg), np.radians(el_deg)
        Ry = np.array([[np.cos(e), 0, -np.sin(e)], [0, 1, 0], [np.sin(e), 0, np.cos(e)]])
        Rz = np.array([[np.cos(a), -np.sin(a), 0], [np.sin(a), np.cos(a), 0], [0, 0, 1]])
        with np.errstate(divide='ignore', over='ignore', invalid='ignore'):  # numpy/Accelerate false alarms
            d = self.rays @ (Rz @ Ry).T.astype(np.float32)      # N x 3, panorama frame
        dx, dy, dz = d[:, 0], d[:, 1], d[:, 2]
        if mirror:
            dy = -dy
        if upside_down:                  # camera mounted upside down: 180 deg about its front axis
            dy, dz = -dy, -dz
        if self.projection == 'equirect':
            lon = np.arctan2(dy, dx)                              # + = left
            lat = np.arcsin(np.clip(dz, -1, 1))
            mx = (0.5 - lon / (2 * np.pi)) * src_w
            my = (0.5 - lat / np.pi) * src_h
        else:
            mx, my = self._dual_fisheye(dx, dy, dz, src_w, src_h)
        return (mx.reshape(self.H, self.W).astype(np.float32),
                my.reshape(self.H, self.W).astype(np.float32))

    def _dual_fisheye(self, dx, dy, dz, W, H):
        """Two equidistant fisheyes side by side: left half looks along +x,
        right half along -x. A hard seam at the sides -- good enough to aim."""
        R = min(W / 2, H) / 2
        front = dx >= 0
        s = np.sqrt(dy ** 2 + dz ** 2) + 1e-9
        theta = np.where(front, np.arccos(np.clip(dx, -1, 1)), np.arccos(np.clip(-dx, -1, 1)))
        r = theta / (self.fisheye_fov / 2) * R
        right = np.where(front, -dy, dy) / s                      # screen-right component
        cx = np.where(front, W / 4, 3 * W / 4)
        return cx + r * right, H / 2 - r * dz / s

    def render(self, frame, az_deg, el_deg, yaw_deg=0.0, mirror=False, upside_down=False):
        h, w = frame.shape[:2]
        mx, my = self.maps(az_deg, el_deg, w, h, yaw_deg, mirror, upside_down)
        border = cv2.BORDER_WRAP if self.projection == 'equirect' else cv2.BORDER_CONSTANT
        return cv2.remap(frame, mx, my, cv2.INTER_LINEAR, borderMode=border)


def panorama_xy(az_deg, el_deg, w, h, yaw_deg=0.0, mirror=False):
    """Where a rig direction lands on the equirect panorama (for the marker)."""
    lon = np.radians(az_deg - yaw_deg) * (-1 if mirror else 1)
    lon = (lon + np.pi) % (2 * np.pi) - np.pi
    return int((0.5 - lon / (2 * np.pi)) * w), int((0.5 - np.radians(el_deg) / np.pi) * h)


# ======================= stand-alone test ================================
def _wait_first_frame(cam, timeout=8.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        fr = cam.latest()
        if fr is not None:
            return fr
        time.sleep(0.05)
    return None


def _test(index, projection):
    cam = open_panorama_camera(index=index)
    fr = _wait_first_frame(cam)
    if fr is None:
        print('Camera opened but sent no frames.')
        cam.close()
        return
    print(f'Receiving {fr.shape[1]}x{fr.shape[0]}. Drag to look around, Q to quit.')
    rf = Reframer(projection=projection)
    view = {'az': 0.0, 'el': 0.0, 'drag': None}

    def on_mouse(ev, x, y, flags, _):
        if ev == cv2.EVENT_LBUTTONDOWN:
            view['drag'] = (x, y, view['az'], view['el'])
        elif ev == cv2.EVENT_MOUSEMOVE and view['drag']:
            x0, y0, a0, e0 = view['drag']
            view['az'] = a0 + (x - x0) * 0.15
            view['el'] = float(np.clip(e0 + (y - y0) * 0.15, -89, 89))
        elif ev == cv2.EVENT_LBUTTONUP:
            view['drag'] = None

    cv2.namedWindow('X4 test')
    cv2.setMouseCallback('X4 test', on_mouse)
    while True:
        fr = cam.latest()
        out = rf.render(fr, view['az'], view['el'])
        pano = cv2.resize(fr, (960, 480))
        px, py = panorama_xy(view['az'], view['el'], 960, 480)
        cv2.circle(pano, (px, py), 12, (0, 0, 255), 2)
        cv2.putText(out, f"az {view['az']:+.0f}  el {view['el']:+.0f}   {cam.fps:.0f} fps   "
                         f"source {fr.shape[1]}x{fr.shape[0]}", (12, 28),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 2)
        cv2.imshow('X4 test', np.vstack([out, pano]))
        if cv2.waitKey(1) & 0xFF in (ord('q'), 27):
            break
    cam.close()
    cv2.destroyAllWindows()


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--list', action='store_true', help='list cameras and their formats')
    ap.add_argument('--save', default=None, metavar='FILE.jpg',
                    help='with --list: also save one frame from the X4')
    ap.add_argument('--test', action='store_true', help='show the X4, drag to look around')
    ap.add_argument('--index', type=int, default=None, help='use OpenCV camera index instead (fallback)')
    ap.add_argument('--projection', default='equirect', choices=['equirect', 'dualfisheye'])
    a = ap.parse_args()
    if a.list:
        for _, name, fmts, active in list_avf_cameras():
            fs = ', '.join(f'{w}x{h}@{fps:.0f}' for w, h, fps in fmts)
            tag = '   <- 360 panorama available' if any(abs(w / h - 2) < 0.01 for w, h, _ in fmts) else ''
            print(f'{name}: {fs}{tag}')
        if a.save:
            cam = open_panorama_camera(index=a.index)
            fr = _wait_first_frame(cam)
            time.sleep(1.0)                          # let exposure settle
            fr = cam.latest() if cam.latest() is not None else fr
            cam.close()
            if fr is None:
                print('The camera opened but sent no frames.')
            else:
                cv2.imwrite(a.save, fr)
                print(f'saved a {fr.shape[1]}x{fr.shape[0]} frame to {a.save}')
    else:
        _test(a.index, a.projection)
