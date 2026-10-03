"""
rig_config.py -- EVERYTHING YOU MEASURE AT THE RIG GOES HERE.

Same rule as main_2mic.m: these numbers belong to the SETUP, not to the code.
Re-measure them every time the rig is rebuilt. Command-line flags of
live_tracker.py override a few of them for a single run.

Rig frame (identical to main_2mic.m):
    origin  = midpoint between the two mics, at mic height
    +x      = forward, the direction both mics' fronts point
    +y      = LEFT (as seen from behind the rig, looking along +x)
    +z      = up
    azimuth = degrees from +x, POSITIVE TO THE LEFT
"""

# ======================= 1. AUDIO DEVICES ================================
# Matched as a substring of the device name (run:  live_tracker.py --list-devices)
ZYLIA_DEVICE = 'Zylia'
ZOOM_DEVICE = 'H3-VR'
SAMPLE_RATE = 48000

# H3-VR menu: USB > Audio I/F > "4ch Ambisonics", then Menu > Ambisonic Mode.
# Must match what the recorder is set to. 'ambix' is what every recording in
# this project used (the file iXML says "Rec Mode=AmbiX") and is the default.
# 'fuma' also works. NOT 'Ambisonics A' -- that is raw capsules.
ZOOM_FORMAT = 'ambix'

# False = Zylia only: direction still works, but distance does not (it needs
# the second viewpoint), so the camera assumes FALLBACK_DISTANCE_M.
USE_ZOOM = True


# ======================= 2. THE RIG (main_2mic.m section 2) ==============
# 'LR' side by side: Zylia at -y (the rig's RIGHT), Zoom at +y (its LEFT).
#      Stand in FRONT of the rig looking back at it and the Zylia is on YOUR
#      left. Sees sources in front well, blind along the line through the mics.
# 'FB' one behind the other, Zylia in front.   'BF' Zoom in front.
LAYOUT = 'LR'

# TAPE-MEASURE IT. Distance scales linearly with it.
BASELINE_M = 1.00

# How far each mic's own zero is rotated from the rig's +x: a mic reads
# (true bearing + yaw). Only YAW_ZOOM - YAW_ZYLIA matters for distance, and it
# matters a lot (5 deg of it = ~15% of range at 1.5 m). +4.75 is the standing
# Zoom offset found on every 2026-08 session (main_2mic.m section 2). Measure
# it for YOUR setup with:   live_tracker.py --calibrate 1.5 0
# (stand on the rig's centre line 1.5 m out and talk/clap for ~15 s).
YAW_ZYLIA_DEG = 0.0
YAW_ZOOM_DEG = 4.75


# ======================= 3. THE CAMERA ===================================
# Where the Insta360 X4 sits, in the rig frame, metres. (0, 0, 0) = exactly
# between the two mics at mic height. E.g. on a stand 0.3 m behind the mics
# and 0.2 m higher: (-0.3, 0.0, 0.2).
CAMERA_POS_M = (0.0, 0.0, 0.0)

# Which rig azimuth the CENTRE of the X4's panorama looks at. 0 = the same
# way as the mics. Which lens the webcam stream treats as "front" is not
# documented: run the tracker and clap in front of the rig. If the view shows
# the other side, press B (and put the value printed on quit here); if it is
# off by some angle, change this (positive turns the view to the left).
CAMERA_YAW_DEG = 0.0

# If the view pans the WRONG WAY (you move left, it turns right), set True.
CAMERA_MIRROR = False

# If the X4 is mounted upside down (the picture is upside down), set True
# (or press U live).
CAMERA_UPSIDE_DOWN = False

# What the webcam stream looks like. The X4 in Webcam mode at 2880x1440
# gives a stitched 2:1 panorama -> 'equirect'. If you see two round fisheye
# images side by side instead, use 'dualfisheye'.
CAMERA_PROJECTION = 'equirect'

# How late the X4's two streams are compared with real time. Its microphone
# is 0.49 s behind the Zylia on every stomp (measured, 28 Sep recording). Its
# picture is later still: 0.84 s, chosen by watching test clips of the
# 28 Sep recording side by side (sound 0.35 s after the X4 mic's own timing
# looked right; 0.25-0.30 looked a little early). Recorded videos get their
# sound placed this way, and the live 360 heat map waits this long so it
# lights up when the picture shows the sound. If speech looks late or early in
# a recorded video, nudge X4_PICTURE_DELAY_S and remake it.
X4_PICTURE_DELAY_S = 0.84
X4_AUDIO_DELAY_S = 0.49
CAMERA_NAME = 'Insta360'      # opened by name (part of it) through AVFoundation
CAMERA_INDEX = None           # set a number ONLY to force OpenCV capture by index
CAMERA_REQUEST_SIZE = (2880, 1440)
DUALFISHEYE_FOV_DEG = 200.0   # per lens, only for 'dualfisheye'

VIEW_FOV_DEG = 90.0           # horizontal field of view of the "look" window
VIEW_SIZE = (880, 495)         # window = view + radar side by side (fits a 13" screen unscaled)


# ======================= 4. TRACKING =====================================
# How long a frame's vote lasts. Short = follows a moving talker quickly but
# jitters; long = steady but lags. 0.6 s is a good start for speech.
TAU_S = 0.6

# If no frame passed the gates for this long, hold the last direction and say
# "listening".
HOLD_S = 1.0

# How much accumulated evidence (sum of the decaying frame weights of
# az_power_map.m) the Zylia needs before the camera is allowed to move. A lone
# click or a clap's reverberant tail gives ~1-2, a talker 5-50. Raise it if
# stray noises make the view jump; lower it (to ~1) to react to single claps.
MIN_EVIDENCE = 3.0

# Camera turn smoothing (seconds). Larger = calmer pans.
SMOOTH_S = 0.25

# When the distance is untrustworthy (or USE_ZOOM is False) the camera aims
# along the Zylia's bearing, assuming the source is this far away.
FALLBACK_DISTANCE_M = 2.0

# Gates of az_power_map.m: a frame must be within ENERGY_GATE_DB of the loud
# level AND at least SNR_GATE_DB over the room's noise floor.
ENERGY_GATE_DB = -25
SNR_GATE_DB = 10
