function test_level_ratio
% TEST_LEVEL_RATIO  2026-08-21.
%
% CAN TWO MICS MEASURE DISTANCE ALONG THEIR OWN BASELINE -- the axis where
% triangulation is blind?
%
% Why there is any hope at all. Every method tried so far uses the DIRECTION
% the sound arrives from: parallax, and time-of-arrival difference if the two
% recorders were synced. Both are blind along the baseline for the same reason
% -- on that axis both mics see the source in the same direction, and TDOA
% saturates at B/c for every distance. Direction-based methods cannot work
% there, ever.
%
% LEVEL is not a direction. The direct sound falls off as 1/r, so
%
%       dL = 20*log10(rA / rB)      dB, mic B relative to mic A
%
% depends only on the RATIO of the two distances. And that ratio is largest
% exactly where the parallax is zero: on the baseline axis one mic is a whole
% baseline closer than the other. The two methods are perfectly complementary.
%
%   source 1.5 m from the midpoint, B = 1.0 m
%     broadside (parallax ideal)  : rA = rB            -> dL = 0.00 dB, useless
%     on the axis (parallax zero) : rA = 1.0, rB = 2.0 -> dL = 6.02 dB, strong
%
% Two things cancel for free, which is what makes this worth trying in a room:
%   - the SOURCE LEVEL cancels inside each take's ratio, so it does not matter
%     how hard you clapped. This is what killed DRR, which needed a model of
%     the room; this needs none.
%   - the two mics' unknown GAIN MISMATCH is a constant, so it cancels in the
%     DIFFERENCE between two takes recorded on the same build.
%
% THE TEST. Of the seven usable takes, five have the source EQUIDISTANT from
% both mics and must give the same constant (that constant IS the gain
% mismatch). Two -- the 17 Aug "in front of" pair -- have the source 1.5 m from
% one mic and 1.80 m from the other, and must sit -1.60 and +1.60 dB either
% side of that constant. Five nulls and two signals of opposite sign, all from
% recordings that already exist.
%
% If the two signals come out near +-1.60 dB, the method is real and the only
% remaining question is how far it can be pushed. If they are lost in the
% scatter of the five nulls, it is dead and this file says so.
%
% ====================================================================
% RESULT, 2026-08-21: INCONCLUSIVE. Not dead -- untestable on these files.
%
%   five nulls, 2.5 ms window : mean -3.27 dB, spread 5.70 dB
%   the two signals           : separation -0.18 dB, predicted +3.19 dB
%
% The signal to resolve is 1.6 dB and the scatter on takes that MUST agree is
% 5.7 dB, so this data cannot answer the question either way. Three concrete
% reasons, all fixable at record time and none of them physics:
%   1. THE ZOOM IS CLIPPED on the clap takes (3 and 5 events rejected here;
%      test_clip_check.m found 12937 full-scale samples on one take). A
%      flattened peak carries no level information at all. Drop the Zoom input
%      gain ~12 dB. This alone is why this method could not be tested.
%   2. ONLY 1-2 USABLE TRANSIENTS SURVIVE per take. Clap 20+ times, spaced
%      about a second apart, so the median has something to work with.
%   3. The two mics do not share a clap's fine structure -- normalised
%      waveform correlation is 0.12 to 0.21 and does not improve with a wider
%      search, so it is different early reflections at the two positions, not
%      a lag error. Matching on the ENVELOPE instead cut the null scatter from
%      18 dB to 5.7 dB, which is the number above.
%
% The remaining risk, which no recording fix removes: in a small untreated room
% the first few ms are already early reflections, and those differ between two
% positions 1 m apart. That may cap this method regardless of gain. It is the
% same room physics that closed floor_bounce_distance.m. Re-run this file on a
% properly-gained take with many claps before believing anything either way.
% ====================================================================
%
% Uses the W channel (ACN 0) of each mic only. W is omnidirectional, so this
% measurement does not care which way either mic was pointing -- no yaw, no
% bearing, no steering. Direct sound only: a short window from each transient
% onset, before the floor bounce arrives (3.9 ms for a 1.2 m mic at 1.5 m).
addpath(fullfile(fileparts(mfilename('fullpath')), '..')); setup_paths;   % code + recordings on the path

WIN_MS = [1.5 2.5 4.0];      % direct-sound window lengths to try

T = {
% name                zylia                                      zoom                        posA        posB      src(3D)
'11 Aug front VOICE' '2miczyliafront_(ACN-SN3D-3).wav'        '2miczoomfront.WAV'        [0 -0.5 0] [0 0.5 0] [1.5000 0 0]
'11 Aug back clap'   '2micclapzyliaback_(ACN-SN3D-3).wav'     '2micclapzoomback.WAV'     [0 -0.5 0] [0 0.5 0] [-1.5000 0 0]
'in front of ZYLIA'  '2micdirectfrontzylia1_(ACN-SN3D-3).wav' '2micdirectfrontzoom1.WAV' [0 -0.5 0] [0 0.5 0] [1.5000 -0.5 0]
'in front of ZOOM'   '2micdirectfrontzylia2_(ACN-SN3D-3).wav' '2micdirectfrontzoom2.WAV' [0 -0.5 0] [0 0.5 0] [1.5000 0.5 0]
'centre + elevated'  '2micfrontelzylia_(ACN-SN3D-3).wav'      '2micfrontelzoom.WAV'      [0 -0.5 0] [0 0.5 0] [1.5000 0 0.456]
'LEFT (FB rig)'      '2micleftzylia_(ACN-SN3D-3).wav'         '2micleftzoom.WAV'         [0.5 0 0] [-0.5 0 0] [0 1.5 0]
'RIGHT (BF rig)'     '2micrightzylia_(ACN-SN3D-3).wav'        '2micrightzoom.WAV'        [-0.5 0 0] [0.5 0 0] [0 -1.5 0]
};

fprintf('\n  Direct-sound level of the ZOOM relative to the ZYLIA, W channel only.\n');
fprintf('  "pred" is what 1/r geometry demands. Only the RELATIVE spacing of the\n');
fprintf('  rows is meaningful -- a constant offset on all of them is the two\n');
fprintf('  mics'' gain mismatch and carries no distance information.\n\n');
fprintf('%-20s %6s %6s %7s', 'take', 'rA', 'rB', 'pred');
for w = WIN_MS, fprintf(' %8s', sprintf('%.1fms', w)); end
fprintf(' %5s %5s %5s %6s\n', 'used', 'clip', 'badX', 'MAD');
fprintf('%s\n', repmat('-', 1, 84));

pred = nan(size(T,1),1);  meas = nan(size(T,1), numel(WIN_MS));
scat = nan(size(T,1),1);
for k = 1:size(T,1)
    rA = norm(T{k,6} - T{k,4});
    rB = norm(T{k,6} - T{k,5});
    pred(k) = 20*log10(rA/rB);

    al = align_two_mics(T{k,2}, T{k,3}, 'verbose', false);
    [wa, fa] = readW(T{k,2});
    [wb, fb] = readW(T{k,3});

    if fa ~= fb
        wb = resample(wb, fa, fb);  fb = fa;
    end
    on = find_onsets(wa, fa, al.overlap(1), al.overlap(2));

    fprintf('%-20s %6.3f %6.3f %+7.2f', T{k,1}, rA, rB, pred(k));
    nUsed = 0;  nClip = 0;  nBadX = 0;
    for j = 1:numel(WIN_MS)
        d = nan(numel(on),1);
        for i = 1:numel(on)
            % refine mic B's copy of THIS transient by local cross-correlation.
            % align_two_mics is accurate to a frame, not a sample, and a 2 ms
            % measurement window cannot survive that -- this was the whole
            % reason the first run of this file scattered the nulls by 18 dB.
            [lag, q] = refine_lag(wa, wb, fa, on(i), al.offset);
            if isnan(lag) || q < 0.30, nBadX = nBadX + 1; continue; end
            % A CLIPPED window has no level information at all. The Zoom is
            % slammed on every clap take (test_clip_check.m: 12937 samples at
            % full scale on one of them), and a flattened peak makes the RMS
            % ratio meaningless -- this is what scattered the per-clap values
            % by 12-19 dB WITHIN a single take on the previous run.
            if seg_clipped(wa, fa, on(i), WIN_MS(j)) || ...
               seg_clipped(wb, fb, on(i)+lag, WIN_MS(j))
                nClip = nClip + 1;  continue;
            end
            ea = seg_rms(wa, fa, on(i),       WIN_MS(j));
            eb = seg_rms(wb, fb, on(i) + lag, WIN_MS(j));
            if ea > 0 && eb > 0, d(i) = 20*log10(eb/ea); end
        end
        d = d(~isnan(d));
        if isempty(d)
            fprintf(' %8s', '--');
        else
            fprintf(' %+8.2f', median(d));  meas(k,j) = median(d);
            if j == 2, scat(k) = median(abs(d - median(d))); end
        end
        nUsed = max(nUsed, numel(d));
    end
    fprintf(' %5d %5d %5d %6.2f\n', nUsed, nClip, nBadX, scat(k));
end

fprintf('%s\n', repmat('-', 1, 84));
isNull = abs(pred) < 0.01;
fprintf('\n  THE FIVE NULLS (source equidistant -- these must all agree):\n');
for j = 1:numel(WIN_MS)
    v = meas(isNull, j);  v = v(~isnan(v));
    fprintf('    %.1f ms window : mean %+6.2f dB, spread %.2f dB  <- the gain mismatch\n', ...
            WIN_MS(j), mean(v), std(v));
end
fprintf('\n  THE TWO SIGNALS (source 1.50 m from one mic, 1.80 m from the other):\n');
iZ = find(strcmp(T(:,1),'in front of ZYLIA'));
iM = find(strcmp(T(:,1),'in front of ZOOM'));
fprintf('%14s %10s %10s %12s %12s\n','window','ZYLIA','ZOOM','separation','predicted');
for j = 1:numel(WIN_MS)
    v = meas(isNull, j);  g = mean(v(~isnan(v)));
    sep = meas(iM,j) - meas(iZ,j);
    fprintf('%14s %+10.2f %+10.2f %+12.2f %+12.2f\n', sprintf('%.1f ms', WIN_MS(j)), ...
            meas(iZ,j)-g, meas(iM,j)-g, sep, pred(iM)-pred(iZ));
end
fprintf(['\n  The "separation" column is the one that matters: the gain mismatch\n' ...
         '  cancels in it exactly. If it lands near the predicted value and well\n' ...
         '  outside the spread of the nulls, level ranging on the blind axis is\n' ...
         '  worth building. If not, it is dead.\n\n']);
end


% ===================== helpers ========================================
function [w, fs] = readW(f)
% W channel (ACN 0) only -- omnidirectional, so no bearing or yaw is involved
[x, fs] = audioread(f);
w = x(:,1);
end

function on = find_onsets(w, fs, t0, t1)
% transient onsets inside the aligned overlap, at least 0.3 s apart
i0 = max(1, round(t0*fs));  i1 = min(numel(w), round(t1*fs));
seg = w(i0:i1);
env = movmax(abs(seg), round(0.002*fs));
thr = max(0.35*max(env), 6*median(env));
cand = find(env(2:end) >= thr & env(1:end-1) < thr) + 1;
on = [];  last = -inf;
for c = cand(:).'
    if (c - last) > 0.30*fs
        % back up to the true onset, where the envelope first lifts off the floor
        b = max(1, c - round(0.005*fs));
        loc = find(abs(seg(b:c)) > 0.15*env(c), 1, 'first');
        if isempty(loc), loc = c - b + 1; end
        on(end+1) = (i0 + b + loc - 2)/fs;   %#ok<AGROW>
        last = c;
    end
end
end

function [lag, q] = refine_lag(wa, wb, fs, tOn, coarse)
% Where does mic A's transient at tOn sit in mic B?
%
% NOT by cross-correlating the waveforms. Two mics 1 m apart in a live room do
% not share a clap's fine structure -- measured normalised correlation is only
% 0.12 to 0.21, and widening the search from 40 ms to 800 ms does not improve
% it, so this is genuinely different waveforms and not a lag problem. Different
% early reflections at the two positions, plus two different mic responses.
%
% The ENVELOPE does survive the trip. Match on that, then measure RMS on the
% raw signal from the matched onset.
pre = round(0.003*fs);  post = round(0.020*fs);
srch = round(0.040*fs);
q = 0;
a0 = round(tOn*fs) - pre;  a1 = round(tOn*fs) + post;
b0 = round((tOn + coarse)*fs) - pre - srch;
b1 = round((tOn + coarse)*fs) + post + srch;
if a0 < 1 || a1 > numel(wa) || b0 < 1 || b1 > numel(wb), lag = NaN; return; end
p = envel(wa(a0:a1), fs);   p = p - mean(p);
r = envel(wb(b0:b1), fs);   r = r - mean(r);
if norm(p) <= 0 || norm(r) <= 0, lag = NaN; return; end
[c, l] = xcorr(r, p);
[pk, ix] = max(c);
if pk <= 0, lag = NaN; return; end
st = l(ix) + 1;  en = st + numel(p) - 1;
if st < 1 || en > numel(r), lag = NaN; return; end
sl = r(st:en);
if norm(sl) <= 0, lag = NaN; return; end
q = (p.' * sl) / (norm(p) * norm(sl));
lag = (b0 - a0 + l(ix))/fs;
end

function e = envel(x, fs)
% smoothed amplitude envelope, 0.5 ms window
e = movmean(abs(x), max(3, round(0.0005*fs)));
end

function tf = seg_clipped(w, fs, tOn, winMs)
a = round(tOn*fs);  b = a + round(winMs*1e-3*fs);
if a < 1 || b > numel(w), tf = true; return; end
tf = any(abs(w(a:b)) > 0.985);
end

function r = seg_rms(w, fs, tOn, winMs)
% RMS of the direct arrival: winMs starting at the onset, before the floor bounce
a = round(tOn*fs);
b = a + round(winMs*1e-3*fs);
if a < 1 || b > numel(w), r = 0; return; end
r = sqrt(mean(w(a:b).^2));
end
