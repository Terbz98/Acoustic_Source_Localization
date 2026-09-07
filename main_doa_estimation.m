clear; clc; close all;

% ======================================================================
% MAIN SCRIPT -- run this one.
%
%   azimuth + elevation  <-  cfg.wavFile   (16-ch converted, run_doa.m)
%   distance             <-  cfg.rawFile   (19-ch raw capsules,
%                                            estimate_distance.m)
%
% Two files per take because the two quantities survive in different
% places. Direction lives in the ratios between capsules on the same
% wavefront and survives the A-to-B conversion intact. Distance lives only
% in that wavefront's CURVATURE -- at 1.5 m, 0.4 mm of extra path across
% the 9.8 cm sphere, about 1-2 degrees of phase -- which the conversion's
% per-order radial filtering wipes out. So distance has to be read from
% the untouched capsule signals.
% ======================================================================

cfg.wavFile  = '2miczyliafront_(ACN-SN3D-3).wav';   % 16 ch -> az, el
cfg.rawFile  = '2miczyliafront.wav';                % 19 ch -> r
cfg.inFormat = 'ambix';   % 'ambix' or 'fuma'
cfg.order    = 3;         % 1 = Zoom H3-VR   |   3 = Zylia ZM-1

% Capsule-sphere radius of the mic. This sets the order cut-on frequency
% f_n = n*c/(2*pi*micRadius): order n only carries real information above it,
% and below it that order's channels are noise (see build_steering_matrix).
%   Zylia ZM-1  -> ~0.049 m  (order1 ~1.1 kHz, order2 ~2.2 kHz, order3 ~3.3 kHz)
%   Zoom H3-VR  -> leave as 0 (1st order is broadband; no high-order cut-on)
% cfg.micRadius = 0;
% 0.056 is MEASURED from your own recordings, not taken from a datasheet.
% Cross-correlating the 19 capsules gives the arrival delay of the wavefront at
% each one; those delays match the rigid-sphere model (corr 0.99 across takes)
% only when the radius is 0.056 m. The 0.049 m in the SPARTA/SAF preset makes
% the model predict delays 13-15% too short. Fixing it improved azimuth RMSE on
% every take (26.8->26.1, 31.9->23.4, 5.6->5.6, 13.3->10.8 deg).
cfg.micRadius = 0.056;    % <-- set 0 for the Zoom H3-VR

cfg.frameLen = 1024;      % ~21.3 ms @ 48 kHz
cfg.hop      = 512;       % 50% overlap

% Analysis band. IMPORTANT: for the 3rd-order Zylia this MUST reach above the
% order-3 cut-on (~3.3 kHz) or the high-order channels are useless. The old
% [800 4000] band was the bug -- it sat below the order-2/3 cut-ons, so the
% SRP was driven by noise. Frequency-dependent order (build_steering_matrix)
% now lets us keep a wide band: low bins use order 1, high bins use order 3.
% cfg.fBand    = [800 4000];
cfg.fBand    = [1000 12000];   % Zoom H3-VR: use [800 4000]

cfg.nBins    = 60;
cfg.energyGateDb = -9;

cfg.azGrid = deg2rad(0:5:355);
cfg.elGrid = deg2rad(-40:5:40);
cfg.c      = 343;

% Distance settings, used only by estimate_distance on the raw file. The band
% is lower than the ambisonic one on purpose: the near-field phase cue
% n(n+1)/(2kr) grows towards low frequency, but below ka ~ 1 (~1.1 kHz) the
% rigid-sphere response suppresses the very modes that carry it, so the usable
% window is in between.
cfg.rGrid       = 0.5:0.25:3.0;
cfg.distBand    = [700 6000];
cfg.distNBins   = 48;
cfg.distGateDb  = -12;

% Ground truth -- SET THESE TO MATCH cfg.wavFile. They only affect the RMSE
% report, not the estimate. (macfront 0/0, macback 180/0, macleft 90/0,
% macright -90/0, macfrontleftup ~45/20, macbackrightdown ~-135/-20.)
gt.azDeg = 0;
gt.elDeg = 0;
gt.r     = 1.5;

% ---------------------------------------------------------------- run
res = run_doa(cfg);

act = res.active;
if ~any(act)
    error('ERROR');
end

azMed = median(mod(res.azDeg(act) + 180, 360) - 180);
elMed = median(res.elDeg(act));

% distance from the raw capsules, at the direction just found
cfgD = cfg;
cfgD.fBand = cfg.distBand;  cfgD.nBins = cfg.distNBins;
cfgD.energyGateDb = cfg.distGateDb;
dist = estimate_distance(cfg.rawFile, deg2rad(azMed), deg2rad(elMed), cfgD);
dAct = dist.active;

% ------------------------------------------------------------- report
epsAz = mod(res.azDeg(act) - gt.azDeg + 180, 360) - 180;
epsEl = res.elDeg(act) - gt.elDeg;
epsR  = dist.r(dAct)   - gt.r;

rmseAz = sqrt(mean(epsAz.^2));
rmseEl = sqrt(mean(epsEl.^2));
rmseR  = sqrt(mean(epsR.^2));

fprintf('\nMedian estimate : az = %7.2f deg | el = %6.2f deg | r = %.2f m\n', ...
        azMed, elMed, median(dist.r(dAct)));
fprintf('Ground truth    : az = %7.2f deg | el = %6.2f deg | r = %.2f m\n', ...
        gt.azDeg, gt.elDeg, gt.r);
fprintf('RMSE            : az = %7.2f deg | el = %6.2f deg | r = %.2f m\n', ...
        rmseAz, rmseEl, rmseR);
fprintf('Targets (draft) : az RMSE < 5 deg,  r RMSE < 0.1 m\n');

% ------------------------------------------- is the distance trustworthy?
fprintf('\nDistance validity check\n');
fprintf('  wavefront coherence : %.2f   (synthetic point source gives 0.94)\n', dist.coh);
fprintf('  point-source fit    : %.2f\n', median(dist.fit(dAct)));
fprintf('  frames on grid edge : %.0f%%\n', 100*dist.edgeFrac);
if dist.edgeFrac > 0.5
    fprintf(['  VERDICT: RAILED -- r is NOT a measurement. The peak is stuck on an\n' ...
             '  edge of cfg.rGrid. Confirm by setting cfg.rGrid = 0.5:0.5:10 and\n' ...
             '  re-running: a railed estimate follows the new edge, a real one does\n' ...
             '  not move.\n']);
    if dist.coh < 0.9
        fprintf(['  CAUSE: coherence %.2f means much of the arriving sound is not one\n' ...
                 '  clean wavefront, so the 1-2 degree curvature cue is buried. Fix the\n' ...
                 '  RECORDING, not the code: (1) play a sine sweep and time-gate the\n' ...
                 '  direct arrival, (2) use ONE small driver playing mono rather than a\n' ...
                 '  laptop (two speakers 25 cm apart, screen and tabletop reflecting\n' ...
                 '  within 20 cm -- room treatment cannot help at that distance),\n' ...
                 '  (3) keep source and mic >1 m from any surface.\n'], dist.coh);
    end
elseif dist.coh < 0.9
    fprintf('  VERDICT: usable but suspect -- coherence below 0.9.\n');
else
    fprintf('  VERDICT: usable.\n');
end
fprintf('\n  (estimate_distance selftest  verifies the estimator on synthetic data)\n');

% -------------------------------------------------------------- plots
tAct = res.t(act);

figure('Name', 'Per-frame estimates', 'Color', 'w');
subplot(3,1,1);
plot(tAct, mod(res.azDeg(act) + 180, 360) - 180, '.'); hold on;
yline(gt.azDeg, 'r--', 'ground truth');
ylabel('azimuth (deg)'); grid on; ylim([-180 180]);
title('Fine estimates per frame (energy-gated)');

subplot(3,1,2);
plot(tAct, res.elDeg(act), '.'); hold on;
yline(gt.elDeg, 'r--');
ylabel('elevation (deg)'); grid on;

subplot(3,1,3);
plot(dist.t(dAct), dist.r(dAct), '.'); hold on;
yline(gt.r, 'r--');
ylabel('distance (m)'); xlabel('time (s)'); grid on;
ylim([cfg.rGrid(1) cfg.rGrid(end)]);
if dist.edgeFrac > 0.5
    title(sprintf('distance RAILED (coherence %.2f) -- from raw capsules', dist.coh));
else
    title(sprintf('distance from raw capsules (coherence %.2f)', dist.coh));
end

figure('Name', 'SRP power map (strongest frame)', 'Color', 'w');
ie = res.mapIdx(2); ir = res.mapIdx(3);
Paz = squeeze(res.mapP3(:, ie, ir));
polarplot([cfg.azGrid, cfg.azGrid(1)], [Paz; Paz(1)] / max(Paz), 'LineWidth', 1.5);
title(sprintf('Normalized SRP vs azimuth  (el = %g deg, r = %g m, t = %.2f s)', ...
      rad2deg(cfg.elGrid(ie)), cfg.rGrid(ir), res.t(res.mapFrame)));
