clear; clc; close all;
addpath(fileparts(mfilename('fullpath'))); setup_paths;   % code + recordings on the path

fs   = 48000;
dur  = 4;                 % seconds
c    = 343;

% source position
srcAzDeg = 40;            % try 0, 40, 180, 300 ...
srcElDeg = 0;
srcR     = 1.5;           % meters

% piano-ish test signal
t = (0:round(dur*fs)-1)' / fs;
s = zeros(size(t));
noteF = [220 277 330 440];                 % A3, C#4, E4, A4
for kNote = 0:7
    t0   = 0.5 * kNote;
    f0   = noteF(mod(kNote, 4) + 1);
    idx  = t >= t0 & t < t0 + 0.45;
    tt   = t(idx) - t0;
    s(idx) = s(idx) + exp(-6 * tt) .* ...
             (sin(2*pi*f0*tt) + 0.5*sin(2*pi*2*f0*tt) + 0.25*sin(2*pi*3*f0*tt));
end
s = s / max(abs(s));

% Encode into FOA
order = 1;
nCh   = (order + 1)^2;
Ysrc  = real_sh_matrix(order, deg2rad(srcAzDeg), deg2rad(srcElDeg)); % 4 x 1

L = 1024; hop = 512;
win = 0.5 * (1 - cos(2*pi*(0:L-1).'/L));
fAx = (0:L/2) * fs / L;
kf  = 2*pi*fAx / c;

% per-bin channel gains: Y_n^m * h_n^(2)(k r)/h_0^(2)(k r)
G = complex(zeros(nCh, L/2 + 1));
h0 = sph_hankel2(0, kf * srcR);
G(1, :)   = Ysrc(1);
% The (1i)^(-n) factor is REQUIRED: build_steering_matrix.m line 45 applies it
% to every order, so omitting it here made the synthetic signal disagree with
% the estimator by 90 deg on the order-1 channels. That leaves the front and
% back candidates exactly tied in SRP power, and the test failed with a 180 deg
% azimuth flip -- a bug in this test file, not in the pipeline.
G(2:4, :) = Ysrc(2:4) .* ((1i)^(-1) * sph_hankel2(1, kf * srcR) ./ h0);
G(:, fAx < 40) = 0;

nFr = floor((numel(s) - L) / hop) + 1;
b   = zeros(numel(s) + L, nCh);            % N3D, ACN
for fr = 1:nFr
    idx  = (fr-1)*hop + (1:L);
    X    = fft(s(idx) .* win);             % L x 1
    Xp   = X(1:L/2+1).';                   % 1 x (L/2+1)
    C    = G .* Xp;                        % nCh x bins
    Cfull = [C, conj(C(:, end-1:-1:2))];   % Hermitian symmetry
    seg  = real(ifft(Cfull, [], 2)).';     % L x nCh
    b(idx, :) = b(idx, :) + seg;           % 50% Hann OLA (COLA holds)
end
b = b(1:numel(s), :);

b = b + 1e-4 * max(abs(b(:))) * randn(size(b));

% write as AmbiX (ACN / SN3D)
nOfAcn = floor(sqrt(0:nCh-1));
bSN3D  = b ./ sqrt(2 * nOfAcn + 1);
bSN3D  = bSN3D / max(abs(bSN3D(:))) * 0.7;
audiowrite('synthetic_foa.wav', bSN3D, fs);
fprintf('Wrote synthetic_foa.wav  (source truth: az=%g deg, el=%g deg, r=%g m)\n\n', ...
        srcAzDeg, srcElDeg, srcR);

% run the estimation pipeline
cfg.wavFile  = 'synthetic_foa.wav';
cfg.inFormat = 'ambix';
cfg.order    = 1;
cfg.frameLen = 1024;
cfg.hop      = 512;
cfg.fBand    = [100 4000];
cfg.nBins    = 40;
cfg.energyGateDb = -35;
cfg.azGrid   = deg2rad(0:5:355);
cfg.elGrid   = deg2rad(-40:5:40);
cfg.rGrid    = 0.5:0.25:3.0;
cfg.c        = c;

res = run_doa(cfg);
act = res.active;

epsAz = mod(res.azDeg(act) - srcAzDeg + 180, 360) - 180;
rmseAz = sqrt(mean(epsAz.^2));
rmseR  = sqrt(mean((res.r(act) - srcR).^2));

fprintf('\n---------------- SELF-TEST RESULT ----------------\n');
fprintf('Median az = %.2f deg (truth %g)   | RMSE az = %.2f deg\n', ...
        median(mod(res.azDeg(act)+180,360)-180), srcAzDeg, rmseAz);
fprintf('Median el = %.2f deg (truth %g)\n', median(res.elDeg(act)), srcElDeg);
fprintf('Median r  = %.2f m   (truth %g)   | RMSE r  = %.2f m\n', ...
        median(res.r(act)), srcR, rmseR);
if rmseAz < 5
    fprintf('AZIMUTH: PASS (< 5 deg)\n');
else
    fprintf('AZIMUTH: FAIL -- something is wrong in the chain.\n');
end
fprintf(['NOTE on distance: at 1st order and r = 1.5 m the near-field cue is\n' ...
         'tiny (see comments), so a loose r estimate here is expected physics.\n']);
fprintf('---------------------------------------------------\n');
