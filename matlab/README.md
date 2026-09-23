# 🧮 MATLAB: offline analysis

Direction and distance of a sound source from **recorded** takes of the two
arrays. This is the reference implementation; the live tracker in
[`../INSTA360`](../INSTA360) is a validated port of it.

## Quick start

1. Put the recordings in **`<repo>/data/`** (or the repo root). The Zylia files
   must be converted with *ZYLIA Ambisonics Converter* to `…_(ACN-SN3D-3).wav`;
   the Zoom files are the H3-VR's own 4-ch AmbiX WAVs.
2. Open **`main_2mic.m`**, pick a take in section 1 (uncomment its block), and
   press **Run**.
3. Read the printed report and the three figures: per-frame estimates, polar
   power maps, and the fused position map.

Every script finds the code and the recordings by itself (`setup_paths.m`), so
it doesn't matter which folder MATLAB is in. No toolboxes beyond base MATLAB and
the Signal Processing Toolbox (`butter`, `filtfilt`, `hilbert`) are needed.

## Scripts: run these

| Script | What it does |
|---|---|
| **`main_2mic.m`** | **Start here.** Two recordings → azimuth, elevation and distance, with a trust verdict |
| `main_doa_estimation.m` | One array → direction (and the curvature-based distance attempt, kept as a negative result) |
| `test_all_takes.m` | Regression check after changing code: re-runs every take and prints one scoreboard |
| `check_recording.m` | Sanity-check an exported WAV (channel count, format, rough direction) before the full pipeline |
| `synthetic_test.m` | End-to-end check against a synthesised source at a known position |

## Functions: the building blocks

| Function | Role |
|---|---|
| `run_doa.m` | Validated steered-response-power (SRP) direction estimator, per frame |
| `az_power_map.m` | Accumulated azimuth power map for one array (what triangulation uses) |
| `triangulate.m` | Source position from two arrays, by multiplying their maps over a grid |
| `build_steering_matrix.m` | Spherical-harmonic steering vectors with frequency-dependent order |
| `real_sh_matrix.m`, `sph_hankel2.m` | Real ACN/N3D spherical harmonics, spherical Hankel functions |
| `convert_to_acn_n3d.m` | AmbiX / FuMa → ACN/N3D |
| `align_two_mics.m` | Puts two independently-started recorders on one clock |
| `check_mic_yaw.m` | Relative rotation between the arrays from a front + back take |
| `estimate_distance.m` | Curvature-based range from the raw 19-capsule file (**negative result**: unobservable at 1.5 m) |
| `floor_bounce_distance.m` | Range from the floor reflection (**negative result**: floor and ceiling echoes collide) |
| `setup_paths.m` | Adds the code and the recording folders to the path |

## `investigations/`

One-off studies, each named for the question it answers. They document how the
current method was reached. You don't need them to use the pipeline.

| File | Question |
|---|---|
| `test_angle_sweep.m` | How far off broadside does distance still work? |
| `test_side_takes.m` | Why are the ±90° takes wrong, and how to record them next time? |
| `test_level_ratio.m` | Can level differences measure distance along the baseline, where triangulation is blind? |
| `test_zoom_offset.m` | Why does the Zoom need ≈ +4.75° of yaw even when aimed straight? |
| `test_yaw_attribution.m` | Which mic turned? (limits of the front + back invariant) |
| `test_front_clap_window.m`, `test_clip_check.m`, `test_level_bias.m`, `test_drr_check.m` | Diagnosing the unresolved 11 Aug front-clap take |
| `test_voice_front.m`, `test_old_vs_new.m` | Did a code change alter an old result? (`triangulate_aug11.m` is the frozen old version) |

## Conventions

- **Azimuth:** degrees from the arrays' front (+x), **positive to the left**. **Elevation:** positive up.
- **Rig frame:** origin midway between the two mics; `LR` layout = Zylia at −y, Zoom at +y.
- **Distance** is reported from the midpoint of the two mics.
- Each take block in `main_2mic.m` carries its own ground truth, baseline, layout and yaw, because those belong to the recording session, not to the code.
