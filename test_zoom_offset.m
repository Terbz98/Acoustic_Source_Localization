function test_zoom_offset
% TEST_ZOOM_OFFSET  2026-08-20.
%
% "Why should yawB be 4.75 if I aimed both mics straight forward?"
%
% yawB is not a description of a placement mistake. It is a lump-sum correction
% that absorbs everything making the two mics disagree about which way is
% forward, and only ONE of those things is how carefully you aimed them:
%   1. the mic bodies genuinely not parallel        <- the only one you control
%   2. each mic's ACOUSTIC zero not matching its printed front marker
%   3. systematic bearing bias of the two estimators (order 3 vs order 1,
%      different bands, different capsule geometry)
%
% 2 and 3 are properties of the instruments. They do not care how carefully you
% set up, they are the SAME every session, and they cannot be aimed away.
%
% This tells them apart. For every take with a trustworthy ground truth it
% prints each mic's bearing error at yawB = 0 and their difference -- the
% relative offset the distance actually cares about.
%   - a placement mistake is RANDOM: it changes sign and size between sessions
%   - an instrument offset is FIXED: same number, both sessions, every take
%
% TWO METHOD POINTS, both learned the hard way while writing this:
%   - use the ALIGNED OVERLAP window, not the whole file. The two recorders run
%     at different times and the non-overlapping part is a different acoustic
%     event; whole-file moved the Zoom's answer 11 deg on one take.
%   - read the accumulated MAP PEAK, not the per-frame median. On clap material
%     most gated frames are reverberant tail and a plain median collapses --
%     with medians two of these takes came out 130 deg wrong, which would have
%     been read as a catastrophic rig fault.
%
% The front clap take is excluded on purpose: its source position is disputed,
% so its "error" is not an error. The two side takes are excluded too -- they
% were a front-back rig with unmeasured yaw of their own.

T = {
% name              zylia file                                zoom file                    gtAz    gtR    session
'11 Aug front VOICE' '2miczyliafront_(ACN-SN3D-3).wav'      '2miczoomfront.WAV'            0.0   1.50   '11 Aug'
'11 Aug back clap'   '2micclapzyliaback_(ACN-SN3D-3).wav'   '2micclapzoomback.WAV'       180.0   1.50   '11 Aug'
'in front of ZYLIA'  '2micdirectfrontzylia1_(ACN-SN3D-3).wav' '2micdirectfrontzoom1.WAV' -18.43  1.5811 '17 Aug'
'in front of ZOOM'   '2micdirectfrontzylia2_(ACN-SN3D-3).wav' '2micdirectfrontzoom2.WAV' +18.43  1.5811 '17 Aug'
'centre + elevated'  '2micfrontelzylia_(ACN-SN3D-3).wav'    '2micfrontelzoom.WAV'          0.0   1.568  '17 Aug'
};

B = 1.00;
posA = [0 -B/2];  posB = [0 +B/2];

cA.inFormat='ambix'; cA.order=3; cA.micRadius=0.056; cA.fBand=[1000 12000]; cA.nBins=60;
cB.inFormat='ambix'; cB.order=1; cB.micRadius=0;     cB.fBand=[800 4000];   cB.nBins=60;
for s = {'A','B'}
    q = eval(['c' s{1}]);
    q.frameLen=1024; q.hop=512; q.energyGateDb=-25; q.snrGateDb=10;
    q.azGrid=deg2rad(0:1:359); q.elGrid=deg2rad(-40:5:40); q.rGrid=1.5; q.c=343;
    eval(['c' s{1} ' = q;']);
end

fprintf('\n  Bearing error of each mic at yawB = 0, against the take truth.\n');
fprintf('  The Zoom-Zylia column is what the DISTANCE cares about.\n\n');
fprintf('%-20s %8s %9s %9s %11s %8s\n', 'take', 'session', 'Zylia err', 'Zoom err', ...
        'Zoom-Zylia', 'frames');
fprintf('%s\n', repmat('-', 1, 72));

rel = [];  ses = {};
for k = 1:size(T,1)
    gtPos = [T{k,5}*cosd(T{k,4}), T{k,5}*sind(T{k,4})];
    tA = atan2d(gtPos(2)-posA(2), gtPos(1)-posA(1));
    tB = atan2d(gtPos(2)-posB(2), gtPos(1)-posB(1));

    al = align_two_mics(T{k,2}, T{k,3}, 'verbose', false);
    a = cA;  a.wavFile = T{k,2};  a.tWindow = al.overlap;
    b = cB;  b.wavFile = T{k,3};  b.tWindow = al.overlap + al.offset;
    o = evalc('mA = az_power_map(a); mB = az_power_map(b);');   %#ok<NASGU>

    eA = wrap180(mA.azPeak - tA);
    eB = wrap180(mB.azPeak - tB);

    fprintf('%-20s %8s %+9.2f %+9.2f %+11.2f %8d\n', ...
            T{k,1}, T{k,6}, eA, eB, eB - eA, mA.nFrames);
    rel(end+1) = eB - eA;  %#ok<AGROW>
    ses{end+1} = T{k,6};   %#ok<AGROW>
end

fprintf('%s\n', repmat('-', 1, 72));
for s = {'11 Aug','17 Aug'}
    m = strcmp(ses, s{1});
    if any(m)
        fprintf('  %s mean relative offset : %+.2f deg  (over %d takes, spread %.2f)\n', ...
                s{1}, mean(rel(m)), nnz(m), std(rel(m)));
    end
end
fprintf('  ALL takes, both sessions      : %+.2f deg, spread %.2f\n', ...
        mean(rel), std(rel));
fprintf(['\n  If the two session means are close, the offset is a property of the\n' ...
         '  INSTRUMENTS, not of how you placed them, and one number works for both.\n' ...
         '  If they differ by several degrees, it is placement, and it has to be\n' ...
         '  measured fresh every time the rig is built.\n\n']);
end

function y = wrap180(x)
y = mod(x + 180, 360) - 180;
end
