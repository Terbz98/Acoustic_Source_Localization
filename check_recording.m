%% CHECK_RECORDING  --  run this on any exported WAV BEFORE the full pipeline.
%
%  It tells you, in plain English, whether the file looks like a valid
%  ACN/SN3D ambisonic recording, and roughly which direction the sound
%  is coming from. No steering matrix, no grid -- just quick sanity checks.
%
%  HOW TO USE:
%    1. Put your exported .wav filename below.
%    2. Run this file.
%    3. Read the VERDICT lines.

wavFile = 'zoomh3vrfront.wav';     % <-- EDIT: your exported recording

% --------------------------------------------------------------------
[x, fs] = audioread(wavFile);
nCh = size(x, 2);
fprintf('\n============ RECORDING CHECK: %s ============\n', wavFile);
fprintf('Channels: %d   |   Duration: %.1f s   |   Rate: %d Hz\n\n', ...
        nCh, size(x,1)/fs, fs);

% ---- Check 1: channel count ----
if nCh == 16
    fprintf('[OK ] 16 channels -> 3rd-order ambisonics. Set cfg.order = 3.\n');
elseif nCh == 4
    fprintf('[OK ] 4 channels -> 1st-order ambisonics. Set cfg.order = 1.\n');
elseif nCh == 19
    fprintf('[BAD] 19 channels -> this is RAW capsule data, NOT ambisonics.\n');
    fprintf('      You must export through the Zylia Converter to AmbiX first.\n');
    return;
else
    fprintf('[??] %d channels -> unexpected. Not a standard ambisonic file.\n', nCh);
end

% ---- Check 2: is channel 1 the omni (W)? ----
% W captures ALL sound, so it should be one of the loudest channels.
rms = sqrt(mean(x.^2, 1));
[~, loudest] = max(rms);
w_rank = sum(rms > rms(1)) + 1;   % rank of channel 1 (1 = loudest)

fprintf('\nChannel energies (first 4):  ');
fprintf('%.5f  ', rms(1:min(4,nCh))); fprintf('\n');

if loudest == 1 || rms(1) >= 0.5 * max(rms)
    fprintf('[OK ] Channel 1 is the loudest (or close) -> looks like the omni W.\n');
    chOK = true;
else
    fprintf('[BAD] Channel 1 is NOT the loudest (it ranks #%d of %d).\n', w_rank, nCh);
    fprintf('      In real ACN order, channel 1 is the omni and should be loudest.\n');
    fprintf('      >>> Your export ordering is probably WRONG. Re-export from the\n');
    fprintf('          Zylia Converter with ACN ordering + SN3D normalization,\n');
    fprintf('          and make sure it is the Ambisonics (B-format) export,\n');
    fprintf('          NOT a raw / capsule / A-format export.\n');
    chOK = false;
end

% ---- Check 3: rough direction from the intensity vector ----
% Only meaningful if the channel order is trustworthy.
W = x(:,1); Y = x(:,2); Z = x(:,3); X = x(:,4);   % ACN order: W,Y,Z,X
env = abs(W);
thr = quantile(env, 0.85);          % loudest 15% of samples
m = env > thr;
Ix = mean(W(m).*X(m));
Iy = mean(W(m).*Y(m));
Iz = mean(W(m).*Z(m));
az = mod(atan2d(Iy, Ix), 360);
el = atan2d(Iz, hypot(Ix, Iy));

fprintf('\nRough source direction (from raw channels, loudest frames):\n');
fprintf('   azimuth   ~ %.0f deg   (0=front, 90=left, 180=back, 270=right)\n', az);
fprintf('   elevation ~ %.0f deg   (0=ear height, +up, -down)\n', el);

% ---- Check 4: is the sound horizontal? (sanity on elevation) ----
Xr = sqrt(mean(X(m).^2)); Yr = sqrt(mean(Y(m).^2)); Zr = sqrt(mean(Z(m).^2));
fprintf('\nDirectional channel strengths (loud):  X=%.5f  Y=%.5f  Z=%.5f\n', Xr, Yr, Zr);
if Zr > max(Xr, Yr)
    fprintf('[BAD] Z (up-down) is the STRONGEST directional channel.\n');
    fprintf('      For a source at ear height this is wrong. Two possible causes:\n');
    fprintf('       (a) strong floor/ceiling reflection (untreated room), or\n');
    fprintf('       (b) channel order is scrambled (see Check 2).\n');
    zOK = false;
else
    fprintf('[OK ] Horizontal channels dominate -> sound is arriving horizontally.\n');
    zOK = true;
end

% ---- VERDICT ----
fprintf('\n---------------------- VERDICT ----------------------\n');
if chOK && zOK
    fprintf('LOOKS GOOD. Proceed to the full pipeline (main_doa_estimation).\n');
    fprintf('Set gt.azDeg to the MEASURED angle and compare.\n');
else
    fprintf('NOT READY. Fix the issues flagged [BAD] above before running\n');
    fprintf('the full pipeline -- otherwise the estimates will be garbage no\n');
    fprintf('matter how good your room or positioning is.\n');
end
fprintf('=====================================================\n');
