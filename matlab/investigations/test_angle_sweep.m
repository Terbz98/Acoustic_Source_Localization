function test_angle_sweep
% TEST_ANGLE_SWEEP  2026-08-21.
%
% ONE TAKE, CLAPS AT EVERY ANGLE. How far off broadside does the distance
% still work?
%
% This is the measurement that turns "distance dies at 90 deg" from a guess
% into a curve. Record ONE continuous take with the rig untouched, clapping a
% group of claps at each taped angle with a pause between groups. This script
% finds the groups by itself, runs both mics over each group, triangulates, and
% plots range error against angle with the theoretical 1/cos(theta) rise
% overlaid.
%
% WHY ONE TAKE AND NOT NINE FILES. Every distance failure in this project so
% far traces to the rig being rebuilt between takes and the relative yaw being
% lost. One continuous take makes that impossible: one build, one yaw, one
% alignment between the two recorders, for every angle. That is the whole
% point of the design.
%
% -------------------------------------------------------------------------
% RECORDING PROTOCOL -- read this BEFORE recording or the take is unusable
% -------------------------------------------------------------------------
%  1. Build the rig once. Mics side by side, tape-measure the baseline, same
%     height, both facing the same way. DO NOT TOUCH IT until the take ends.
%  2. TURN THE ZOOM INPUT GAIN DOWN about 12 dB. Its claps currently clip
%     (12937 full-scale samples on one take) and a clipped frame is dropped.
%  3. Tape floor marks at ONE radius from the MIDPOINT -- 1.5 m -- at each
%     angle you want: 0, +-20, +-40, +-60, +-80. Same radius for all of them.
%     Also tape the two YAW CALIBRATION marks: on the perpendicular bisector,
%     the same measured distance in FRONT of and BEHIND the midpoint.
%  4. Start both recorders. Clap once loudly to give align_two_mics something
%     to lock onto.
%  5. CALIBRATION FIRST: 5 claps at the front mark, pause, 5 claps at the back
%     mark, pause. Set CAL_BLOCKS below to [1 2] and this script recovers the
%     relative yaw from the take itself -- no assumed value, no ground truth.
%  6. Then walk the angles IN THE ORDER YOU LIST IN 'angles' BELOW. About 5
%     claps at each mark, then a pause of AT LEAST 3 SECONDS before moving.
%     The pause is what separates the groups; without it this script cannot
%     tell the angles apart.
%  7. Clap at mic height, arms out, not over your head. Write the order down.
% -------------------------------------------------------------------------
addpath(fullfile(fileparts(mfilename('fullpath')), '..')); setup_paths;   % code + recordings on the path

%% ---- edit these ---------------------------------------------------------
zyliaFile = 'sweepzylia_(ACN-SN3D-3).wav';
zoomFile  = 'sweepzoom.WAV';

CAL_BLOCKS = [1 2];        % [frontBlock backBlock], or [] to skip and set yawB
yawB       = 4.75;         % used only when CAL_BLOCKS is empty
angles     = [0 -20 +20 -40 +40 -60 +60 -80 +80];   % clap order AFTER the cal blocks
gtR        = 1.50;         % metres from the MIDPOINT, same for every angle
B          = 1.00;         % tape-measured baseline
GAP_S      = 2.0;          % silence that separates one angle group from the next
PAD_S      = 0.15;         % breathing room added round each group
%% ------------------------------------------------------------------------

posA = [0 -B/2];  posB = [0 +B/2];       % Zylia at -y, Zoom at +y

cA.inFormat='ambix'; cA.order=3; cA.micRadius=0.056; cA.fBand=[1000 12000]; cA.nBins=60;
cB.inFormat='ambix'; cB.order=1; cB.micRadius=0;     cB.fBand=[800 4000];   cB.nBins=60;
for s = {'A','B'}
    q = eval(['c' s{1}]);
    q.frameLen=1024; q.hop=512; q.energyGateDb=-25; q.snrGateDb=10;
    q.azGrid=deg2rad(0:1:359); q.elGrid=deg2rad(-40:5:40); q.rGrid=gtR; q.c=343;
    eval(['c' s{1} ' = q;']);
end

for f = {zyliaFile, zoomFile}
    if ~isfile(f{1})
        error('cannot find %s in %s -- set zyliaFile/zoomFile at the top of this file to whatever you named the sweep recording (the Zylia one must be the ACN-SN3D version, not the raw).', f{1}, pwd);
    end
end

al = align_two_mics(zyliaFile, zoomFile, 'verbose', false);
blk = find_blocks(zyliaFile, al.overlap, GAP_S, PAD_S);

fprintf('\n  %d clap groups found in the aligned overlap [%.2f %.2f] s:\n\n', ...
        numel(blk), al.overlap);
fprintf('%7s %9s %9s %8s\n', 'block', 'start', 'end', 'claps');
for i = 1:numel(blk)
    fprintf('%7d %9.2f %9.2f %8d\n', i, blk(i).t0, blk(i).t1, blk(i).n);
end

nNeed = numel(angles) + numel(CAL_BLOCKS);
if numel(blk) ~= nNeed
    fprintf(['\n  *** %d groups found but %d expected (%d angles + %d calibration).\n' ...
             '  *** Either a pause was too short (groups merged) or a gap inside one\n' ...
             '  *** angle was too long (one angle split in two). Check the times above\n' ...
             '  *** against your notes, then fix ''angles'' or GAP_S and rerun. Nothing\n' ...
             '  *** below is trustworthy until the counts match.\n\n'], ...
            numel(blk), nNeed, numel(angles), numel(CAL_BLOCKS));
end

%% ---- relative yaw, straight out of this take ----------------------------
if ~isempty(CAL_BLOCKS)
    [fA, fB] = block_bearings(blk(CAL_BLOCKS(1)), cA, cB, zyliaFile, zoomFile, al);
    [bA, bB] = block_bearings(blk(CAL_BLOCKS(2)), cA, cB, zyliaFile, zoomFile, al);
    % For a source on the perpendicular bisector, a mic's FRONT and BACK
    % azimuths sum to 180 -- but ONLY if the two marks are the same distance
    % from the rig. That is why step 3 says "the same measured distance".
    % See the header of check_mic_yaw.m for what happens when they are not.
    eA = (wrap180(fA) + mod(bA,360) - 180)/2;
    eB = (wrap180(fB) + mod(bB,360) - 180)/2;
    yawB = wrap180(eB - eA);
    fprintf(['\n  YAW FROM THIS TAKE (blocks %d and %d)\n' ...
             '    Zylia front %+7.2f  back %+7.2f  -> its own rotation %+6.2f\n' ...
             '    Zoom  front %+7.2f  back %+7.2f  -> its own rotation %+6.2f\n' ...
             '    relative yawB = %+.2f deg   (the pair''s standing value is +4.75)\n'], ...
            CAL_BLOCKS(1), CAL_BLOCKS(2), fA, bA, eA, fB, bB, eB, yawB);
    if abs(yawB - 4.75) > 6
        fprintf('    *** that is far from +4.75 -- suspect the two cal marks were not\n');
        fprintf('    *** the same distance from the midpoint. Remeasure before trusting it.\n');
    end
end

%% ---- sweep --------------------------------------------------------------
use = setdiff(1:numel(blk), CAL_BLOCKS);
n   = min(numel(use), numel(angles));

fprintf('\n  DISTANCE vs ANGLE   (baseline %.2f m, truth %.2f m, yawB %+.2f)\n\n', ...
        B, gtR, yawB);
fprintf('%7s %9s %8s %8s %9s %10s %7s  %s\n', ...
        'angle', 'azA err', 'paralx', 'r', 'r err', '95% CI', 'claps', 'verdict');
fprintf('%s\n', repmat('-', 1, 86));

R = nan(n,1);  E = nan(n,1);  AZ = nan(n,1);  CI = nan(n,1);  ok = false(n,1);
for i = 1:n
    b = blk(use(i));  th = angles(i);
    gtPos = gtR*[cosd(th) sind(th)];
    tA = atan2d(gtPos(2)-posA(2), gtPos(1)-posA(1));
    tB = atan2d(gtPos(2)-posB(2), gtPos(1)-posB(1));

    a = cA;  a.wavFile = zyliaFile;  a.tWindow = [b.t0 b.t1];
    z = cB;  z.wavFile = zoomFile;   z.tWindow = [b.t0 b.t1] + al.offset;
    geom = struct('posA', posA, 'posB', posB, 'yawA', 0, 'yawB', yawB, 'nBoot', 100);

    o = evalc('out = triangulate(a, z, geom);');   %#ok<NASGU>

    R(i)  = out.rA;                     % triangulate reports from mic A
    rMid  = norm(out.pos);              % from the midpoint, which gtR is measured from
    E(i)  = 100*(rMid - gtR)/gtR;
    AZ(i) = wrap180(out.azA - tA);
    ok(i) = isempty(out.warning);
    R(i)  = rMid;

    v = 'ok';
    if ~isempty(out.warning), v = 'REJECTED'; end
    ciPct = 100*(out.ci(2) - out.ci(1))/2/max(out.rA, eps);
    CI(i) = ciPct;
    fprintf('%+7.0f %+9.2f %8.1f %8.2f %+8.0f%% %8.0f%% %7d  %s\n', ...
            th, AZ(i), out.sep, rMid, E(i), ciPct, b.n, v);
end
fprintf('%s\n', repmat('-', 1, 86));

%% ---- the curve ----------------------------------------------------------
[~, i0] = min(abs(angles(1:n)));            % the broadside take anchors the model
base = abs(E(i0));
th = linspace(0, 88, 200);
model = base ./ cosd(th);

fprintf('\n  MEASURED vs THE 1/cos MODEL anchored on your own broadside error (%.1f%%)\n\n', base);
fprintf('%9s %12s %12s\n', 'angle', 'measured', 'model');
for i = 1:n
    fprintf('%+9.0f %11.0f%% %11.0f%%\n', angles(i), abs(E(i)), base/cosd(abs(angles(i))));
end

fprintf(['\n  HOW TO QUOTE EACH MEASUREMENT. Distance is wanted as information,\n' ...
         '  so every angle gets a number AND an honest bar -- never a bare number\n' ...
         '  that hides how far off broadside it was taken.\n\n']);
fprintf('%9s %24s   %s\n', 'angle', 'quote it as', 'basis');
fprintf('%s\n', repmat('-', 1, 74));
for i = 1:n
    bar = max(CI(i), base/cosd(abs(angles(i))));
    if ~ok(i)
        tag = 'REJECTED by a guard -- do not quote';
    elseif abs(angles(i)) > 60
        tag = 'outside the trusted cone';
    else
        tag = 'inside the trusted cone';
    end
    fprintf('%+9.0f %24s   %s\n', angles(i), ...
            sprintf('%.2f m +- %.0f%%', R(i), bar), tag);
end
fprintf(['\n  The bar is the LARGER of this take''s own bootstrap CI and what\n' ...
         '  the 1/cos model predicts for that angle. Two independent estimates;\n' ...
         '  trust the pessimistic one -- a bootstrap CI only sees frame-to-frame\n' ...
         '  scatter, and goes happily tight on a bearing that is systematically\n' ...
         '  wrong. That is exactly how the 11 Aug front clap passed every guard.\n\n']);

figure('Name','Distance accuracy vs angle off broadside','Color','w');
subplot(2,1,1);
plot(th, model, 'k--', 'LineWidth', 1); hold on;
plot(abs(angles(1:n)), abs(E), 'o', 'MarkerFaceColor', [0.2 0.4 0.8], 'MarkerSize', 7);
plot(abs(angles(~ok(1:n))), abs(E(~ok)), 'rx', 'MarkerSize', 12, 'LineWidth', 2);
yline(10, ':', '10% line');
xlabel('degrees off broadside');  ylabel('|range error| %');
title(sprintf('range error vs angle  (B = %.2f m, r = %.2f m)', B, gtR));
legend('base/cos\theta', 'measured', 'rejected by a guard', 'Location','northwest');
ylim([0 max(60, 1.2*max(abs(E)))]);  grid on;

subplot(2,1,2);
plot(angles(1:n), AZ, 'o-', 'MarkerFaceColor', [0.8 0.4 0.2]);
xlabel('source azimuth, deg');  ylabel('Zylia azimuth error, deg');
title('azimuth should stay flat across the whole sweep -- only range decays');
grid on;

cross = th(find(model > 10, 1, 'first'));
if ~isempty(cross)
    fprintf(['\n  The model crosses 10%% at %.0f deg off broadside. Read your own\n' ...
             '  crossing off the top panel -- THAT number is the usable half-width\n' ...
             '  of this rig, and it is the headline result of this take.\n\n'], cross);
end
end


% ===================== helpers ========================================
function blk = find_blocks(f, ovl, gapS, padS)
% Split the take into clap GROUPS separated by at least gapS of near-silence.
[x, fs] = audioread(f);
w = x(:,1);                                   % W channel, omnidirectional
i0 = max(1, round(ovl(1)*fs));  i1 = min(numel(w), round(ovl(2)*fs));
seg = w(i0:i1);
env = movmax(abs(seg), round(0.002*fs));
thr = max(0.25*max(env), 8*median(env));
hot = env >= thr;
d   = diff([false; hot(:); false]);
s   = find(d ==  1);  e = find(d == -1) - 1;
if isempty(s), blk = struct('t0',{},'t1',{},'n',{}); return; end

% merge events closer together than gapS -- those are claps of one group
gap = round(gapS*fs);
gs = s(1);  ge = e(1);  n = 1;  blk = struct('t0',{},'t1',{},'n',{});
for k = 2:numel(s)
    if s(k) - ge <= gap
        ge = e(k);  n = n + 1;
    else
        blk(end+1) = mk(gs, ge, n, i0, fs, padS, numel(w));  %#ok<AGROW>
        gs = s(k);  ge = e(k);  n = 1;
    end
end
blk(end+1) = mk(gs, ge, n, i0, fs, padS, numel(w));
end

function b = mk(gs, ge, n, i0, fs, padS, N)
b.t0 = max(0,       (i0 + gs - 1)/fs - padS);
b.t1 = min((N-1)/fs,(i0 + ge - 1)/fs + padS);
b.n  = n;
end

function [azA, azB] = block_bearings(b, cA, cB, fa, fb, al)
% accumulated map peak of each mic over one clap group
a = cA;  a.wavFile = fa;  a.tWindow = [b.t0 b.t1];
z = cB;  z.wavFile = fb;  z.tWindow = [b.t0 b.t1] + al.offset;
o = evalc('mA = az_power_map(a); mB = az_power_map(z);');   %#ok<NASGU>
azA = mA.azPeak;  azB = mB.azPeak;
end

function y = wrap180(x)
y = mod(x + 180, 360) - 180;
end
