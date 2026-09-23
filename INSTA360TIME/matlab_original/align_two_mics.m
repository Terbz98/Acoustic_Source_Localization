function out = align_two_mics(fileA, fileB, varargin)
% ALIGN_TWO_MICS  Put two independently-started recordings on one clock.
%
%   out = align_two_mics(fileA, fileB)
%   out = align_two_mics(fileA, fileB, 'maxLag', 15, 'band', [300 3500])
%
%   out.offset    seconds to ADD to a time in file A to get the same instant
%                 in file B:   tB = tA + out.offset
%                 Positive means B was already rolling when A started.
%   out.overlap   [t0 t1] in A's clock where both files have audio
%   out.r         peak correlation (how confident the match is)
%   out.clapA/B   the transient used for the fine refinement, if one was found
%   out.refinedMs how far the clap moved the estimate off the envelope answer
%
%   HOW IT WORKS, AND WHY THE CLAP IS THE RIGHT ANCHOR
%   Step 1 is a coarse match on the loudness envelope. Both mics heard the same
%   room, so their envelopes rise and fall together even though their gains,
%   frequency responses and channel counts are nothing alike. Cross-correlating
%   the two envelopes finds the offset to within a few tens of milliseconds.
%
%   Step 2 refines that with the clap. A clap is a single sharp event, so once
%   the coarse offset has told us roughly where to look, matching the waveform
%   itself pins the offset to the sample. Speech cannot do this on its own --
%   it is quasi-periodic, so a correlator will happily lock onto the wrong
%   syllable one pitch period away.
%
%   WORTH KNOWING: bearing-only triangulation does NOT need this. Each mic's
%   direction is computed from its own file over whatever window contains the
%   source, and a static source gives the same bearing whichever window you
%   pick. Alignment matters for choosing matching windows, for checking that
%   the two files really are the same take, and for any per-frame comparison.
%   Do not let a poor alignment score make you distrust a good bearing.
%
%   Works with any channel counts: 19-channel raw capsules are averaged to an
%   omni, ambisonic files use their W channel.

p = inputParser;
p.addParameter('maxLag', 15);          % seconds
p.addParameter('band', [300 3500]);
p.addParameter('envRate', 500);        % Hz
p.addParameter('verbose', true);
p.parse(varargin{:});
o = p.Results;

[wA, fsA] = local_omni(fileA);
[wB, fsB] = local_omni(fileB);
if fsA ~= fsB
    error(['Sample rates differ: "%s" is %d Hz, "%s" is %d Hz. Resample one ' ...
           'before aligning.'], fileA, fsA, fileB, fsB);
end
fs = fsA;

eA = local_env(wA, fs, o.band, o.envRate);
eB = local_env(wB, fs, o.band, o.envRate);

[lag, r] = local_xcorr(eA, eB, round(o.maxLag*o.envRate));
offset = lag / o.envRate;

% ---- fine refinement on the sharpest shared transient -------------------
out.clapA = NaN;  out.clapB = NaN;  out.refinedMs = NaN;
[tA, sharp] = local_transient(wA, fs, o.band);
if ~isnan(tA) && sharp > 8
    W  = round(0.050*fs);                 % +-50 ms around the transient
    S  = round(0.060*fs);                 % +-60 ms of search
    iA = round(tA*fs);
    a0 = max(1, iA-W);  a1 = min(numel(wA), iA+W);
    seg = wA(a0:a1);
    jB  = round((tA + offset)*fs);
    b0  = max(1, jB-W-S);  b1 = min(numel(wB), jB+W+S);
    if (b1-b0+1) > numel(seg)
        ref = wB(b0:b1);
        c   = local_normxcorr(ref, seg);
        [~, k] = max(abs(c));
        fine = (b0 + k - 1) - a0;
        newOff = fine/fs;
        if abs(newOff - offset) < 0.25          % only trust a small correction
            out.refinedMs = (newOff - offset)*1000;
            offset = newOff;
            out.clapA = tA;  out.clapB = tA + offset;
        end
    end
end

durA = numel(wA)/fs;  durB = numel(wB)/fs;
t0 = max(0, -offset);
t1 = min(durA, durB - offset);

out.offset  = offset;
out.overlap = [t0 t1];
out.r       = r;
out.fs      = fs;
out.durA    = durA;
out.durB    = durB;

if o.verbose
    fprintf('\nAlignment: %s  <->  %s\n', fileA, fileB);
    fprintf('  durations      : %.2f s and %.2f s\n', durA, durB);
    fprintf('  offset         : %+.4f s   (tB = tA %+.4f)\n', offset, offset);
    if ~isnan(out.refinedMs)
        fprintf('  clap refinement: %+.1f ms off the envelope estimate (clap at tA = %.3f s)\n', ...
                out.refinedMs, out.clapA);
    else
        fprintf('  clap refinement: none (no sharp shared transient found)\n');
    end
    fprintf('  envelope match : r = %.3f\n', r);
    fprintf('  usable overlap : %.2f .. %.2f s in A''s clock (%.2f s)\n', t0, t1, t1-t0);
    if t1 - t0 < 1
        warning('Overlap is under 1 s -- check these two files are the same take.');
    end
    if r < 0.25
        fprintf(['  NOTE: weak envelope match. For bearing-only triangulation this is\n' ...
                 '  not fatal -- see the header. Check the overlap window looks sane.\n']);
    end
end
end


% ===================== helpers =========================================
function [w, fs] = local_omni(file)
[x, fs] = audioread(file);
if size(x,2) == 19
    w = mean(x, 2);          % raw ZM-1 capsules -> omni
else
    w = x(:,1);              % ambisonic W
end
end

function e = local_env(w, fs, band, rate)
[b,a] = butter(4, band/(fs/2), 'bandpass');
y = filtfilt(b, a, w);
e = abs(hilbert(y));
q = max(1, round(fs/rate));
e = e(1:q:end);
end

function [lag, r] = local_xcorr(a, b, maxlag)
a = a(:) - mean(a);  b = b(:) - mean(b);
a = a/(norm(a)+eps);  b = b/(norm(b)+eps);
n = 2^nextpow2(numel(a)+numel(b));
c = ifft(fft(b,n).*conj(fft(a,n)));
c = [c(n-numel(a)+2:n); c(1:numel(b))];
lags = (-(numel(a)-1):(numel(b)-1)).';
keep = abs(lags) <= maxlag;
c = c(keep);  lags = lags(keep);
[r, i] = max(real(c));
lag = lags(i);
if i > 1 && i < numel(c)
    d  = real(c(i+1)) - real(c(i-1));
    dd = 2*real(c(i)) - real(c(i+1)) - real(c(i-1));
    if abs(dd) > eps, lag = lag + 0.5*d/dd; end
end
end

function [t, sharp] = local_transient(w, fs, band)
% sharpest onset: biggest jump over the preceding 250 ms
[b,a] = butter(4, band/(fs/2), 'bandpass');
y = abs(filtfilt(b, a, w));
L = round(0.005*fs);
n = floor(numel(y)/L);
e = max(reshape(y(1:n*L), L, n), [], 1).';
edb = 20*log10(max(e, eps));
k = round(0.25/(L/fs));
best = -inf;  t = NaN;
for i = k+1:numel(edb)
    jump = edb(i) - max(edb(i-k:i-1));
    if jump > best && edb(i) > max(edb) - 12
        best = jump;  t = (i-1)*L/fs;
    end
end
sharp = best;
end

function c = local_normxcorr(ref, seg)
seg = seg(:) - mean(seg);
n = numel(seg);
c = zeros(numel(ref)-n+1, 1);
ns = norm(seg) + eps;
cs = [0; cumsum(ref(:))];  cs2 = [0; cumsum(ref(:).^2)];
full = conv(ref(:), flipud(seg), 'valid');
for i = 1:numel(c)
    s  = cs(i+n) - cs(i);
    s2 = cs2(i+n) - cs2(i);
    v  = sqrt(max(s2 - s^2/n, 0)) + eps;
    c(i) = full(i) / (ns*v);
end
end
