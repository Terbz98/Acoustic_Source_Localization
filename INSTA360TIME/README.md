# INSTA360TIME: live sound tracking → Insta360 X4

> **To use it: double-click `START_TRACKER.command`** (or run
> `.venv/bin/python live_tracker.py` in Terminal / VS Code: the `.command`
> file is only a shortcut for that line). A window opens on the Mac showing the
> X4's view turned toward whoever is making sound. Every separate sound (a
> clap, a word) gets one line with its az / el / distance, in the Terminal, in
> the window's LAST SOUNDS list, and in `logs/sounds_<date>.csv` (opens in
> Excel). Press Q to quit. The only file you edit is `rig_config.py`; the
> other `.py` files are parts of the program.

This is the live version of `main_2mic.m`. Both arrays record at the same
time, and az / el / distance are recomputed ten times a second. A virtual
camera cut out of the Insta360 X4's 360° video turns to face the sound, on
your Mac's screen.

```
Zylia ZM-1 (19 raw capsules) ──► SRP map ─┐
                                          ├─► fused over the room ─► az, el, r ─► reframe X4 panorama
Zoom H3-VR (4-ch AmbiX)      ──► SRP map ─┘      (triangulate.m)                  at that direction
          (both also saved to WAV with --record)
```

The X4 can't physically turn, and it doesn't need to because it already sees
all 360°. "Looking at the sound" means cutting a normal perspective view out
of the panorama, centred on the estimated direction. That's the same thing as
the Insta360 app's reframe, done live.

## Why Python and not MATLAB

MATLAB can do live audio (`audioDeviceReader`), but a live 19+4-channel
two-device loop with a webcam and a window needs the Audio Toolbox and the
webcam support package, and it's much slower. The Python port uses the same
equations as your MATLAB files, and it's validated against them (see below).
Your original MATLAB files are in `matlab_original/`, untouched.

| MATLAB (`matlab_original/`) | Python |
|---|---|
| `run_doa.m`, `az_power_map.m` | `doa_core.py`: `SrpArray`, `frame_weights_and_norm`, gates |
| `build_steering_matrix.m`, `real_sh_matrix.m`, `sph_hankel2.m`, `convert_to_acn_n3d.m` | `doa_core.py`: `sh_steering`, `real_sh_matrix`, `ambi_to_acn_n3d` |
| `estimate_distance.m` (`capsule_tf`, `zylia_geom`) | `doa_core.py`: `rigid_sphere_capsule_steering`, `ZYLIA_CAPS_AZEL` |
| `triangulate.m` (`fuse` + guards) | `fusion.py`: `Triangulator` |
| `main_2mic.m` section 1–2 (the take / the rig) | `rig_config.py` |
| `check_mic_yaw.m` | `live_tracker.py --calibrate` |

**The one real difference.** Offline, the Zylia went through ZYLIA Ambisonics
Converter first. Live, the driver hands over the 19 raw capsules, so the
Zylia is steered directly with the rigid-sphere capsule model from
`estimate_distance.m`: same sphere, same measured 0.056 m radius. A live check
confirmed that the ZM-1-3E's channel order matches that model. The fit on live
sound is 0.31 against 0.20 for an old known-good file, and 0.09 when the
channels are deliberately shuffled.

## Answers to the setup questions

- **H3-VR: AmbiX or FuMa?** **AmbiX.** Every recording in this project used
  it (the WAV iXML says `Rec Mode=AmbiX`), and it's the default here. FuMa also
  works if you set `ZOOM_FORMAT = 'fuma'`. Just make the setting and the
  recorder match. Don't use "Ambisonics A", because that's raw capsules.
- **Insta360 X4: webcam mode?** **Yes, use Webcam mode.** Plug in USB-C, and
  when the camera shows the USB-mode prompt, choose **Webcam**. The Mac then
  sees a normal camera giving a 2880×1440 360° panorama, and the program shows
  the reframed view on your Mac display.

## Every session: setting up the hardware

1. **Zylia ZM-1.** Plug it in. It shows up as a 20-channel input; only the
   first 19 are capsules. If it doesn't appear, approve the driver in **System
   Settings → General → Login Items & Extensions → Driver Extensions → ZYLIA
   ZM-1 Driver**. That's the setting you'd forgotten, and it's now on for this
   Mac.
2. **Zoom H3-VR.** Menu → **USB → Audio I/F → 4ch Ambisonics**. Then Menu →
   **Ambisonic Mode → AmbiX**. Keep **Mic Position** the same as in your
   earlier sessions. **Turn the input gain down**: it clipped on every clap in
   both old sessions, and clipped frames are thrown away.
3. **Insta360 X4.** Charge it first. Webcam mode drains it fast, so keep it on
   a charger if you can. Then plug in USB-C and choose **Webcam**.
4. **The rig.** This is the same as your MATLAB protocol, and every rule
   there still applies. Mics side by side (`LAYOUT = 'LR'`), **baseline
   tape-measured** (`BASELINE_M`), both fronts facing the same way. Put the X4
   where you like and enter where it is in `CAMERA_POS_M`, for example right
   between the mics: `(0, 0, 0)`.
5. **The first time only.** macOS asks whether Terminal (or VS Code) may use
   the **Microphone** and the **Camera**. Allow both.

## Running it

Open a terminal in this folder (or open the folder in VS Code and use the Run
panel, where every command below is already set up):

```bash
cd ~/Documents/專題/INSTA360TIME
```

```bash
.venv/bin/python live_tracker.py
```

That's the full thing: both mics plus the X4 view. Other ways to run it:

| command | what it does |
|---|---|
| `.venv/bin/python live_tracker.py --no-camera` | audio only, with the radar view |
| `.venv/bin/python live_tracker.py --record` | also saves both mics to `recordings/` |
| `.venv/bin/python live_tracker.py --zylia-only` | Zoom not connected: direction only, no distance |
| `.venv/bin/python live_tracker.py --headless` | no window, just prints |
| `.venv/bin/python live_tracker.py --udp 127.0.0.1:9870` | also sends each estimate as JSON (for MATLAB or another program) |
| `.venv/bin/python live_tracker.py --list-devices` | shows every audio device |
| `.venv/bin/python camera_view.py --test` | X4 only: drag the mouse to look around |

**Keys in the window:** `Q` quit · `R` start/stop recording · `C` clear
the maps · `-` `=` zoom out/in · `B` look out of the other side of the X4
(turn 180°) · `U` upside-down (if the X4 is mounted upside down).

All of these are done by this program on the Mac. The X4 always sends its
whole 360° picture, and the program chooses which part of it to show and how.
Nothing is changed on the camera itself.

**What's on screen:**

| where | what |
|---|---|
| top left | the X4 view, turned toward the sound (the green + is the centre) |
| top right | radar, seen from above with the front at the top: the two mics, their live direction maps and rays, the yellow heat where they agree, and the sound with its distance. Orange numbered dots are the last few separate sounds |
| bottom left | the whole 360° panorama: green circle = where the view is looking, red × = the latest sound |
| bottom right | all the numbers: the current sound (az / el / distance and how it was found), the view settings, the mic levels, the X4 status, the LAST SOUNDS list and the keys |

## Calibration (do this once per rig build)

### 1. Mic yaw

This is the number distance depends on. Stand on the rig's centre line at a
tape-measured distance, for example 1.5 m straight ahead, and talk or clap for
15 seconds:

```bash
.venv/bin/python live_tracker.py --calibrate 1.5 0
```

It prints `YAW_ZYLIA_DEG` and `YAW_ZOOM_DEG`. Paste them into
`rig_config.py`. The relative yaw (Zoom − Zylia) was +4.0 to +5.4° on every
2026-08 session. If you get something much bigger, a mic is turned. As
`main_2mic.m` warns, a yaw fitted at one spot makes that spot come out right
by construction. So check it at a different tape-measured position before you
trust a distance.

### 2. Camera direction

Run the tracker, then stand or clap in front of the rig. If the view shows the
wrong side, press `B`. If it's consistently off by some angle, set
`CAMERA_YAW_DEG` in `rig_config.py` (positive turns the view to the left). If
it turns the wrong way when you move, set `CAMERA_MIRROR = True`.

## How well it works

`validate_offline.py` runs your recorded takes through the exact live
estimator. Replaying them through `live_tracker.py --replay` gives the live
numbers: each value is the median of the ~10 Hz live updates.

| take (truth) | live az | live el | live r | MATLAB r |
|---|---|---|---|---|
| 11 Aug front voice (0°, 1.50 m) | −1.0° | −2.7° | 1.45 m | n/a |
| 11 Aug back clap (180°, 1.50 m) | −179.1° | +0.0° | 1.58 m | 1.56 m |
| in front of Zylia (−18.4°, 1.58 m) | −17.5° | +0.3° | 1.52 m | 1.52 m |
| in front of Zoom (+18.4°, 1.58 m) | +15.6° | −0.9° | 1.66 m | 1.62 m |
| centre, elevated (0°, el ≈ +17°, 1.57 m) | −0.9° | +21.7° | 1.76 m | 1.66 m |

Gross outliers (more than 30° off) are 0–2 per take, out of 40–180 updates.
The old ±90° takes and the unresolved 11 Aug front clap behave exactly as in
MATLAB: rejected, and +78% respectively. `validate_offline.py --sh` also runs
the converted ACN files through a straight port of `run_doa.m`. That port
reproduces your MATLAB numbers: for example, the elevated take gives az −0.7°,
el +15.6°, identical to MATLAB.

## Limits, the same physics as the MATLAB project

- **Distance needs the two viewpoints.** It's only reported when the fused
  answer passes the `triangulate.m` guards: the source must be broadside to the
  baseline and within r/B < 3. Otherwise the camera still turns to the right
  **direction** (the Zylia's bearing) and assumes `FALLBACK_DISTANCE_M`. The
  screen says "direction only" and gives the reason.
- **Elevation comes from the Zylia only.** The H3-VR's first-order elevation
  map reads 0° whatever the source does.
- **Delay:** about 0.2–0.6 s. That's `TAU_S` (the memory of the maps) plus
  `SMOOTH_S` (camera smoothing). Lower both for faster, jumpier tracking.
  Stray clicks don't move the camera, because `MIN_EVIDENCE` requires enough
  sound first.
- **Insta360 X4 webcam mode** is officially tested by Insta360 only with OBS,
  and it hasn't been tried with this code yet. If the image turns out to be two
  round fisheyes instead of one panorama, set
  `CAMERA_PROJECTION = 'dualfisheye'`.

## Files

| file | purpose |
|---|---|
| `live_tracker.py` | **start here:** live tracking, recording, calibration, replay |
| `rig_config.py` | every number you measure at the rig |
| `doa_core.py` | one array: steering, SRP maps, gates, accumulation |
| `fusion.py` | two arrays → position (`triangulate.m`) |
| `camera_view.py` | X4 capture and reframing |
| `validate_offline.py` | scoreboard against the recorded takes |
| `matlab_original/` | the MATLAB files this was ported from |

Recordings made with `--record` can go back into MATLAB. Open the
`*_zylia19.wav` in ZYLIA Ambisonics Converter to get the `_(ACN-SN3D-3).wav`,
then use it with the `*_zoom_ambix.wav` in `main_2mic.m` section 1.

To rebuild the Python environment on another Mac:

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
```
