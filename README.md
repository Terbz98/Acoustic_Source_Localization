# Acoustic Source Localization with Spherical Microphone Arrays

Estimating **direction (azimuth + elevation) and distance** of a sound source in a
real room, in MATLAB, from spherical microphone array recordings.

Undergraduate research project — active, updated as work continues.

**Hardware:** Zylia ZM-1 (3rd-order ambisonics, 19 capsules) and Zoom H3-VR
(1st-order AmbiX).

---

## The short version

Direction works well from a single array. **Distance does not, and cannot** —
that turned out to be the central result rather than a bug to fix.

At 1.5 m, the only single-microphone cue for range is the curvature of the
wavefront, which across an 11 cm sphere amounts to roughly **0.5 mm** of extra
path. Nine successive methods were tried against it and all nine returned the
edge of the search grid — 3.00 m on every take regardless of the true distance,
and 10.0 m when the grid was widened to 10 m. The number was never a
measurement.

A quiet source nearby and a loud source far away produce nearly the same signal
at one microphone, and nothing in that recording breaks the tie. Breaking it
needs an external reference. Two were recordable here: **a second array at a
measured baseline**, and **the floor as a reflector**. Both were tested. The
second viewpoint works.

With a 1 m baseline, distance lands within **3–6% of a tape measure**.

## Results

Seven takes, three physical rig arrangements, source at 1.50 m.

| take | rig | azimuth | distance | vs truth | verdict |
|---|---|---|---|---|---|
| 11 Aug, front clap | side by side | −5.0° | 2.78 m | +85% | passed, wrong |
| 11 Aug, back clap | side by side | +0.7° | 1.56 m | +4% | trusted |
| 17 Aug, in front of Zylia | side by side | −0.7° | 1.52 m | −4% | trusted |
| 17 Aug, in front of Zoom | side by side | −2.7° | 1.62 m | +3% | trusted |
| 17 Aug, centre, elevated | side by side | −0.7° | 1.66 m | +6% | trusted |
| 17 Aug, left | front-back | +6.2° | 3.14 m | +109% | rejected |
| 17 Aug, right | front-back | +2.4° | 2.40 m | +60% | passed, wrong |

- **Azimuth is inside 6.2° on every take**, on all three rig arrangements,
  including the ones where distance failed.
- **Elevation works on the Zylia and not on the Zoom.** The elevated take reads
  +15.6° against roughly +16° measured three independent ways. At 1st order the
  vertical beam is too broad to beat the reverberant field, so the Zoom's
  vertical map peaks at exactly 0.0° on every take — it is measuring the room,
  not the source. This is an estimator limit, not broken hardware.
- **Distance splits on exactly one thing:** whether the relative yaw between the
  two arrays had been measured. Where it was known: −4, +3, +6, +4%. Where it
  was not: +60, +85, +109%. Same method, same geometry, one missing number.

## Method

**Direction.** Frequency-domain steered-response power over spherical-harmonic
steering vectors, on a rigid-sphere near-field model (spherical Hankel
functions). 1024-sample frames, 50% overlap at 48 kHz, 60 bins across the
analysis band, energy and SNR gating, clipped-frame rejection, parabolic peak
interpolation on the az/el grid.

**Frequency-dependent order.** A spherical array only carries usable order-*n*
information above its cut-on `f_n = n·c/(2πa)`. Below it, that order's channels
are self-noise and folding them into the SRP wrecks the estimate. Each frequency
bin now uses only the orders it can physically support. The original
800–4000 Hz band sat below the order-2 (~2.2 kHz) and order-3 (~3.3 kHz) cut-ons,
which left 11 of 16 channels as pure noise — this was the bug behind the early
3rd-order runs.

**Capsule radius.** Calibrated from the recordings rather than the datasheet.
GCC-PHAT arrival delays across all 19 capsules match the rigid-sphere model at
**r = 0.056 m with 0.99 correlation**; the 0.049 m value in the SPARTA/SAF preset
predicts delays 13–15% short. Correcting it improved azimuth RMSE on every take
(26.8→26.1, 31.9→23.4, 13.3→10.8°).

**Distance.** Not by crossing two peak bearings — two peaks each a few degrees
off put the answer metres away. Each array contributes its whole accumulated
power map, and the two are **multiplied across a grid of candidate source
positions**. A noisy frame widens the ridge instead of moving the answer. Each
frame's map is contrast-normalised so a loud syllable does not outvote a quiet
one, then weighted by how decisive that frame actually was.

**Where it stops working.** The angle the two arrays disagree by *is* the
distance information; there is nothing else. On a 1 m baseline that is 36.9° at
1.5 m, 18.9° at 3 m, 11.4° at 5 m. Hence `σ(r)/r ≈ (r/B)·σ(θ)`, and past
`r/B = 3` the two rays are too close to parallel for the answer to mean
anything. Unlike curvature there is no ceiling — only a baseline that has to
grow with the range.

**The dominant error term.** An unmeasured relative rotation between the two
arrays. A source truly at 1.50 m reports as 1.75 m through a 5° twist, 2.09 m
through 10°, 2.59 m through 15°, 3.37 m through 20°. The whole measurement is
only 36.9° wide, so 15° of unknown rotation throws away 40% of the signal.
`check_mic_yaw.m` recovers it from a front take and a back take alone, with no
ground truth.

**The floor-reflection alternative is closed**, by measurement rather than
assumption, and not for the expected reason. The floor is bare hardwood and
returns ~96% of the pressure — absorption was never the problem. The *ceiling*
echo lands 0.25 ms from the floor echo — 12 samples at 48 kHz, against a clap
roughly 3 ms long — and the two comb-filter into a blend with no fixed
direction. It is a microphone-height problem: the collision happens when the mic
sits at (ceiling − source height), which is about where a normal stand puts it.
Dropping the mic to 0.35 m separates the two arrivals by 4 ms.

## Repository layout

Analysis scripts, run one take at a time:

| file | what it does |
|---|---|
| `main_2mic.m` | **Start here.** Azimuth, elevation and distance from one pair of recordings |
| `main_doa_estimation.m` | Single-array version: direction, plus the curvature-based distance attempt |
| `run_doa.m` | The validated SRP direction estimator |
| `az_power_map.m` | Full accumulated azimuth power map for one array (what triangulation consumes) |
| `triangulate.m` | Source position from two arrays, by multiplying their power maps |
| `estimate_distance.m` | Curvature-based range from the raw 19-capsule file — kept as the negative result |
| `floor_bounce_distance.m` | Range from the floor reflection — also a negative result |
| `build_steering_matrix.m` | Spherical-harmonic steering vectors with frequency-dependent order |
| `real_sh_matrix.m`, `sph_hankel2.m`, `convert_to_acn_n3d.m` | Spherical harmonics, Hankel functions, A-format → ACN/SN3D |
| `align_two_mics.m` | Puts two independently-started recorders on one clock |
| `check_mic_yaw.m` | Measures the relative rotation between arrays, no ground truth needed |
| `check_recording.m` | Sanity-check any exported WAV before running the pipeline |
| `synthetic_test.m` | End-to-end check against a synthesised source at a known position |
| `test_all_takes.m` | Regression harness — reruns every take on record and prints one scoreboard |
| `test_*.m` | Individual investigations, each named for the question it answers |
| `triangulate_aug11.m` | Frozen 2026-08-11 copy, used only by `test_old_vs_new.m` |

Reports (`.pptx`): `DOA_Project_Presentation` (method), `DOA_Distance_Report`
(how distance was solved), `DOA_Limit_Tests` (five takes pushing it until it
breaks).

## Running it

MATLAB. Open `main_2mic.m`, edit section 1 to select a take — each take block
carries its own ground truth, baseline, rig layout and yaw, because those belong
to the recording session and not to the script — then Run. One take at a time.

The recordings are **not in this repository** (~4.6 GB of WAV, over GitHub's
per-file limit). Scripts expect them in the working directory.

## Recording protocol

Every item exists because something went wrong without it.

1. **Record a front take and a back take every setup.** `check_mic_yaw.m` gets
   the twist from those two alone. One extra minute, and it is the difference
   between 4% and 85%.
2. **Tape the floor and label which array is FRONT.** The two front-back
   arrangements give completely different distances and cannot be told apart
   from the audio afterwards.
3. **Never rebuild the rig mid-session without re-measuring.** The twist does not
   survive a teardown and nothing downstream can detect that it changed.
4. **Tape-measure the baseline.** Distance scales linearly with it and it cannot
   be recovered from the audio.
5. **Keep the source broadside, `r/B` under 3.** Grow the baseline with the
   distance you want to measure.
6. **Watch the H3-VR's input level** — it clipped on every clap in both sessions
   — and write down the mic, source and ceiling heights.

## Known limitations and open questions

- An unmeasured rotation between the arrays is **invisible to every guard**. It
  produces two perfectly self-consistent bearings that cross in the wrong place,
  and nothing in the audio contradicts them. "Trusted" means the geometry is
  self-consistent; it has never meant correct.
- The 11 Aug front clap take reads +85% and passes every check. Unresolved:
  two stories fit the recordings exactly and the audio cannot separate them.
- Elevation ground truth is inferred from audio, never checked against a ruler.
- Two arrays have one blind axis — the line through both of them, where a source
  gives both the identical bearing at every range. You choose where to point it.
  Covering front and side at once needs a third array off the line.
- Next: one session with a tape-measured baseline at three or four known
  distances, front/back pair at each. That turns correct answers into a
  calibration curve.

## In progress

Real-time operation: mapping per-frame direction estimates onto pan and tilt for
a mounted Insta360 camera, so capture follows the active sound source. Not yet
implemented.
