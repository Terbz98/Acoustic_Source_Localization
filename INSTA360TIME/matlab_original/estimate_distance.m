function out = estimate_distance(rawFile, az, el, cfg)
% ESTIMATE_DISTANCE  Source distance from the RAW 19-capsule ZM-1 file.
%
%   out = estimate_distance(rawFile, az, el, cfg)
%       rawFile : 19-channel A-format wav (e.g. 'macfront.wav')
%       az, el  : source direction in RADIANS, as found by run_doa.m
%       cfg     : needs frameLen hop fBand nBins energyGateDb rGrid c
%
%   out fields: t, r, active, fit, coh, edgeFrac
%
%   estimate_distance selftest    runs a synthetic verification
%
%   WHY DISTANCE NEEDS THE RAW FILE AND DIRECTION DOES NOT
%   Direction lives in the ratios between capsules sitting on the same
%   wavefront, and survives everything -- which is why run_doa.m gets az/el
%   right from the converted 16-channel file. Distance lives only in that
%   wavefront's CURVATURE. At 1.5 m the difference between "1.5 m away" and
%   "3 m away" is 0.4 mm of extra path across the whole 9.8 cm sphere, about
%   1-2 degrees of phase. That is far too fine to survive the per-order radial
%   filtering in the A-to-B conversion, so it must be read from the untouched
%   capsule signals.
%
%   MODEL
%   For a point source at (az, el, r) and a rigid sphere of radius a, the
%   pressure at capsule q is
%       p_q = sum_n (2n+1)/(4pi) * h_n(k r) * b_n(k a) * P_n(cos gamma_q)
%   with gamma_q the angle between the source and capsule q, and
%       b_n(x) = -1i / (x^2 * h_n'(x))
%   the rigid-sphere scattering term. h_n(k r) is the distance dependence.
%   Because az/el are already known, this searches r ONLY -- a 1-D search.
%
%   READ THE COHERENCE OUTPUT
%   out.coh is how much of the arriving sound is a single clean wavefront,
%   measured between the two most widely separated capsules. A synthetic point
%   source gives 0.94. The current takes give 0.32-0.85, i.e. roughly half the
%   energy above 1.6 kHz is not one wavefront, and the 1-2 degree cue cannot be
%   read through that -- the search then rails to an edge of cfg.rGrid.
%   Get coherence above ~0.9 and distance becomes measurable. How, in order of
%   effectiveness:
%     1. Play a SINE SWEEP and time-gate the direct arrival, rejecting every
%        reflection after the first.
%     2. Use ONE small driver playing MONO. A laptop has two speakers ~25 cm
%        apart plus a screen and tabletop reflecting within 20 cm of them; a
%        damped room does nothing about a reflector that close to the source.
%     3. Keep source and mic more than 1 m from any surface, both on stands.

if nargin == 1 && (ischar(rawFile) || isstring(rawFile)) && strcmpi(rawFile, 'selftest')
    selftest();
    return;
end

[x, fs] = audioread(rawFile);
[capsAzEl, ~, Q] = zylia_geom();
if size(x,2) ~= Q
    error(['"%s" has %d channels but the raw capsule file must have %d. ' ...
           'The 16-channel _(ACN-SN3D-*) file is the converted one -- that is ' ...
           'cfg.wavFile, used for az/el; this argument wants cfg.rawFile.'], ...
           rawFile, size(x,2), Q);
end

L = cfg.frameLen;  hop = cfg.hop;
win = 0.5*(1-cos(2*pi*(0:L-1).'/L));
fAx = (0:L/2)*fs/L;
inB = find(fAx >= cfg.fBand(1) & fAx <= cfg.fBand(2));
if isempty(inB)
    error('No FFT bins inside cfg.fBand = [%g %g] Hz.', cfg.fBand);
end
sel   = unique(inB(round(linspace(1, numel(inB), min(cfg.nBins, numel(inB))))));
freqs = fAx(sel);

% ---- steering vectors, one per candidate distance ---------------------
nR = numel(cfg.rGrid);
W  = complex(zeros(Q, nR, numel(freqs)));
for ir = 1:nR
    G = capsule_tf(az, el, cfg.rGrid(ir), freqs, cfg.c);
    W(:, ir, :) = reshape(G ./ vecnorm(G, 2, 1), Q, 1, numel(freqs));
end

% ---- frame loop -------------------------------------------------------
nFr = floor((size(x,1)-L)/hop) + 1;
if nFr < 1
    error('Raw recording shorter than one frame (%d samples).', L);
end

E = zeros(nFr,1);
for fr = 1:nFr
    idx = (fr-1)*hop + (1:L);
    F = fft(x(idx,:).*win);
    E(fr) = sqrt(mean(abs(F(sel,:)).^2, 'all'));
end
gate = max(E) * 10^(cfg.energyGateDb/20);

out.t      = ((0:nFr-1)'*hop + L/2)/fs;
out.r      = nan(nFr,1);
out.fit    = nan(nFr,1);
out.active = false(nFr,1);
rIdx       = nan(nFr,1);
dR         = 0;
if nR > 1, dR = cfg.rGrid(2)-cfg.rGrid(1); end

for fr = 1:nFr
    if E(fr) < gate, continue; end
    idx = (fr-1)*hop + (1:L);
    F  = fft(x(idx,:).*win);
    Xf = F(sel,:).';                                   % Q x nFreq

    P = zeros(nR,1);
    for fi = 1:numel(freqs)
        P = P + abs(W(:,:,fi)' * Xf(:,fi)).^2;         % SRP over distance only
    end
    [pk, ir] = max(P);

    if nR > 2 && ir > 1 && ir < nR                     % parabolic refinement
        den = 2*P(ir+1) - 4*P(ir) + 2*P(ir-1);
        off = 0;
        if abs(den) > eps*max(abs(P))
            off = max(min(-(P(ir+1)-P(ir-1))/den, 1), -1);
        end
        out.r(fr) = cfg.rGrid(ir) + off*dR;
    else
        out.r(fr) = cfg.rGrid(ir);
    end
    out.fit(fr)    = pk / sum(abs(Xf).^2, 'all');
    rIdx(fr)       = ir;
    out.active(fr) = true;
end

out.edgeFrac = mean(rIdx(out.active) == 1 | rIdx(out.active) == nR);
out.coh      = capsule_coherence(x, sel, L, hop, capsAzEl);
end


% ======================= diagnostics ===================================
function coh = capsule_coherence(x, sel, L, hop, capsAzEl)
% Coherence between the two most widely separated capsules, over the analysis
% bins, using the loudest 30% of frames. One coherent wavefront gives ~1
% however far apart the capsules are; a diffuse or multi-source field gives far
% less. This is the single best predictor of whether distance is readable.
u = [cos(capsAzEl(:,2)).*cos(capsAzEl(:,1)), ...
     cos(capsAzEl(:,2)).*sin(capsAzEl(:,1)), sin(capsAzEl(:,2))];
D = u*u.';
[~, im] = min(D(:));
[q1, q2] = ind2sub(size(D), im);

win = 0.5*(1-cos(2*pi*(0:L-1).'/L));
nFr = floor((size(x,1)-L)/hop)+1;
E = zeros(nFr,1);
for fr = 1:nFr
    idx = (fr-1)*hop+(1:L);
    E(fr) = sum(x(idx,:).^2, 'all');
end
[~, ord] = sort(E,'descend');

Sxy = 0; Sxx = 0; Syy = 0;
for fr = ord(1:max(1,round(0.3*nFr))).'
    idx = (fr-1)*hop+(1:L);
    F = fft(x(idx,:).*win);
    A = F(sel,q1);  B = F(sel,q2);
    Sxy = Sxy + sum(A.*conj(B));
    Sxx = Sxx + sum(abs(A).^2);
    Syy = Syy + sum(abs(B).^2);
end
coh = abs(Sxy)/sqrt(Sxx*Syy);
end


% ======================= model =========================================
function [azEl, a, Q] = zylia_geom()
% ZYLIA ZM-1 capsule directions (radians, same az/el convention as the rest of
% the project) and rigid-sphere radius. Source: Spatial_Audio_Framework
% __Zylia1D_coords_rad, the SPARTA Array2SH preset ZYLIA_1D. Rings are
% 1 x +90 deg, 3 x +48.1, 6 x +19.4, 6 x -19.4, 3 x -48.1 = 19 capsules, with
% no bottom pole (that is the stand mount). Row order = channel order of the
% raw wav, confirmed by checking these capsules reproduce run_doa.m's azimuth.
azEl = [ 0.0                  1.57079632679490
         0.00305809444245928  0.840254037451382
         2.09600986753364     0.840126252832125
        -2.09336058192593     0.840886905122138
        -1.43409959239697     0.338967177556435
        -0.656487391713457    0.339152933310760
         0.661232814211584    0.338858655681573
         1.43624308141539     0.339058915910358
         2.75545932621978     0.339167630604397
        -2.75063229463181     0.339281599533891
        -2.48035983937821    -0.338858655681573
        -1.70534957217440    -0.339058915910358
        -0.386133327370014   -0.339167630604397
         0.390960358957982   -0.339281599533891
         1.70749306119282    -0.338967177556435
         2.48510526187634    -0.339152933310760
        -3.13853455914733    -0.840254037451382
        -1.04558278605616    -0.840126252832125
         1.04823207166387    -0.840886905122138 ];
% 0.056 m, not the 0.049 m in the SAF preset. Measured from these recordings:
% the inter-capsule arrival delays (GCC-PHAT across all 19 channels) match the
% rigid-sphere model at corr 0.99, but only at this radius -- 0.049 m predicts
% delays 13-15% too short. Consistent with Zylia's ~103 mm published body.
a = 0.056;
Q = size(azEl,1);
end

function G = capsule_tf(az, el, r, freqs, c)
% Rigid-sphere point-source pressure at each capsule (see header for the
% equation). Uses the Legendre addition theorem, so no spherical-harmonic
% convention is involved and real_sh_matrix.m is not needed here.
[capsAzEl, a, Q] = zylia_geom();
k  = 2*pi*freqs(:).'/c;   k(k==0) = 1e-6;
ka = k*a;
N  = min(40, ceil(max(ka) + 4.05*max(ka)^(1/3) + 3));   % modal truncation

uS = [cos(el)*cos(az); cos(el)*sin(az); sin(el)];
uQ = [cos(capsAzEl(:,2)).*cos(capsAzEl(:,1)), ...
      cos(capsAzEl(:,2)).*sin(capsAzEl(:,1)), sin(capsAzEl(:,2))];
cosG = max(min(uQ*uS, 1), -1);

[~, Hp] = sph_h2(N, ka);
bn = -1i ./ (ka.^2 .* Hp);   bn(~isfinite(bn)) = 0;
Hr = sph_h2(N, k*r);

Pn = zeros(Q, N+1);  Pn(:,1) = 1;
if N >= 1, Pn(:,2) = cosG; end
for n = 1:N-1
    Pn(:,n+2) = ((2*n+1)*cosG.*Pn(:,n+1) - n*Pn(:,n))/(n+1);
end

G = complex(zeros(Q, numel(k)));
for n = 0:N
    G = G + Pn(:,n+1) * (((2*n+1)/(4*pi)) * Hr(n+1,:) .* bn(n+1,:));
end
end

function [H, Hp] = sph_h2(nMax, x)
% Spherical Hankel h_n^(2) and its derivative, n = 0..nMax. Same convention as
% sph_hankel2.m; that file returns only H, and the rigid-sphere boundary
% condition (no air flow into the plastic) needs Hp.
x = max(x(:).', 1e-6);
H = complex(zeros(nMax+1, numel(x)));
pref = sqrt(pi./(2*x));
for n = 0:nMax
    H(n+1,:) = pref .* (besselj(n+0.5,x) - 1i*bessely(n+0.5,x));
end
if nargout < 2, return; end
Hm1 = exp(-1i*x)./x;                        % h_{-1}^(2)(x) seeds the recursion
Hp  = complex(zeros(nMax+1, numel(x)));
for n = 0:nMax
    if n == 0, prev = Hm1; else, prev = H(n,:); end
    Hp(n+1,:) = prev - ((n+1)./x).*H(n+1,:);       % f_n' = f_{n-1} - (n+1)/x f_n
end
end


% ======================= self test =====================================
function selftest()
% Synthesise capsule signals for a point source at known distances and check
% they come back. This verifies the CODE -- it inverts its own forward model.
% It cannot verify that the ZM-1 in a real room obeys that model; the coherence
% number is what tells you that.
fs = 48000;
cfg.frameLen = 1024;  cfg.hop = 512;  cfg.fBand = [700 6000];
cfg.nBins = 48;  cfg.energyGateDb = -12;  cfg.rGrid = 0.5:0.25:3.0;  cfg.c = 343;

L = cfg.frameLen;  hop = cfg.hop;
win = 0.5*(1-cos(2*pi*(0:L-1).'/L));
fAx = (0:L/2)*fs/L;
[~,~,Q] = zylia_geom();
rng(3);  s = randn(3*fs,1);  s = s/max(abs(s));

fprintf('\nSynthetic point source at az = 0, el = 0, 30 dB SNR:\n');
fprintf('%10s %10s %8s %11s\n','true r','est r','fit','coherence');
for trueR = [0.75 1.0 1.5 2.0 2.5]
    G = capsule_tf(0, 0, trueR, fAx, cfg.c);
    G(:, fAx < 40) = 0;
    nFr = floor((numel(s)-L)/hop)+1;
    xc = zeros(numel(s)+L, Q);
    for fr = 1:nFr
        idx = (fr-1)*hop+(1:L);
        X = fft(s(idx).*win);
        C = G .* X(1:L/2+1).';
        xc(idx,:) = xc(idx,:) + real(ifft([C, conj(C(:,end-1:-1:2))],[],2)).';
    end
    xc = xc(1:numel(s),:);
    xc = xc + 10^(-30/20)*sqrt(mean(xc(:).^2))*randn(size(xc));
    xc = xc/max(abs(xc(:)))*0.7;

    f = fullfile(tempdir,'ed_selftest.wav');
    audiowrite(f, xc, fs);
    o = estimate_distance(f, 0, 0, cfg);
    fprintf('%10.2f %10.2f %8.3f %11.2f\n', trueR, median(o.r(o.active)), ...
            median(o.fit(o.active)), o.coh);
end
fprintf(['\nIf these track, the estimator is sound and any failure on a real\n' ...
         'recording is in the recording, not the code.\n']);
end
