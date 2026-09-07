function out = triangulate_aug11(cfgA, cfgB, geom)
% FROZEN COPY, DO NOT EDIT AND DO NOT CALL FROM ANALYSIS CODE.
% This is triangulate.m exactly as it stood on 2026-08-11, recovered from the
% D:\u5c08題\u5c08題 snapshot folder and renamed so both versions can be loaded at
% once. Its only user is test_old_vs_new.m, which runs it side by side with the
% live triangulate.m to show that the code did not change any take's answer.
% The live estimator is triangulate.m. Use that one.
% TRIANGULATE  Source distance and position from TWO microphone positions.
%
%   out = triangulate(cfgA, cfgB, geom)
%   triangulate selftest        checks the geometry on synthetic bearings
%
%   THIS IS THE METHOD THAT WORKS AT RANGE, AND IT IS NOW CONFIRMED ON REAL
%   RECORDINGS. It does not use wavefront curvature, reverberation, source
%   level or time-of-flight -- only the two BEARINGS, which this project
%   already measures well. Where the two rays cross is the source.
%
%   Measured on the two-mic takes (Zylia + Zoom H3-VR, 1 m baseline, speaker
%   about 1.5 m from the midpoint, so 1.58 m from each mic):
%       front, voice take   1.78 m
%       back,  clap take    1.30 m
%   against a railed, meaningless 3.00 m from every curvature-based attempt.
%
%   HOW THE ESTIMATE IS FORMED
%   Not by intersecting two single bearings. az_power_map.m keeps each mic's
%   FULL steered-response map over azimuth, accumulated over every usable
%   frame. This function then lays a grid of candidate source positions over
%   the room and, for each one, multiplies the two maps at the azimuth that
%   position implies at each mic. The peak of that product is the source.
%
%   The difference matters. Two single bearings that are each a few degrees off
%   put the crossing metres away, because at r/B = 1.5 a 1 degree bearing error
%   is already a 4 cm range error and the errors do not cancel. Multiplying the
%   whole maps lets a frame that is slightly off widen the ridge instead of
%   dragging the answer, and the two mics' independent evidence multiplies.
%
%   THE ONE RULE: MAKE THE BASELINE ROUGHLY THE DISTANCE YOU WANT TO MEASURE.
%       sigma_r / r  ~=  (r / B) * sigma_theta
%   Past r/B = 3 the rays are too close to parallel and the answer stops
%   meaning anything -- out.warning will say so. With B = 1 m trust it to about
%   3 m; for a source at 5 m use a 3-5 m baseline.
%
%   INPUTS
%     cfgA, cfgB  full cfg structs (see main_distance.m), one per mic, each
%                 with its own wavFile / order / micRadius / fBand, and
%                 optionally tWindow = [t0 t1] to analyse part of the file.
%                 Zylia ZM-1 : order 3, micRadius 0.056, fBand [1000 12000]
%                 Zoom H3-VR : order 1, micRadius 0,     fBand [800 4000]
%     geom.posA   [x y] of mic A in metres, e.g. [0 -0.5]
%     geom.posB   [x y] of mic B in metres, e.g. [0 +0.5]
%     geom.yawA   optional, degrees mic A is rotated from the assumed heading
%     geom.yawB   optional, the same for mic B. ONLY THE DIFFERENCE MATTERS to
%                 the distance, and it matters a great deal: the parallax at
%                 1.5 m on a 1 m baseline is 36.9 deg, so 15 deg of relative
%                 rotation nearly halves it. Measure these with check_mic_yaw.m
%                 from a front take and a back take -- it needs no ground truth.
%     geom.nBoot  optional bootstrap repeats for the confidence interval (300)
%
%   OUTPUT
%     out.pos       estimated source position [x y] in metres
%     out.rA, out.rB   distance from each mic
%     out.ci        95% confidence interval on rA, by bootstrapping frames
%     out.azA, out.azB, out.elA, out.elB   the two bearings
%     out.sep       angular separation of the bearings (the parallax)
%     out.warning   '' if the geometry is trustworthy, else why it is not
%
%   RECORDING PROTOCOL
%   1. Both mics on stands at the SAME HEIGHT, baseline B apart. TAPE-MEASURE B
%      and write it down -- it cannot be recovered afterwards, and B scales the
%      answer linearly: a 10% error in B is a 10% error in every distance.
%   2. Aim both mic fronts the same way. Any relative rotation goes straight
%      into the distance; feed it in as geom.yawB if you cannot avoid it.
%   3. No time sync needed. Record independently on each device.
%   4. Keep the source broadside to the baseline, not along it -- a source on
%      the line through both mics has no parallax at all.
%   5. Record at 3-4 tape-measured distances so you can plot estimated against
%      true and actually demonstrate that it tracks.

if nargin == 1 && (ischar(cfgA) || isstring(cfgA)) && strcmpi(cfgA, 'selftest')
    selftest();  return;
end
if nargin < 3, error('triangulate needs cfgA, cfgB and geom.'); end
if ~isfield(geom, 'yawA'),  geom.yawA  = 0;   end
if ~isfield(geom, 'yawB'),  geom.yawB  = 0;   end
if ~isfield(geom, 'nBoot'), geom.nBoot = 300; end

posA = geom.posA(1:2);  posA = posA(:).';
posB = geom.posB(1:2);  posB = posB(:).';
B    = norm(posB - posA);
if B < 1e-3
    error(['The two mic positions are the same point (baseline %.4f m). ' ...
           'Triangulation needs two SEPARATED positions -- this is exactly ' ...
           'why takes recorded on one stand cannot be used.'], B);
end

mA = az_power_map(cfgA);
mB = az_power_map(cfgB);

% mic B's map is expressed in its own frame; undo any relative rotation
azB_grid = mA.az;
PB = interp1([mA.az; mA.az(1)+2*pi], [mB.P; mB.P(1)], ...
             mod(azB_grid + deg2rad(geom.yawB - geom.yawA), 2*pi), 'linear', 'extrap');

span = max(6*B, 8);
step = min(0.02, B/50);
xg = (posA(1)+posB(1))/2 + (-span:step:span);
yg = (posA(2)+posB(2))/2 + (-span:step:span);

[out.pos, out.rA, out.rB, S] = fuse(mA.P, PB, mA.az, posA, posB, xg, yg);

% bootstrap the confidence interval by resampling frames
nb = geom.nBoot;
rb = nan(nb,1);
xc = (posA(1)+posB(1))/2 + (-span:step*3:span);
yc = (posA(2)+posB(2))/2 + (-span:step*3:span);
nA = size(mA.Pframe,2);  nB = size(mB.Pframe,2);
for k = 1:nb
    ia = randi(nA, nA, 1);  ib = randi(nB, nB, 1);
    pa = mA.Pframe(:,ia) * mA.w(ia).';
    pb = mB.Pframe(:,ib) * mB.w(ib).';
    if max(pa) <= 0 || max(pb) <= 0, continue; end
    pa = pa/max(pa);  pb = pb/max(pb);
    pb = interp1([mA.az; mA.az(1)+2*pi], [pb; pb(1)], ...
                 mod(azB_grid + deg2rad(geom.yawB - geom.yawA), 2*pi), 'linear', 'extrap');
    [~, rb(k)] = fuse(pa, pb, mA.az, posA, posB, xc, yc);
end
out.ci = quantile(rb(~isnan(rb)), [0.025 0.975]);

out.azA = mA.azPeak;  out.elA = mA.elPeak;  out.nA = mA.nFrames;
out.azB = mB.azPeak;  out.elB = mB.elPeak;  out.nB = mB.nFrames;
out.baseline = B;
out.map = S;  out.xg = xg;  out.yg = yg;
out.mapA = mA;  out.mapB = mB;      % the two accumulated azimuth maps

vA = out.pos - posA;  vB = out.pos - posB;
out.sep = abs(mod(atan2d(vA(2),vA(1)) - atan2d(vB(2),vB(1)) + 180, 360) - 180);

% ---- is this geometry trustworthy? -------------------------------------
out.warning = '';
if out.rA > 3*B
    out.warning = sprintf(['r/B = %.1f. Past 3 the two rays are too close to ' ...
        'parallel and the range is not meaningful. Use a baseline near %.1f m.'], ...
        out.rA/B, out.rA);
elseif out.sep < 10
    out.warning = sprintf(['the two bearings differ by only %.1f deg. There is ' ...
        'almost no parallax to work with; widen the baseline.'], out.sep);
end

fprintf('\nTriangulation\n');
fprintf('  mic A      : az %7.2f  el %6.2f deg   (%d frames, SNR %.0f dB, %d clipped dropped)\n', ...
        out.azA, out.elA, out.nA, mA.snrDb, mA.nClip);
fprintf('  mic B      : az %7.2f  el %6.2f deg   (%d frames, SNR %.0f dB, %d clipped dropped)\n', ...
        out.azB, out.elB, out.nB, mB.snrDb, mB.nClip);
fprintf('  baseline   : %.3f m       parallax %.1f deg\n', B, out.sep);
fprintf('  source at  : [%.2f %.2f] m\n', out.pos);
fprintf('  DISTANCE   : %.2f m from mic A   (%.2f m from mic B)\n', out.rA, out.rB);
fprintf('  95%% CI     : [%.2f  %.2f] m   (bootstrap over frames)\n', out.ci);
if isempty(out.warning)
    fprintf('  VERDICT    : usable (r/B = %.1f)\n', out.rA/B);
else
    fprintf('  VERDICT    : NOT TRUSTWORTHY -- %s\n', out.warning);
end
end


% ===================== fusion =========================================
function [pos, rA, rB, S] = fuse(PA_, PB_, azgrid, posA, posB, xg, yg)
[X, Y] = ndgrid(xg, yg);
azq = [azgrid(:); azgrid(1)+2*pi];
PA = interp1(azq, [PA_(:); PA_(1)], mod(atan2(Y-posA(2), X-posA(1)), 2*pi));
PB = interp1(azq, [PB_(:); PB_(1)], mod(atan2(Y-posB(2), X-posB(1)), 2*pi));
S  = PA .* PB;
S(hypot(X-posA(1), Y-posA(2)) < 0.25) = 0;   % meaningless right on top of a mic
S(hypot(X-posB(1), Y-posB(2)) < 0.25) = 0;
[~, i] = max(S(:));
[ia, ib] = ind2sub(size(S), i);
pos = [xg(ia) yg(ib)];
rA  = norm(pos - posA);
rB  = norm(pos - posB);
end


% ===================== self test ======================================
function selftest()
% Put a source at known positions, compute the exact bearings each mic would
% see, add realistic bearing noise, and check the distance comes back. This
% verifies the GEOMETRY. Whether a real room delivers bearings this good is a
% separate question, answered by out.ci and out.warning on real files.
fprintf('\nGeometry check: baseline 1.0 m, bearing noise 3 deg (1 sigma)\n');
fprintf('%10s %10s %10s %10s %10s\n','true r','median est','rms err','r/B','verdict');
rng(1);
posA = [0 -0.5];  posB = [0 0.5];  B = 1.0;
for trueR = [1.0 1.58 2.5 4.0 8.0]
    src = [trueR 0];
    errs = zeros(400,1);
    for t = 1:400
        aA = bearing(src, posA) + 3*randn;
        aB = bearing(src, posB) + 3*randn;
        dA = [cosd(aA) sind(aA)];  dB = [cosd(aB) sind(aB)];
        M = [dA(:), -dB(:)];
        if abs(det(M)) < 1e-9, errs(t) = NaN; continue; end
        s = M \ (posB(:)-posA(:));
        if s(1) <= 0, errs(t) = NaN; continue; end
        p = posA(:) + s(1)*dA(:);
        errs(t) = norm(p.' - posA) - norm(src - posA);
    end
    errs = errs(~isnan(errs));
    rt = norm(src - posA);
    v = 'ok';
    if rt > 3*B, v = 'r/B>3'; end
    fprintf('%10.2f %10.2f %10.2f %10.1f %10s\n', ...
            rt, rt+median(errs), sqrt(mean(errs.^2)), rt/B, v);
end
fprintf(['\nError grows with r/B exactly as sigma_r/r = (r/B)*sigma_theta says.\n' ...
         'On real files the map-fusion estimator above does better than this\n' ...
         'two-bearing intersection, because it uses every frame''s whole map.\n']);
end

function azDeg = bearing(src, mic)
v = src(:) - mic(:);
azDeg = atan2d(v(2), v(1));
end
