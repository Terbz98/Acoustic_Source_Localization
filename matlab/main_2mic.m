clear; clc; close all;
addpath(fileparts(mfilename('fullpath'))); setup_paths;   % code + recordings on the path

% ======================================================================
% TWO-MICROPHONE MAIN SCRIPT -- run this one.
%
% Gives AZIMUTH, ELEVATION and DISTANCE from one pair of recordings.
%
%   azimuth + elevation  <-  run_doa.m on each mic  (the validated path,
%                            completely unchanged)
%   distance             <-  triangulate.m, where the two bearings cross
%
% Distance comes from the two mic POSITIONS, not from wavefront curvature.
% That is the whole point. Curvature at 1.5 m is 1 mm of bulge across the
% 11 cm sphere and rails to the edge of any search grid; two viewpoints 1 m
% apart give a 33 degree parallax that is easy to measure. Every curvature
% attempt returned a meaningless 3.00 m; this returns 1.3-1.7 m against a
% 1.50 m truth.
%
% HOW TO USE THIS FILE: edit section 1 to pick ONE take, press Run, read the
% report and the three figures. One take at a time -- that has not changed and
% is not going to. Each take block carries its own gtR/yawB/layout, so picking
% a take means uncommenting its block and commenting out the old one.
%
% For a SINGLE-mic take (macfront, linux, ...) use main_doa_estimation.m.
% For the floor-reflection method, call floor_bounce_distance.m directly.
% test_all_takes.m is NOT an alternative to this file -- it is a regression
% check that reruns every take after you change code, and prints a table with
% no figures. If you are analysing a recording, you want THIS script.
% ======================================================================


%% ==================== 1. THE TAKE  (edit these) ======================
% The two files must be the same event recorded at the same time. The Zylia
% one is the 16-channel CONVERTED file; the Zoom one is the 4-channel AmbiX
% file straight off the H3-VR.

% yawB BELONGS TO THE TAKE, NOT TO THE SCRIPT. It is the relative rotation of
% the two mics at the moment that take was recorded, so it changes every time
% the rig is set up again and a value measured on one session says nothing about
% another. Each block below carries its own, and section 2 just reads it.
%
% The 2026-08-11 session recorded the front position TWICE: once with speech
% only (2miczyliafront + 2miczoomfront) and once with claps and speech
% (2micclapzyliafront + 2micclapzoomfront). They are different takes and they
% do not agree. The VOICE pair is the good one and is the default below.

zyliaFile = '2miczyliafront_(ACN-SN3D-3).wav';
zoomFile  = '2miczoomfront.WAV';
gtAzDeg   = 0;         % where the source really was: 0 = front, 180 = behind
gtElDeg   = 0;         % 0 = same height as the mics
gtR       = 1.50;      % metres from the MIDPOINT between the two mics
yawB      = 0;      % 2026-08-11 session
layout    = 'LR';      % how the two mics STOOD -- see section 2

% -- the other takes. To use one, comment out the block above and uncomment a
% -- block below. Keep yawB with its own take.

% ---- 2026-08-11 session, yawB = 4.75 from check_mic_yaw on the front/back pair
% zyliaFile = '2micclapzyliaback_(ACN-SN3D-3).wav';
% zoomFile  = '2micclapzoomback.WAV';
% gtAzDeg   = 180;  gtElDeg = 0;  gtR = 1.50;  yawB = 4.75;  layout = 'LR';

% ---- 2026-08-11 front CLAP pair. UNRESOLVED, and honestly so. At the
% ---- session's yaw it reads 2.77 m where 1.50 m was expected. Two stories fit
% ---- the recordings EXACTLY and the audio cannot separate them. Kept at the
% ---- session yaw because the user is confident the mics did not move.
% zyliaFile = '2micclapzyliafront_(ACN-SN3D-3).wav';
% zoomFile  = '2micclapzoomfront.WAV';
% gtAzDeg   = 0;  gtElDeg = 0;  gtR = 1.50;  yawB = 4.75;  layout = 'LR';
%
% THE TWO STORIES.
%   A. The mics did not move (yawB = 4.75, as the rest of the session) and the
%      SOURCE was somewhere else for this take. Solving the two bearings puts it
%      at (2.63, -0.25) -- 2.64 m out and 0.25 m off the centre line. Then the
%      reported 2.77 m is CORRECT and the 1.50 m gtR above is the wrong number.
%   B. The source was at 1.50 m and the RIG turned, by about 20 deg of relative
%      yaw. At yawB = 20.52 the take reads 1.45 m, -4%.
% Both reproduce the measured bearings to the decimal. Only the person who was
% in the room can say which. THE QUESTION TO ANSWER IS: for the clap take, did
% you stand where you stood for the voice take, or further back?
%
% WHY THE FRONT/BACK SUM DOES NOT SETTLE IT -- and this is a real limitation of
% check_mic_yaw.m, see the note added to its header. That test wants front + back
% azimuth to sum to +-180, and its docstring claims distance cancels out. It only
% cancels if the front and back source positions are MIRRORED about the rig, i.e.
% the same distance either side. In general
%       sum = 180 + atan(B/2 d_front) - atan(B/2 d_back)
% This take measures 169.28. A 20 deg rotation gives that. So does zero rotation
% with the source at 4.03 m. The test cannot tell a turned mic from an unequal
% pair of distances, so it CANNOT be used to argue story B over story A.
%
% WHAT IS SETTLED, and it took three wrong turns to get here:
%   - the code is not involved. The 2026-08-11 triangulate.m was recovered from
%     the D:\zhuanti\zhuanti snapshot and run beside today's: identical to four
%     decimals on all three takes, and everything upstream is md5-identical.
%     This take read 2.77 m on the day it was recorded. Run test_old_vs_new.m.
%   - the RECORDING is not damaged, which was my own wrong theory earlier today.
%     Its Zylia bearing is stable across level (3.3 deg on the 222 quietest
%     frames, 6.1 on the next 184, MAD 5) and across time (7.0, 7.2, 4.2, 4.1,
%     6.1 over five bands). A distorted or clipped bearing moves with level.
%     This one does not -- the take consistently and repeatably sees 5 deg where
%     the voice take consistently sees 16.9. Run test_level_bias.m.
%   - the clipping is real but is NOT the cause: 12937 Zoom samples at full
%     scale, five times the back clap take. Worth fixing at the rig anyway.
%     Run test_clip_check.m.
%   - no analysis window changes the answer: clap only, speech only, early, late
%     and whole-file all land 2.2-3.0 m. Run test_front_clap_window.m.
%   - direct-to-reverberant ratio LEANS toward story B: it uses no bearings and
%     is immune to gain, and it puts this source no further than the back clap
%     take. Treat that as a lean and not a verdict -- DRR assumes a uniform
%     reverberant field, and at 1.5-2.6 m in this small untreated room the
%     200 ms window is early reflections, which change completely when the
%     source moves. This is the same room physics that closed the floor-bounce
%     method (see floor_bounce_distance.m). Run test_drr_check.m.
%
% GATING NOTE, worth knowing before running any of this by hand: run_doa gates
% at energyGateDb below the LOUDEST frame. On a clap take the clap is ~40 dB
% above the speech, so a -25 dB gate keeps 47 frames of clap and reverberant
% tail and throws all the speech away -- and reverberant tails point nowhere
% (MAD 77-108 deg). main_2mic does not have this problem: az_power_map gates
% against the 95th percentile and main_2mic feeds that back in as
% gateRelMaxDb, which is why the tables here show 528 frames, not 47.
%
% ONE THING THIS TAKE DID SETTLE, whichever story is true. At yawB = 0 it read
% 3.75 m and SELF-REJECTED on r/B > 3 -- that is what the 2026-08-12 deck shows,
% correctly labelled. Applying the session's +4.75 pulled it to 2.77 m, under the
% limit, so it started PASSING. The yaw did not make it right, it made it look
% acceptable. A guard that a wrong number escapes by getting less wrong is not a
% guard, which is why r/B is printed beside the broadside angle and neither is
% called a verdict.

% ---- 2026-08-17 limit tests. Source 1.50 m away in every one, and yawB = 5.40
% ---- for all five (see section 2). Note gtR is measured from the MIDPOINT, so
% ---- standing 1.50 m in front of one MIC is hypot(1.50,0.50) = 1.58 m from the
% ---- midpoint, at +-18.43 deg.

% directly in front of the ZYLIA (-y side).  RESULT: az err 0.0 deg, r 1.44 m
% zyliaFile = '2micdirectfrontzylia1_(ACN-SN3D-3).wav';
% zoomFile  = '2micdirectfrontzoom1.WAV';
% gtAzDeg   = -18.43;  gtElDeg = 0;  gtR = 1.5811;  yawB = 5.40;  layout = 'LR';

% directly in front of the ZOOM (+y side).   RESULT: az err 0.0 deg, r 1.52 m
% zyliaFile = '2micdirectfrontzylia2_(ACN-SN3D-3).wav';
% zoomFile  = '2micdirectfrontzoom2.WAV';
% gtAzDeg   = +18.43;  gtElDeg = 0;  gtR = 1.5811;  yawB = 5.40;  layout = 'LR';

% centre line, clapped above head height.    RESULT: az err 1.4 deg, r 1.57 m
% gtElDeg below is NOT tape-measured -- it is what the Zylia map and direct-path
% pseudo-intensity on both mics agree on (+15..+17). Replace it if you measure
% the real clap and mic heights; +16.9 deg at 1.5 m means 0.46 m above the mic.
% zyliaFile = '2micfrontelzylia_(ACN-SN3D-3).wav';
% zoomFile  = '2micfrontelzoom.WAV';
% gtAzDeg   = 0;  gtElDeg = 16.9;  gtR = 1.568;  yawB = 5.40;  layout = 'LR';

% LEFT take. The rig for this one was FRONT-BACK, not side by side: the ZYLIA
% stood in front facing the wall, the ZOOM behind it, both looking the same way
% (a rear mic "facing the Zylia" is facing the wall too), with the source off to
% the left. That puts the source exactly BROADSIDE, 0 deg off, which is the
% IDEAL geometry -- not the blind axis. An earlier version of this comment said
% the opposite and assumed 'LR'; it was wrong. Corrected 2026-08-18.
% The layout is confirmed by the bearings themselves, with no ground truth: on
% a front-back rig the FRONT mic must read |az| > 90 and the BACK mic |az| < 90.
% Zylia reads 105.0 (front), Zoom reads 87.0 (back). Matches.
% zyliaFile = '2micleftzylia_(ACN-SN3D-3).wav';
% zoomFile  = '2micleftzoom.WAV';
% gtAzDeg   = +90;  gtElDeg = 0;  gtR = 1.50;  yawB = 0;  layout = 'FB';

% RIGHT take. Same idea but the rig was REBUILT WITH THE MICS SWAPPED -- ZOOM
% in front facing the wall, ZYLIA behind. Hence 'BF', and hence its own yaw: a
% rig taken apart and rebuilt keeps nothing from the previous setup. Bearings
% agree again: Zoom -99.0 (|az| > 90, front), Zylia -76.0 (|az| < 90, back).
% zyliaFile = '2micrightzylia_(ACN-SN3D-3).wav';
% zoomFile  = '2micrightzoom.WAV';
% gtAzDeg   = -90;  gtElDeg = 0;  gtR = 1.50;  yawB = 0;  layout = 'BF';

% WHAT IS STILL WRONG WITH THOSE TWO, AND IT IS NOT THE GEOMETRY.
% With the layouts above both takes are broadside, both sets of rays cross in
% front of both mics, and every guard passes. The AZIMUTH is fine -- the Zylia
% is within 3.4 and 4.4 deg. Only the DISTANCE is bad, and it is bad for one
% reason: the relative YAW was never measured for either setup, and the rig was
% rebuilt between them so nothing carries over.
%
% 2026-08-21: rerun with the aligned-overlap + map-peak method (the two fixes
% from 2026-08-20). The old whole-file/median numbers survive unchanged, which
% is worth knowing -- these takes are not a measurement artefact.
%
%   take   srcA    azA    errA    srcB    azB    errB   rel yaw
%   LEFT  +108.4 +105.0   -3.4   +71.6  +87.0  +15.4    +18.87
%   RIGHT  -71.6  -76.0   -4.4  -108.4  -99.0   +9.4    +13.87
%
% srcA/srcB is where the source really was IN THAT MIC'S OWN FRAME. That column
% is the whole story: on these two takes the source sat about 90 deg off the
% mics' own front axis, which no front take ever does.
%
% The mics were SWAPPED between the takes, so in the Zoom's frame the source
% sat at exactly opposite directions, 180.00 deg apart. Split the two required
% yaws accordingly:
%     common to both builds .................. +16.37 deg
%     differs between them ................... + 2.50 deg (builds 5.0 deg apart)
%     standing offset from the five front takes  +4.75 deg
%     excess over standing, COMMON to two rebuilds  +11.62 deg
%
% Two conclusions, one solid and one a strong suspicion:
%   SOLID. The rig is not the sloppy part. Two independently built front-back
%     rigs came out only 5.0 deg apart in relative yaw. That is a good job of
%     aiming by eye and it is NOT where the error is coming from.
%   SUSPECTED. The +11.62 excess survived a complete rebuild. Random building
%     error does not repeat like that, so it is systematic. The one thing these
%     takes do differently is put the source ~90 deg off the mics' own axis, so
%     that is the prime suspect: the Zoom's bearing error is a constant +4.75
%     near its front/back axis and appears to grow steeply out toward broadside.
%     It CANNOT be proved from n = 2 -- a habit repeated on every front-back
%     build would look identical. See test_side_takes.m, which explains why the
%     180 deg flip narrows this but cannot close it.
%
% Distances at each assumed yaw, so the size of it is visible (truth 1.50 m):
%     yawB      LEFT              RIGHT
%     0.00      3.14 m  +109%     2.46 m  +64%
%     4.75      2.48 m   +65%     2.02 m  +35%     <- standing offset applied
%    fitted     1.50 m    -0%     1.50 m   -0%     <- circular, not evidence
%
% Note both takes pass r/B < 3 at the standing yaw. Same lesson as the 11 Aug
% front clap: a guard that a wrong number escapes by getting less wrong is not
% a guard.
%
% It is tempting to recover yaw from the azimuth error against the known source
% direction -- that is the "fitted" row, and it lands on 1.50 m exactly. DO NOT
% READ THAT AS A MEASUREMENT. Fitting yaw to a known azimuth forces the range
% right by construction: what is left after the fit is a rotation COMMON to both
% rays, and a common rotation swings the answer around the midpoint without
% changing its RANGE. Compare the front takes, where yaw came from three takes
% at once and was then checked against a range nobody used to derive it. That is
% what independent confirmation looks like; this is not one.
%
% HOW TO NOT HAVE THIS PROBLEM AGAIN. Two rules, both free at record time.
%   1. AIM BOTH MICS AT THE SOURCE. "Broadside to the baseline" and "in front of
%      the mics" are INDEPENDENT conditions and the distance needs both. These
%      takes satisfied the first and gave up the second. You never have to: keep
%      the two mic POSITIONS where they are and just turn both mics 90 deg to
%      face the source. The source stays broadside to the baseline, and now it
%      is on-axis for both mics too. Equivalently -- always rotate the whole rig
%      so the pair sits side by side AS SEEN FROM THE SOURCE.
%      (For an AZIMUTH test at +-90 this does not apply; azimuth was fine here.
%      It is only the distance that needs the source in front.)
%   2. RECORD A YAW-CALIBRATION PAIR IN EVERY SETUP, before anything moves.
%      Tape-mark a point on the perpendicular bisector of the baseline, clap,
%      then clap again at the MIRROR-IMAGE point on the other side at the SAME
%      tape-measured distance, and run check_mic_yaw.m on that pair. It needs no
%      ground-truth direction. The equal-distance part is not optional: the
%      front/back sum only cancels distance for MIRRORED positions (see the
%      header of check_mic_yaw.m). Thirty seconds, and yawB becomes a
%      measurement instead of a guess.
%      Every rebuild resets the yaw, so one pair per BUILD, not per session.
%
% Also worth doing at the rig: tape-measure and write down the baseline B (it
% scales every distance linearly), the source distance, and both heights.

% Time window, in seconds, of the Zylia file. Leave EMPTY to use everything
% the two recordings have in common -- that is the normal case now, because
% quiet frames are dropped by the energy gate and clipped frames (every clap
% on the Zoom) are dropped automatically. Only set it by hand if you want to
% study one particular passage, e.g. window = [7.0 21.0].
window = [];


%% ==================== 2. THE RIG  (edit these) =======================
% MEASURE THE BASELINE WITH A TAPE. Distance scales linearly with it: 10%
% wrong in B is 10% wrong in r, and it cannot be recovered from the audio.
B = 1.00;                       % metres between the two mics

% WHERE THE TWO MICS STAND. Both of them always POINT the same way (+x, the
% look direction); this says only where they SIT relative to each other. It
% belongs to the TAKE, like yawB, because it changes the moment the rig is
% rebuilt -- so it is set in section 1 and only decoded here.
%
%   'LR'  side by side. Baseline runs ACROSS the look direction.
%         Zylia at -y, Zoom at +y. Origin is the midpoint.
%         Sees FRONT sources well. Blind to the sides, along +-y.
%
%   'FB'  one behind the other. Baseline runs ALONG the look direction.
%         Zylia in FRONT at +x, Zoom BEHIND at -x.
%         Sees SIDE sources well. Blind straight ahead and straight behind.
%
%   'BF'  the same, mics swapped: Zylia BEHIND at -x, Zoom in FRONT at +x.
%
% 'FB' and 'BF' are NOT interchangeable and you cannot tell them apart by eye
% afterwards -- get it wrong and the range is nonsense while azimuth still
% looks plausible. There is a reliable check that needs no tape measure: with
% the mics one behind the other and the source off to one side, the FRONT mic
% always reports |az| > 90 (the source is behind its shoulder) and the BACK mic
% always reports |az| < 90. Read the two per-mic bearings this script prints
% and set the layout to match them.
%
% These are the same geometry rotated 90 deg and neither is better. The only
% rule is that THE SOURCE MUST BE BROADSIDE TO THE BASELINE -- within about
% 60 deg of the perpendicular bisector of the two mics. A two-mic rig has a
% blind AXIS, the line through both mics, and no amount of processing removes
% it: a source on that line gives both mics the IDENTICAL bearing at every
% distance, so the recording contains no range information at all. You aim the
% rig so its blind axis points away from the source. You cannot delete it.
%
% Which mic sits on which side of an 'LR' rig is fixed by the data, not by
% eye: the mic that sees the source to its LEFT reports a POSITIVE azimuth.
% On the front takes the Zylia reads 0 while the Zoom reads -29, so the source
% is to the Zoom's RIGHT and the Zylia is at -y. Note this is the mirror of
% what you see standing in front of the rig looking back at it: the mic on
% YOUR left as you face the pair is the one at -y, the rig's right.
switch upper(layout)
    case 'LR', geom.posA = [0 -B/2];  geom.posB = [0 +B/2];
    case 'FB', geom.posA = [+B/2 0];  geom.posB = [-B/2 0];
    case 'BF', geom.posA = [-B/2 0];  geom.posB = [+B/2 0];
    otherwise
        error(['layout must be ''LR'' (side by side), ''FB'' (Zylia in front) ' ...
               'or ''BF'' (Zoom in front), got ''%s''. Set it in section 1 ' ...
               'with the take.'], layout);
end

% RELATIVE ORIENTATION OF THE TWO MICS. This matters far more than it looks.
% Distance comes from the DIFFERENCE between the two bearings, and at 1.5 m on
% a 1 m baseline that difference is only 36.9 deg. So 15 deg of relative
% rotation nearly halves the parallax and roughly doubles the reported range --
% while azimuth and elevation shift by a merely mediocre 15 deg and still look
% fine. A rig that is good enough for direction can be useless for distance.
%
% Measure it with check_mic_yaw.m, which needs a FRONT take and a BACK take and
% no ground truth at all. On the 2026-08-11 session it came out +4.75 deg, and
% applying it moved the two good takes from +13% and -9% error to -2.7% and +4%.
%
% 2026-08-17 re-measurement, from the five limit-test takes. The Zoom's azimuth
% error against truth was +4.7, +3.0 and +5.4 deg on the three non-degenerate
% takes (mean +4.4) while the Zylia's was 0.0, -1.7, -1.4 (mean -1.0), so the
% RELATIVE offset is +5.4 deg. Independently, sweeping yawB against the 1.5 m
% tape truth minimises distance error at +5.0 to +6.5 deg. Two unrelated
% derivations agreeing is why this is trusted over a single front/back pair.
% At +5.0 the three measurable takes come out 1.48, 1.54 and 1.58 m against
% 1.50 m truth -- every one inside 5.3%.
%
% 2026-08-20: IT IS MOSTLY NOT A PLACEMENT ERROR, IT IS THE ZOOM. Asked whether
% 4.75 was reasonable for two mics aimed straight forward on purpose, and it is,
% because yawB absorbs three different things and only one of them is aiming:
% the mic bodies not being parallel, each mic's ACOUSTIC zero not matching its
% printed front marker, and systematic bias in the two estimators. The last two
% belong to the instruments and cannot be aimed away.
% Per-mic errors over all five takes with a trustworthy truth (test_zoom_offset.m,
% aligned window, map peaks not per-frame medians):
%
%   take                 Zylia err   Zoom err   Zoom-Zylia
%   11 Aug front VOICE      -1.43      +2.43       +3.87
%   11 Aug back clap        +1.43      +5.57       +4.13
%   in front of ZYLIA       -0.01      +4.69       +4.69
%   in front of ZOOM        -2.69      +3.01       +5.69
%   centre + elevated       -0.69      +4.69       +5.37
%
% The Zylia sits on truth to +-1.5 deg. The Zoom is POSITIVE every single time.
% Within a session the offset is repeatable to 0.18 and 0.51 deg; between two
% sessions, with the rig taken apart and rebuilt in between, it moved only from
% +4.00 to +5.25. A placement mistake would be random -- different sign and size
% each build. This is a standing property of the pair, so ~+4.75 is a sensible
% DEFAULT to start from, and the ~1.25 deg that moves between sessions is the
% part that really is placement.
% Note the Zoom-Zylia column is robust to the source not being exactly where the
% tape said: a source offset shifts both mics almost equally and cancels in the
% difference. That is why it is a better statistic than either column alone.
%
% Do NOT read too much into the exact value: it is only pinned to about +-1 deg,
% because every method of measuring it assumes you stood on a line to within a
% centimetre or two, and at 1.5 m one centimetre sideways is 0.38 deg. If you
% want better distance, fix the yaw MECHANICALLY (tape lines on the floor,
% marked mic fronts) rather than estimating it afterwards.
geom.yawA = 0;
geom.yawB = yawB;               % set with the take in section 1, NOT here


%% ==================== 3. ANALYSIS SETTINGS ===========================
c = 343;

% Zylia ZM-1 (mic A)
cfgA.inFormat  = 'ambix';
cfgA.order     = 3;
cfgA.micRadius = 0.056;         % measured, not the SAF preset's 0.049
cfgA.fBand     = [1000 12000];  % must reach above the order-3 cut-on (~2.9 kHz)
cfgA.nBins     = 60;

% Zoom H3-VR (mic B). Confirmed from the file's own iXML metadata:
% "T=H3-VR; Rec Mode=AmbiX" -- 1st order AmbiX, 48 kHz.
cfgB.inFormat  = 'ambix';
cfgB.order     = 1;
cfgB.micRadius = 0;             % 1st order is broadband: no order cut-on
cfgB.fBand     = [800 4000];
cfgB.nBins     = 60;

for s = {'A','B'}
    q = eval(['cfg' s{1}]);
    q.frameLen     = 1024;      % ~21 ms at 48 kHz
    q.hop          = 512;
    q.energyGateDb = -25;       % relative to the loudest frame, AND
    q.snrGateDb    = 10;        % at least this far above the file's noise floor
    q.azGrid       = deg2rad(0:1:359);
    q.elGrid       = deg2rad(-40:5:40);
    % One distance in the steering grid. Distance is no longer read from this
    % SRP -- triangulation supplies it -- and bearings barely depend on the
    % assumed r, so a single value keeps the grid 11x smaller and faster.
    q.rGrid        = 1.5;
    q.c            = c;
    eval(['cfg' s{1} ' = q;']);
end


%% ==================== 4. RUN =========================================
fprintf('================ %s  +  %s ================\n', zyliaFile, zoomFile);

% Put the two files on one clock: envelope match, then the clap to refine.
al = align_two_mics(zyliaFile, zoomFile);

if isempty(window)
    window = al.overlap;        % everything the two recordings share
    fprintf('  window         : auto, %.2f .. %.2f s\n', window);
else
    fprintf('  window         : set by hand, %.2f .. %.2f s\n', window);
end

cfgA.wavFile = zyliaFile;  cfgA.tWindow = window;
cfgB.wavFile = zoomFile;   cfgB.tWindow = window + al.offset;

tri  = triangulate(cfgA, cfgB, geom);      % distance

% run_doa.m gates relative to the single loudest frame. On a clap take that
% frame is the clap, ~25 dB above the speech, so its own gate would discard
% almost all the speech. Hand it the threshold az_power_map actually used, so
% both analyse the same frames. run_doa itself is untouched.
cfgA.energyGateDb = tri.mapA.gateRelMaxDb;
cfgB.energyGateDb = tri.mapB.gateRelMaxDb;

resA = doa_frames(cfgA);                   % per-frame bearings, Zylia
resB = doa_frames(cfgB);                   % per-frame bearings, Zoom
[azA, elA, azAmad, elAmad] = frame_stats(resA);
[azB, elB, azBmad, elBmad] = frame_stats(resB);

% Lift the horizontal solution into 3-D. This used to be
%     zS = mean([tri.rA*tand(elA), tri.rB*tand(elB)]);
% -- the mean of the two mics' PER-FRAME MEDIAN elevations. Both halves of that
% were wrong, and on the 2026-08-17 elevated-clap take they combined to report
% 2.6 deg for a source that three independent measurements put at about +16.
%
%   1. The Zoom contributes nothing. Its SRP elevation map peaks at exactly
%      0 deg in all five takes -- including the elevated one -- and its profile
%      is symmetric to two decimals and essentially identical to the flat
%      control. At 1st order the vertical beam is too broad to beat the room,
%      so what it measures is the diffuse field, which is symmetric about the
%      horizontal plane. Averaging a correct +16 with a stuck 0 halves it.
%      (The Zoom's Z channel is fine, -3.2 dB re W: this is the estimator, not
%      the hardware. Direct-path pseudo-intensity on its own claps gave +14.7.)
%
%   2. run_doa's per-frame MEDIAN collapses on transient material. On that take
%      it returned 3.2 deg for the Zylia. A clap leaves most gated frames in the
%      reverberant tail, which points nowhere; a plain median has no defence,
%      while az_power_map's decisiveness weighting does. The same effect put
%      that take's per-frame median AZIMUTH at 164.6 deg with a MAD of 168.
%
% So take elevation from the Zylia's accumulated map instead. It reads 0.0 deg
% on all four flat takes and +15 (+20 on claps only) on the elevated one, and
% agrees with direct-path pseudo-intensity (+16.9 +- 4.6). run_doa itself is
% untouched -- elA/elB are still computed and still printed per mic below.
zS   = tri.rA * tand(tri.mapA.elPeak);
pos  = [tri.pos zS];
rHor = hypot(pos(1), pos(2));
rC   = hypot(rHor, zS);
azC  = atan2d(pos(2), pos(1));
elC  = atan2d(zS, rHor);

% what each mic SHOULD see, derived from the ground truth and the geometry
gtPos = gtR * [cosd(gtElDeg)*cosd(gtAzDeg), cosd(gtElDeg)*sind(gtAzDeg), sind(gtElDeg)];
[gtAzA, gtElA] = bearing_from(gtPos, geom.posA);
[gtAzB, gtElB] = bearing_from(gtPos, geom.posB);

% per-frame distance, by intersecting the two bearings frame by frame. Only
% meaningful because the files are aligned, so frame k means the same instant
% on both. Used for the plot and to show the scatter -- the reported distance
% is the far steadier map-fusion one above.
[rFrame, tFrame] = per_frame_range(resA, resB, geom);


%% ==================== 5. REPORT ======================================
fprintf('\n=============== SOURCE, from the midpoint of the two mics ===============\n');
fprintf('Estimate        : az = %7.2f deg | el = %6.2f deg | r = %.2f m\n', azC, elC, rC);
fprintf('Ground truth    : az = %7.2f deg | el = %6.2f deg | r = %.2f m\n', gtAzDeg, gtElDeg, gtR);
fprintf('Error           : az = %+7.2f deg | el = %+6.2f deg | r = %+.2f m (%+.0f%%)\n', ...
        wrap180(azC-gtAzDeg), elC-gtElDeg, rC-gtR, 100*(rC-gtR)/gtR);
fprintf('95%% CI on r     : [%.2f  %.2f] m   (bootstrap over frames)\n', tri.ci*rC/tri.rA);
fprintf('position [x y z]: [%.2f %.2f %.2f] m\n', pos);
fprintf('Targets (draft) : az RMSE < 5 deg,  r error < 0.1 m\n');

fprintf('\n=============== PER-MIC BEARINGS (run_doa, per frame) ===============\n');
fprintf('%-7s %4s %9s %9s %9s %9s %9s\n', '', '', 'median', 'truth', 'error', 'spread', 'RMSE');
print_bearing('Zylia', 'az', azA, gtAzA, resA, 'az', azAmad);
print_bearing('',      'el', elA, gtElA, resA, 'el', elAmad);
print_bearing('Zoom',  'az', azB, gtAzB, resB, 'az', azBmad);
print_bearing('',      'el', elB, gtElB, resB, 'el', elBmad);
fprintf('frames used     : Zylia %d, Zoom %d   (parallax %.1f deg)\n', ...
        nnz(resA.active), nnz(resB.active), tri.sep);
fprintf('elevation used  : %+.1f deg, from the Zylia MAP (not the per-frame median)\n', ...
        tri.mapA.elPeak);

% A large azimuth MAD means the per-frame path has collapsed into noise -- the
% frames are pointing all round the circle and their median means nothing. It
% does NOT invalidate the numbers above, which come from the accumulated maps,
% but it does invalidate the per-mic median column for that mic.
for mic = {{'Zylia', azAmad, elAmad}, {'Zoom', azBmad, elBmad}}
    m = mic{1};
    if m{2} > 30
        fprintf(['\nNOTE: the %s per-frame azimuth scatter is %.0f deg -- the frames are\n' ...
                 '      pointing all round the circle, so that mic''s MEDIAN row above is\n' ...
                 '      meaningless. Typical on clap-only takes, where most gated frames\n' ...
                 '      are reverberant tail. The map-based answers are unaffected.\n'], ...
                m{1}, m{2});
    end
end
fprintf(['\n"spread" is the robust scatter (MAD) of the per-frame estimates;\n' ...
         '"RMSE" is over every frame including gross outliers. When RMSE is far\n' ...
         'larger than spread, most frames are good and a few point somewhere\n' ...
         'random -- which is why the distance fuses the two full power maps\n' ...
         'instead of averaging per-frame peaks.\n']);

fprintf(['\nMic yaw in use   : A %+.2f, B %+.2f deg. Re-measure with check_mic_yaw.m\n' ...
         '                   whenever the rig is set up again -- it drifts, and the\n' ...
         '                   distance is far more sensitive to it than az/el are.\n'], ...
        geom.yawA, geom.yawB);

% HOW FAR THE SOURCE WAS FROM BROADSIDE. This is the single number that says
% whether a distance was possible AT ALL, and it is worth reading before the
% answer itself. The rig has a blind AXIS -- the line through both mics. A
% source sitting on it is seen at the IDENTICAL bearing by both mics at every
% range, so the recording holds no range information whatsoever and nothing
% downstream can invent it. This measures how close the source came to that
% axis: 0 deg is straight out the perpendicular bisector and ideal, 90 deg is
% the blind axis itself. Azimuth and elevation are unaffected either way --
% only the range dies. Added 2026-08-18.
bl   = (geom.posB - geom.posA) / B;
uMid = tri.pos - (geom.posA + geom.posB)/2;
rMid = norm(uMid);
offBroadside = 90 - acosd(min(1, abs(dot(uMid/rMid, bl))));
if     offBroadside < 45, quality = 'ideal';
elseif offBroadside < 60, quality = 'usable';
elseif offBroadside < 75, quality = 'marginal -- expect errors of tens of percent';
else,                     quality = 'ON THE BLIND AXIS -- no range information exists';
end

fprintf('\n=============== VERDICT ===============\n');
fprintf('Source %.0f deg off broadside (0 = ideal, 90 = blind axis): %s\n', ...
        offBroadside, quality);
fprintf('Parallax %.1f deg measured, %.1f deg expected for %.2f m at this angle.\n', ...
        tri.sep, 2*atand(B*cosd(offBroadside)/(2*rMid)), rMid);
if isempty(tri.warning)
    fprintf('Distance is usable: r/B = %.1f, inside the r/B < 3 limit for a %.2f m\n', ...
            tri.rA/B, B);
    fprintf('baseline. To measure further away, widen the baseline to about r.\n');
    fprintf(['\nCAUTION: the r/B rule cannot see a rig that turned. If a mic rotated\n' ...
             'between takes, the range is wrong and this test still passes. The only\n' ...
             'thing that catches it is check_mic_yaw.m on a front + back pair.\n']);
else
    fprintf('DISTANCE NOT TRUSTWORTHY -- %s\n', tri.warning);
    fprintf('Azimuth and elevation above are still fine; only r is affected.\n');
end


%% ==================== 6. PLOTS =======================================
% --- Figure 1: per-frame estimates, same layout as main_doa_estimation.m
figure('Name','Per-frame estimates','Color','w');
subplot(3,1,1);
plot(resA.t(resA.active), wrap180(resA.azDeg(resA.active)), '.'); hold on;
plot(resB.t(resB.active), wrap180(resB.azDeg(resB.active)), '.');
yline(gtAzA,'r--','Zylia truth'); yline(gtAzB,'b--','Zoom truth');
ylabel('azimuth (deg)'); grid on; ylim([-180 180]);
legend('Zylia','Zoom','Location','best');
title('Fine estimates per frame (energy-gated)');

subplot(3,1,2);
plot(resA.t(resA.active), resA.elDeg(resA.active), '.'); hold on;
plot(resB.t(resB.active), resB.elDeg(resB.active), '.');
yline(gtElDeg,'r--');
ylabel('elevation (deg)'); grid on;

subplot(3,1,3);
plot(tFrame, rFrame, '.'); hold on;
yline(gtR,'r--','ground truth');
yline(rC,'k-','fused estimate');
ylabel('distance (m)'); xlabel('time (s)'); grid on; ylim([0 5]);
title(sprintf('per-frame triangulated range (median %.2f m, fused %.2f m)', ...
      median(rFrame,'omitnan'), rC));

% --- Figure 2: polar SRP, like main_doa_estimation.m but accumulated over
% every usable frame rather than just the single loudest one
figure('Name','SRP power vs azimuth','Color','w');
azp = [tri.mapA.az; tri.mapA.az(1)];
polarplot(azp, [tri.mapA.P; tri.mapA.P(1)], 'LineWidth', 1.5); hold on;
polarplot(azp, [tri.mapB.P; tri.mapB.P(1)], 'LineWidth', 1.5);
polarplot(deg2rad(gtAzA)*[1 1], [0 1], 'r--');
polarplot(deg2rad(gtAzB)*[1 1], [0 1], 'b--');
legend('Zylia','Zoom','Zylia truth','Zoom truth','Location','southoutside');
title('Normalised SRP vs azimuth, accumulated over all usable frames');

% --- Figure 3: the two-mic likelihood map, where the answer comes from
figure('Name','Fused position map','Color','w');
imagesc(tri.xg, tri.yg, tri.map.'); axis xy equal tight; hold on;
colormap(parula); colorbar;
plot(geom.posA(1), geom.posA(2), 'wo', 'MarkerFaceColor','k', 'MarkerSize',8);
plot(geom.posB(1), geom.posB(2), 'wo', 'MarkerFaceColor','k', 'MarkerSize',8);
text(geom.posA(1), geom.posA(2), '  Zylia', 'Color','w');
text(geom.posB(1), geom.posB(2), '  Zoom',  'Color','w');
plot(tri.pos(1), tri.pos(2), 'w+', 'MarkerSize',16, 'LineWidth',2);
plot(gtPos(1), gtPos(2), 'wx', 'MarkerSize',14, 'LineWidth',2);
xlim([-3 3]); ylim([-3 3]); xlabel('x (m)'); ylabel('y (m)');
title('Two-mic likelihood.   +  estimate    x  ground truth');


%% ==================== local functions ================================
function res = doa_frames(cfg)
% run_doa.m has no time window, so trim to a scratch file first. The analysis
% path itself is completely untouched.
[x, fs] = audioread(cfg.wavFile);
if isfield(cfg,'tWindow') && ~isempty(cfg.tWindow)
    i0 = max(1, round(cfg.tWindow(1)*fs)+1);
    i1 = min(size(x,1), round(cfg.tWindow(2)*fs));
    x  = x(i0:i1, :);
end
f = fullfile(tempdir, sprintf('doa_seg_%d.wav', randi(1e6)));
audiowrite(f, x, fs, 'BitsPerSample', 32);
cfg.wavFile = f;
evalc('res = run_doa(cfg);');       % suppress the per-call setup chatter
delete(f);
end

function [r, t] = per_frame_range(resA, resB, geom)
n  = min(numel(resA.azDeg), numel(resB.azDeg));
ok = resA.active(1:n) & resB.active(1:n);
aA = wrap180(resA.azDeg(1:n));  aB = wrap180(resB.azDeg(1:n));
r  = nan(n,1);
pA = geom.posA(:);  pB = geom.posB(:);
for k = 1:n
    if ~ok(k), continue; end
    dA = [cosd(aA(k)); sind(aA(k))];
    dB = [cosd(aB(k)); sind(aB(k))];
    M  = [dA, -dB];
    if abs(det(M)) < 1e-6, continue; end
    s = M \ (pB - pA);
    if s(1) <= 0 || s(2) <= 0, continue; end   % crossing behind a mic
    r(k) = norm(s(1)*dA);
end
t = resA.t(1:n);
t = t(~isnan(r));  r = r(~isnan(r));
end

function [azMed, elMed, azMad, elMad] = frame_stats(res)
a = res.active;
if ~any(a), error('No frames passed the energy gate.'); end
az = wrap180(res.azDeg(a));
% Unwrap around the DENSEST 30-degree window, not around the circular mean.
% A handful of frames pointing the wrong way drags the mean badly, and if it
% lands near the +-180 seam the median comes out on the far side of the circle
% from every actual estimate.
edges = -180:5:180;
h  = histcounts(az, edges);
hw = movsum([h h h], 6);                 % wrap-around 30 deg window
hw = hw(numel(h)+1 : 2*numel(h));
[~, i] = max(hw);
mu = (edges(i) + edges(i+1))/2;
az = wrap180(az - mu) + mu;
azMed = median(az);  azMad = 1.4826*median(abs(az - azMed));
azMed = wrap180(azMed);      % unwrapping can push it past +-180; bring it back
elMed = median(res.elDeg(a));
elMad = 1.4826*median(abs(res.elDeg(a) - elMed));
end

function print_bearing(mic, what, med, truth, res, kind, spread)
a = res.active;
if strcmp(kind,'az')
    e = wrap180(res.azDeg(a) - truth);
else
    e = res.elDeg(a) - truth;
end
fprintf('%-7s %4s %9.2f %9.2f %+9.2f %9.2f %9.2f\n', mic, what, med, truth, ...
        wrap180(med-truth), spread, sqrt(mean(e.^2)));
end

function [azDeg, elDeg] = bearing_from(src, mic)
v = [src(1)-mic(1), src(2)-mic(2), src(3)];
azDeg = atan2d(v(2), v(1));
elDeg = atan2d(v(3), hypot(v(1), v(2)));
end

function y = wrap180(x)
y = mod(x + 180, 360) - 180;
end
