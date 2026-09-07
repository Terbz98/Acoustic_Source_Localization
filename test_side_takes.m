function test_side_takes
% TEST_SIDE_TAKES  2026-08-21.
%
% "left and right are still wrong -- what might be wrong and how do I fix it
%  in future recordings, is it the setup or what?"
%
% Recomputes both side takes from scratch, because the -3.4/+15.4 and
% -4.4/+9.4 per-mic errors quoted in main_2mic.m section 1 were measured with
% the whole file and per-frame medians, and both of those were shown on
% 2026-08-20 to be unreliable on clap material. This uses the same method as
% test_zoom_offset.m: the ALIGNED OVERLAP window and the accumulated MAP PEAK.
%
% Then it asks the question that decides what to do about it. The front takes
% establish a standing relative offset of +4.75 deg for this pair of mics.
% These two takes need much more than that. Where does the extra come from?
%   (a) the rig was BUILT crooked -- a placement error, fixable by measuring
%   (b) the ZOOM's bearing error grows when the source is far off its own
%       front axis -- an instrument property, not fixable by aiming
%
% There is one clean lever for telling those apart, and it is free: the mics
% were SWAPPED between these two takes, so in the ZOOM's OWN FRAME the source
% sat at exactly OPPOSITE directions (180 deg apart) on the two takes. Split
% the two required yaws into a part COMMON to both and a part that DIFFERS:
%
%   common  = (yawLEFT + yawRIGHT)/2      differs = (yawLEFT - yawRIGHT)/2
%
% A FIXED rotation -- which is what mis-aiming is, and what a mic's acoustic
% zero sitting off its printed front is -- contributes to "common", and shows
% up in "differs" only to the extent the two rigs were built differently. So:
%
%   - "differs" measures how repeatably YOU build a front-back rig. Small is
%     good news about your hands.
%   - "common" is the interesting one. It contains the standing +4.75 offset
%     plus anything systematic about this rig or this source direction. If it
%     is far bigger than +4.75 on two INDEPENDENTLY REBUILT rigs, that excess
%     cannot be random building error, because random error does not repeat.
%
% What this CANNOT do is name the mechanism behind a repeatable excess. A
% direction-dependent bias in the mics at ~90 deg off their own front axis,
% and a habit you repeat every time you build this rig, look identical here.
% (An earlier version of this header claimed the 180 deg flip separates them
% outright, arguing any mic error must be even or odd under the flip. That is
% only true of a SINGLE angular harmonic; a real direction-dependent error has
% both even and odd terms and can take any pair of values. Corrected.)

B = 1.00;
STANDING = 4.75;          % the offset the five front takes agree on

T = {
% name    zylia                               zoom                 gtAz   gtR  layout
'LEFT'  '2micleftzylia_(ACN-SN3D-3).wav'   '2micleftzoom.WAV'    +90.0  1.50  'FB'
'RIGHT' '2micrightzylia_(ACN-SN3D-3).wav'  '2micrightzoom.WAV'   -90.0  1.50  'BF'
};

cA.inFormat='ambix'; cA.order=3; cA.micRadius=0.056; cA.fBand=[1000 12000]; cA.nBins=60;
cB.inFormat='ambix'; cB.order=1; cB.micRadius=0;     cB.fBand=[800 4000];   cB.nBins=60;
for s = {'A','B'}
    q = eval(['c' s{1}]);
    q.frameLen=1024; q.hop=512; q.energyGateDb=-25; q.snrGateDb=10;
    q.azGrid=deg2rad(0:1:359); q.elGrid=deg2rad(-40:5:40); q.rGrid=1.5; q.c=343;
    eval(['c' s{1} ' = q;']);
end

fprintf('\n=== 1. WHAT EACH MIC ACTUALLY SAW (aligned overlap, map peak) ===\n\n');
fprintf('%-6s %-4s %8s %8s %8s %8s %8s %8s %9s %7s\n', ...
        'take','lay','srcA','azA','errA','srcB','azB','errB','rel yaw','frames');
fprintf('%s\n', repmat('-',1,86));

R = struct([]);
for k = 1:size(T,1)
    lay = T{k,6};
    switch lay
        case 'FB', posA = [+B/2 0];  posB = [-B/2 0];
        case 'BF', posA = [-B/2 0];  posB = [+B/2 0];
        case 'LR', posA = [0 -B/2];  posB = [0 +B/2];
    end
    gtPos = T{k,5}*[cosd(T{k,4}) sind(T{k,4})];
    tA = atan2d(gtPos(2)-posA(2), gtPos(1)-posA(1));
    tB = atan2d(gtPos(2)-posB(2), gtPos(1)-posB(1));

    al = align_two_mics(T{k,2}, T{k,3}, 'verbose', false);
    a = cA;  a.wavFile = T{k,2};  a.tWindow = al.overlap;
    b = cB;  b.wavFile = T{k,3};  b.tWindow = al.overlap + al.offset;
    o = evalc('mA = az_power_map(a); mB = az_power_map(b);');   %#ok<NASGU>

    eA = wrap180(mA.azPeak - tA);
    eB = wrap180(mB.azPeak - tB);

    fprintf('%-6s %-4s %+8.2f %+8.2f %+8.2f %+8.2f %+8.2f %+8.2f %+9.2f %7d\n', ...
            T{k,1}, lay, tA, wrap180(mA.azPeak), eA, tB, wrap180(mB.azPeak), eB, ...
            eB-eA, mA.nFrames);

    R(k).name=T{k,1}; R(k).posA=posA; R(k).posB=posB; R(k).gtPos=gtPos;
    R(k).azA=wrap180(mA.azPeak); R(k).azB=wrap180(mB.azPeak);
    R(k).tA=tA; R(k).tB=tB; R(k).eA=eA; R(k).eB=eB; R(k).rel=eB-eA;
    R(k).gtR=T{k,5};
end
fprintf(['\n  srcA/srcB = where the source really was, in that mic''s OWN frame\n' ...
         '  (both mics point along +x, so these are off-axis angles).\n' ...
         '  "rel yaw" = the relative rotation this take needs = errB - errA.\n' ...
         '  A source-position error moves BOTH mics almost equally and cancels\n' ...
         '  in that last column, which is why it is the trustworthy one.\n']);

fprintf('\n=== 2. HOW MUCH OF IT IS THE RIG? ===\n\n');
d = wrap180(R(2).tB - R(1).tB);
fprintf('  source direction in the ZOOM''s own frame: %+.2f on %s, %+.2f on %s\n', ...
        R(1).tB, R(1).name, R(2).tB, R(2).name);
fprintf('  those differ by %.2f deg -- the mics were swapped between takes.\n\n', abs(d));
sym  = (R(1).rel + R(2).rel)/2;
asym = (R(1).rel - R(2).rel)/2;
fprintf('    required relative yaw : %+.2f (%s), %+.2f (%s)\n', ...
        R(1).rel, R(1).name, R(2).rel, R(2).name);
fprintf('    common to both builds : %+.2f deg\n', sym);
fprintf('    differs between them  : %+.2f deg  (the two builds were %.1f deg apart)\n', ...
        asym, 2*abs(asym));
fprintf('    standing offset from the five front takes : %+.2f deg\n', STANDING);
fprintf('    excess over that, COMMON to two rebuilds  : %+.2f deg\n\n', sym - STANDING);
fprintf('  Read it this way. The two rigs were built %.1f deg apart, which is a\n', 2*abs(asym));
fprintf('  respectable job of aiming by eye. But BOTH needed about %+.0f deg where\n', sym);
fprintf('  the front takes need %+.2f. An excess that survives a full rebuild is\n', STANDING);
fprintf('  systematic, not sloppiness -- and the one thing these takes do that the\n');
fprintf('  front takes never do is put the source ~90 deg off the mics'' own front\n');
fprintf('  axis. That is the suspect, and it is also the thing you can just avoid.\n');

fprintf('\n=== 3. WHAT DISTANCE COMES OUT AT EACH ASSUMED YAW ===\n\n');
fprintf('%-6s %10s %10s %10s %10s\n','take','yawB','r (mid)','err','source at');
fprintf('%s\n', repmat('-',1,58));
for k = 1:numel(R)
    for y = [0, STANDING, R(k).rel]
        p = cross_rays(R(k).azA, R(k).azB - y, R(k).posA, R(k).posB);
        if isempty(p)
            fprintf('%-6s %10.2f %10s %10s %10s\n', R(k).name, y, 'no cross','--','--');
        else
            r = norm(p);
            fprintf('%-6s %10.2f %10.2f %9.0f%% %6.2f,%5.2f\n', ...
                    R(k).name, y, r, 100*(r-R(k).gtR)/R(k).gtR, p(1), p(2));
        end
    end
    fprintf('\n');
end
fprintf(['  The third row of each block is the yaw FITTED to the known azimuth.\n' ...
         '  It lands on 1.50 m by construction and is NOT evidence -- see the\n' ...
         '  circularity note in main_2mic.m section 1. It is printed only to show\n' ...
         '  how far the honest rows (yawB = 0 and the standing +4.75) are from it.\n\n']);
end

% ---------------------------------------------------------------------
function p = cross_rays(azA, azBeff, posA, posB)
% where two bearings meet, in the frame whose origin is the rig midpoint
dA = [cosd(azA); sind(azA)];
dB = [cosd(azBeff); sind(azBeff)];
M  = [dA, -dB];
if abs(det(M)) < 1e-9, p = []; return; end
s = M \ (posB(:) - posA(:));
if any(s <= 0), p = []; return; end          % crosses behind a mic
q = posA(:) + s(1)*dA;
p = (q - (posA(:)+posB(:))/2).';
end

function y = wrap180(x)
y = mod(x + 180, 360) - 180;
end
