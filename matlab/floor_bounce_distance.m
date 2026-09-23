function out = floor_bounce_distance(file, micHeight, varargin)
% FLOOR_BOUNCE_DISTANCE  Range from a single mic using the floor reflection.
%
%   out = floor_bounce_distance(file, micHeight)
%   out = floor_bounce_distance(file, micHeight, 'band', [500 5000])
%       file      : ambisonic wav (the _(ACN-SN3D-*) one), containing ONE clap
%       micHeight : height of the mic above the floor, in metres. MEASURE IT.
%                   Pass [] to scan a range of plausible heights instead.
%
%   THE IDEA
%   A reflection off the floor is sound from an IMAGE SOURCE the same distance
%   below the floor as the real one is above it. So a single mic that hears
%   both the direct sound and the bounce is effectively hearing two viewpoints,
%   and the delay between them fixes the range. With the direct elevation and
%   the mic height known, the reflection DELAY alone gives the distance:
%
%       tau = ( sqrt(d^2 + (hs+hm)^2) - sqrt(d^2 + (hs-hm)^2) ) / c
%       hs  = hm + d*tan(el_direct)
%
%   Solving for d needs no reflection angle at all, which matters because the
%   reflection's angle is the one quantity that cannot be measured reliably --
%   it overlaps the direct sound and any estimate of it is a blend of the two.
%
%   WHAT IT NEEDS FROM THE RECORDING
%     * a HARD, BARE floor. Carpet or acoustic treatment kills the reflection,
%       and then there is simply nothing to measure.
%     * an IMPULSIVE source -- a clap or a balloon. Not speech: a voice's own
%       pitch periodicity swamps the echo in the autocorrelation.
%     * mic and source at least 1 m from every OTHER surface, so the floor
%       bounce is the only strong early reflection.
%
%   READ out.reflectionStrength BEFORE READING out.r. It is the height of the
%   echo peak in the clap's autocorrelation. A bare hard floor at 1.5 m gives
%   about 0.4. Below about 0.25 there is no distinct reflection in the file and
%   out.r is fitted to noise -- the function says so rather than returning a
%   confident-looking number.

p = inputParser;
p.addParameter('band', [500 5000]);
p.addParameter('tauRange', [1.5 12]);      % ms
p.addParameter('c', 343);
p.addParameter('verbose', true);
p.parse(varargin{:});
o = p.Results;

[x, fs] = audioread(file);
b1 = convert_to_acn_n3d(x, 'ambix', 1);              % W Y Z X, N3D
[bb, aa] = butter(4, o.band/(fs/2), 'bandpass');
b1 = filtfilt(bb, aa, b1);

% ---- locate the clap -----------------------------------------------------
w = abs(b1(:,1));
[~, ip] = max(w);
sr = max(1, ip-round(0.020*fs)) : ip;
k  = find(w(sr) >= 0.25*w(ip), 1, 'first');
if isempty(k)
    error('Could not find a clap onset in "%s".', file);
end
n0 = sr(1) + k - 1;
out.clapTime = n0/fs;

seg = b1(n0 : min(size(b1,1), n0+round(0.030*fs)), :);
pw  = seg(:,1);
g   = seg(:,[4 2 3]) / sqrt(3);                      % X Y Z, so g = u*p

% ---- direct direction ----------------------------------------------------
d1 = round(0.001*fs);
I  = sum(pw(1:d1) .* g(1:d1,:), 1);
out.azDirect = atan2d(I(2), I(1));
out.elDirect = atan2d(I(3), hypot(I(1), I(2)));

% ---- reflection delay from the autocorrelation ---------------------------
n  = 2^nextpow2(4*numel(pw));
P  = fft(pw, n);
R  = real(ifft(P .* conj(P)));
R  = R(1:round(0.020*fs)+1) / R(1);
lagMs = (0:numel(R)-1).'/fs*1000;
band  = lagMs >= o.tauRange(1) & lagMs <= o.tauRange(2);
[pk, kk] = max(R .* band);
out.tau  = lagMs(kk)/1000;
out.reflectionStrength = pk;
out.acf = R;  out.acfLagMs = lagMs;

% how much of that peak is just noise? compare against the spread of the ACF
% away from any plausible echo
ref = R(lagMs > o.tauRange(2) & lagMs < 20);
out.acfNoise = 3*std(ref);

% ---- solve for distance --------------------------------------------------
if isempty(micHeight)
    hs = 0.8:0.1:1.8;
else
    hs = micHeight(:).';
end
out.micHeights = hs;
out.rByHeight  = nan(size(hs));
for i = 1:numel(hs)
    d = solve_d(out.tau, out.elDirect, hs(i), o.c);
    if ~isnan(d)
        out.rByHeight(i) = hypot(d, d*tand(out.elDirect));
    end
end
out.r = out.rByHeight(1);
if numel(hs) > 1
    out.r = median(out.rByHeight(~isnan(out.rByHeight)));
end

out.usable = out.reflectionStrength > 0.25 && ...
             out.reflectionStrength > 2*out.acfNoise;

if o.verbose
    fprintf('\nFloor bounce: %s\n', file);
    fprintf('  clap at        : %.3f s\n', out.clapTime);
    fprintf('  direct         : az %.1f  el %.1f deg\n', out.azDirect, out.elDirect);
    fprintf('  echo peak      : %.2f ms, strength %.3f (noise level %.3f)\n', ...
            out.tau*1000, out.reflectionStrength, out.acfNoise);
    if numel(hs) > 1
        fprintf('  distance vs assumed mic height:\n');
        for i = 1:numel(hs)
            fprintf('     h = %.1f m  ->  r = %.2f m\n', hs(i), out.rByHeight(i));
        end
    else
        fprintf('  DISTANCE       : %.2f m  (mic height %.2f m)\n', out.r, hs);
    end
    if out.usable
        fprintf('  VERDICT        : usable\n');
    else
        fprintf(['  VERDICT        : NO USABLE REFLECTION. The strongest echo in\n' ...
                 '  the %.0f-%.0f ms window is %.3f, at or below the %.3f noise level of\n' ...
                 '  this same autocorrelation. A bare hard floor at 1.5 m would give\n' ...
                 '  about 0.4. There is no discrete floor bounce in this recording to\n' ...
                 '  measure -- the room is absorbing it. Any r above is fitted to noise.\n' ...
                 '  Re-record over a BARE HARD floor, mic and clap >1 m from every\n' ...
                 '  other surface.\n'], o.tauRange(1), o.tauRange(2), ...
                 out.reflectionStrength, out.acfNoise);
    end
end
end


function d = solve_d(tau, elDeg, hm, c)
% tau(d) rises monotonically from 0, so a bisection is safe.
f = @(dd) (hypot(dd, 2*hm + dd*tand(elDeg)) - hypot(dd, dd*tand(elDeg)))/c - tau;
lo = 0.05;  hi = 40;  d = NaN;
if ~isfinite(f(lo)) || ~isfinite(f(hi)) || f(lo)*f(hi) > 0, return; end
for i = 1:100
    mid = 0.5*(lo+hi);
    if f(lo)*f(mid) <= 0, hi = mid; else, lo = mid; end
end
d = 0.5*(lo+hi);
end
