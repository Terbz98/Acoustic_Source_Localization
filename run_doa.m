function res = run_doa(cfg)

[x, fs] = audioread(cfg.wavFile);
b = convert_to_acn_n3d(x, cfg.inFormat, cfg.order);



L   = cfg.frameLen;
hop = cfg.hop;
win = 0.5 * (1 - cos(2 * pi * (0:L-1).' / L));

fAx    = (0:L/2) * fs / L;
inBand = find(fAx >= cfg.fBand(1) & fAx <= cfg.fBand(2));
if isempty(inBand)
    error('No FFT bins inside cfg.fBand = [%g %g] Hz.', cfg.fBand);
end
sel   = unique(inBand(round(linspace(1, numel(inBand), min(cfg.nBins, numel(inBand))))));
freqs = fAx(sel);

% Report the array order cut-on so the analysis band can be sanity-checked
% against the physics of the mic (see build_steering_matrix for details).
if isfield(cfg, 'micRadius') && cfg.micRadius > 0
    fCutTop = cfg.order * cfg.c / (2*pi*cfg.micRadius);
    fprintf('Array order cut-on: order %d valid above %.0f Hz (micRadius = %.3f m).\n', ...
            cfg.order, fCutTop, cfg.micRadius);
    if cfg.fBand(2) < fCutTop
        warning(['cfg.fBand = [%g %g] Hz lies ENTIRELY below the order-%d cut-on ' ...
                 '(%.0f Hz). Every order-%d channel is noise in this band, so the ' ...
                 'high-order info you paid for is unused. Raise cfg.fBand(2) above ' ...
                 '%.0f Hz, or lower cfg.order.'], cfg.fBand(1), cfg.fBand(2), ...
                 cfg.order, fCutTop, cfg.order, fCutTop);
    elseif cfg.fBand(1) < fCutTop
        fprintf(['  fBand starts below this cut-on; frequency-dependent order is ON, ' ...
                 'so\n  low bins automatically fall back to a reduced order.\n']);
    end
end

fprintf('Precomputing steering matrix: %d x %d x %d grid, %d bins ...\n', numel(cfg.azGrid), numel(cfg.elGrid), numel(cfg.rGrid), numel(freqs));
tic;
[W, grid] = build_steering_matrix(cfg, freqs);
fprintf('  done in %.1f s (this cost is paid once, offline).\n', toc);

nAz = numel(cfg.azGrid);
nEl = numel(cfg.elGrid);
nR  = numel(cfg.rGrid);
dAz = cfg.azGrid(2) - cfg.azGrid(1);
% dAz = 0;
if nEl > 1, dEl = cfg.elGrid(2) - cfg.elGrid(1); end
if nR  > 1, dR  = cfg.rGrid(2)  - cfg.rGrid(1);  end


nFrames = floor((size(b, 1) - L) / hop) + 1;
if nFrames < 1
    error('Recording shorter than one frame (%d samples).', L);
end

omni     = b(:, 1);
frameRms = zeros(nFrames, 1);
for fr = 1:nFrames
    idx = (fr - 1) * hop + (1:L);
    Fo  = fft(omni(idx) .* win);
    frameRms(fr) = sqrt(mean(abs(Fo(sel)).^2));
end
gate = max(frameRms) * 10^(cfg.energyGateDb / 20);


res.fs     = fs;
res.freqs  = freqs;
res.grid   = grid;
res.t      = ((0:nFrames-1)' * hop + L/2) / fs;
res.azDeg  = nan(nFrames, 1);
res.elDeg  = nan(nFrames, 1);
res.r      = nan(nFrames, 1);
res.active = false(nFrames, 1);

bestPow = -inf;

engW   = 0;
engDir = 0;

for fr = 1:nFrames
    if frameRms(fr) < gate
        continue;                                  % skip near-silence
    end
    idx = (fr - 1) * hop + (1:L);

    F  = fft(b(idx, :) .* win);                    % L x nCh
    Bf = F(sel, :).';                              % nCh x nBins

    engW   = engW   + sum(abs(Bf(1, :)).^2);
    if size(Bf, 1) >= 4
        engDir = engDir + sum(abs(Bf(2:4, :)).^2, 'all') / 3;
    end

    % SRP: P = diag(W^H Rxx W)
    P = zeros(size(W, 2), 1);
    for fi = 1:numel(freqs)
        P = P + abs(W(:, :, fi)' * Bf(:, fi)).^2;
    end


    P3 = reshape(P, grid.size);                    % nAz x nEl x nR
    [pk, im] = max(P);
    % fprintf('Max P  %d (%d index).\n', grid.size, im);
    [ia, ie, ir] = ind2sub(grid.size, im);


    % Azimuth
    Pm = P3(mod(ia - 2, nAz) + 1, ie, ir);
    Pp = P3(mod(ia,     nAz) + 1, ie, ir);
    azF = parab(cfg.azGrid(ia), dAz, Pm, P3(ia, ie, ir), Pp);
    res.azDeg(fr) = mod(rad2deg(azF), 360);

    % Elevation
    if nEl > 2 && ie > 1 && ie < nEl
        elF = parab(cfg.elGrid(ie), dEl, P3(ia, ie-1, ir), P3(ia, ie, ir), P3(ia, ie+1, ir));
    else
        elF = cfg.elGrid(ie);
    end
    res.elDeg(fr) = rad2deg(elF);

    % Distance
    if nR > 2 && ir > 1 && ir < nR
        rF = parab(cfg.rGrid(ir), dR, P3(ia, ie, ir-1), P3(ia, ie, ir), P3(ia, ie, ir+1));
    else
        rF = cfg.rGrid(ir);
    end
    res.r(fr) = rF;

    res.active(fr) = true;

    % keep the strongest
    if pk > bestPow
        bestPow      = pk;
        res.mapP3    = P3;
        res.mapFrame = fr;
        res.mapIdx   = [ia, ie, ir];
    end
end

fprintf('Processed %d frames (%d active after energy gate).\n', nFrames, nnz(res.active));
if engW > 0
    ratio = engDir / engW;
    res.dirOverOmni = ratio;
    if ratio > 1.5
        warning(['In-band directional/omni energy ratio = %.1f, but it can ' ...
                 'never exceed ~1 for real airborne sound (SN3D). The ' ...
                 'recording is contaminated (mic-stand vibration, rumble, ' ...
                 'handling noise) or the channel convention is wrong. ' ...
                 'Try raising cfg.fBand(1), and check the rig before the ' ...
                 'next take.'], ratio);
    end
end
end



function xFine = parab(x0, dx, Pm, P0, Pp)

%   x_fine = x_peak - dx * (P(+1) - P(-1)) / (2P(+1) - 4P(peak) + 2P(-1))
den = 2*Pp - 4*P0 + 2*Pm;
if abs(den) < eps * max([abs(Pm), abs(P0), abs(Pp), 1])
    xFine = x0;  
else
    off   = -(Pp - Pm) / den;
    off   = max(min(off, 1), -1);
    xFine = x0 + off * dx;
end
end
