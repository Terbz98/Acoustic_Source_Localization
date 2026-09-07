function m = az_power_map(cfg)
% AZ_POWER_MAP  Accumulated SRP power versus azimuth for ONE microphone.
%
%   m = az_power_map(cfg)   with the same cfg fields run_doa.m uses
%       (wavFile inFormat order micRadius frameLen hop fBand nBins
%        energyGateDb azGrid elGrid rGrid c), plus optional cfg.tWindow =
%       [t0 t1] in seconds to analyse only part of the file.
%
%   m.az       azimuth grid (rad), copied from cfg.azGrid
%   m.P        accumulated power, normalised to peak 1
%   m.Pframe   nAz x nFrames, one normalised map per active frame
%   m.w        1 x nFrames weight of each frame (how decisive its map was)
%   m.azPeak   peak azimuth (deg, wrapped to +-180)
%   m.elPeak   peak elevation (deg)
%   m.nFrames  number of frames that passed the energy gate
%   m.snrDb    loudest frame over the file's own noise floor
%
%   WHY THIS EXISTS, AND WHY IT IS NOT run_doa
%   run_doa.m reports the ARGMAX of each frame -- one angle per frame, and
%   everything else in the map is thrown away. That is the right output for
%   direction. For triangulation it is wasteful: a frame whose peak is a few
%   degrees off still carries a perfectly good ridge of evidence, and two mics
%   can agree on a source position even when neither one's argmax lands on it.
%
%   So this keeps the whole map. triangulate.m then multiplies the two mics'
%   maps over a grid of candidate source POSITIONS, which is a far more stable
%   estimator than intersecting two single bearings: a noisy frame widens the
%   ridge instead of moving the answer.
%
%   Each frame's map is contrast-normalised before accumulating, so a loud
%   syllable does not outvote a quiet one, and then WEIGHTED by how decisive
%   that frame's map actually is (peak height above its own median). A frame
%   full of room noise produces a nearly flat map and is almost ignored; a
%   frame with a clean direct arrival produces a sharp ridge and dominates.
%   This is what keeps quiet takes from being dragged around by their pauses.
%
%   Frames are also gated against the file's own NOISE FLOOR (cfg.snrGateDb,
%   default 10 dB), estimated from its quietest frames -- not just against the
%   loudest frame. A take whose speech sits 12 dB over the noise and one whose
%   speech sits 40 dB over it need different thresholds, and the relative gate
%   alone cannot tell them apart.
%
%   run_doa.m is untouched by all of this -- the validated azimuth/elevation
%   path is exactly as it was.

[x, fs] = audioread(cfg.wavFile);
if isfield(cfg, 'tWindow') && ~isempty(cfg.tWindow)
    i0 = max(1, round(cfg.tWindow(1)*fs) + 1);
    i1 = min(size(x,1), round(cfg.tWindow(2)*fs));
    if i1 <= i0
        error('cfg.tWindow = [%g %g] s selects nothing in "%s".', ...
              cfg.tWindow(1), cfg.tWindow(2), cfg.wavFile);
    end
    x = x(i0:i1, :);
end

% Frames containing a clipped sample are dropped outright. The Zoom H3-VR
% clips on every clap, and a clipped transient does not just add noise -- it
% flattens the peaks that carry the level differences between channels, so the
% bearing it produces is confidently wrong. Dropping those frames is what lets
% cfg.tWindow be optional: the claps remove themselves.
isClip = any(abs(x) > 0.985, 2);

b = convert_to_acn_n3d(x, cfg.inFormat, cfg.order);

L   = cfg.frameLen;  hop = cfg.hop;
win = 0.5*(1 - cos(2*pi*(0:L-1).'/L));
fAx = (0:L/2)*fs/L;
inBand = find(fAx >= cfg.fBand(1) & fAx <= cfg.fBand(2));
if isempty(inBand)
    error('No FFT bins inside cfg.fBand = [%g %g] Hz.', cfg.fBand);
end
sel   = unique(inBand(round(linspace(1, numel(inBand), min(cfg.nBins, numel(inBand))))));
freqs = fAx(sel);

[W, grid] = build_steering_matrix(cfg, freqs);

nFr = floor((size(b,1) - L)/hop) + 1;
if nFr < 1
    error('Segment shorter than one frame (%d samples) in "%s".', L, cfg.wavFile);
end

omni = b(:,1);
E = zeros(nFr,1);
for fr = 1:nFr
    idx = (fr-1)*hop + (1:L);
    Fo = fft(omni(idx).*win);
    E(fr) = sqrt(mean(abs(Fo(sel)).^2));
end
if isfield(cfg, 'snrGateDb'), snrGate = cfg.snrGateDb; else, snrGate = 10; end
noise = quantile(E, 0.10);                       % this file's own floor
% Reference the relative gate to a ROBUST loud level, not to the single
% loudest frame. A clap sits ~25 dB above speech, so gating at -25 dB below
% max(E) on a clap take throws away the speech -- exactly the material we
% want. The 95th percentile ignores a handful of transients.
loud  = quantile(E, 0.95);
gate  = max(loud * 10^(cfg.energyGateDb/20), noise * 10^(snrGate/20));

nAz = numel(cfg.azGrid);
nEl = numel(cfg.elGrid);
Pacc   = zeros(nAz,1);
Eacc   = zeros(nEl,1);
Pframe = zeros(nAz, nFr);
wFrame = zeros(1, nFr);
active = false(nFr,1);

nClip = 0;
for fr = 1:nFr
    idx = (fr-1)*hop + (1:L);
    if any(isClip(idx)), nClip = nClip + 1; continue; end
    if E(fr) < gate, continue; end
    F  = fft(b(idx,:).*win);
    Bf = F(sel,:).';

    P = zeros(size(W,2),1);
    for fi = 1:numel(freqs)
        P = P + abs(W(:,:,fi)' * Bf(:,fi)).^2;
    end
    P3 = reshape(P, grid.size);              % nAz x nEl x nR
    pAz = max(reshape(P3, nAz, []), [], 2);  % marginalise el and r by the peak
    pEl = max(reshape(permute(P3, [2 1 3]), nEl, []), [], 2);

    % how decisive is this frame? peak height above its own median, relative to
    % the median. Flat map (diffuse noise) -> ~0. Sharp ridge -> large.
    md = median(pAz);
    w  = (max(pAz) - md) / max(md, eps);

    % contrast-normalise: 0 at its own floor, 1 at its own peak
    lo = min(pAz);  hi = max(pAz);
    if hi > lo
        pAz = (pAz - lo)/(hi - lo);
    else
        pAz = zeros(nAz,1);  w = 0;
    end
    lo = min(pEl);  hi = max(pEl);
    if hi > lo, pEl = (pEl - lo)/(hi - lo); else, pEl = zeros(nEl,1); end

    Pframe(:,fr) = pAz;
    wFrame(fr)   = w;
    Pacc = Pacc + w*pAz;
    Eacc = Eacc + w*pEl;
    active(fr) = true;
end

if ~any(active) || all(wFrame == 0)
    error(['No usable frames in "%s". Either everything was below the gate, ' ...
           'or every frame produced a flat (undirectional) map.'], cfg.wavFile);
end

m.az      = cfg.azGrid(:);
m.P       = Pacc / max(Pacc);
m.Pframe  = Pframe(:, active);
m.w       = wFrame(active);
m.nFrames = nnz(active);
m.t       = ((find(active)-1)*hop + L/2)/fs;
m.fs      = fs;
m.snrDb   = 20*log10(max(E)/max(noise, eps));
m.nClip   = nClip;
m.frameIdx = find(active);
% The threshold actually used, expressed the way run_doa.m wants it: dB
% relative to the loudest frame. Passing this straight into run_doa's
% cfg.energyGateDb makes it select the same frames we did, including the
% noise-floor guard that run_doa has no notion of.
m.gateRelMaxDb = 20*log10(gate/max(max(E), eps));
[~, ip]   = max(m.P);
m.azPeak  = mod(rad2deg(cfg.azGrid(ip)) + 180, 360) - 180;
m.Pel     = Eacc / max(Eacc);
[~, ie]   = max(m.Pel);
m.elPeak  = rad2deg(cfg.elGrid(ie));
end
