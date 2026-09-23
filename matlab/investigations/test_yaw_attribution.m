function test_yaw_attribution
% TEST_YAW_ATTRIBUTION  2026-08-20.
%
% check_mic_yaw's front+back sum invariant needs no ground truth, no distance
% and no baseline -- only that the source was on the centre line both times.
% The 2026-08-11 session gives TWO front takes against one back take, which is
% the third measurement that lets the misalignment be ATTRIBUTED to a take
% instead of split evenly between two.
%
%   pairing               relative misalignment   even split
%   voice front + back    ?                       ? -> the 4.75 in use
%   clap  front + back    ?                       ?
%
% If the voice pairing is clean and the clap pairing is not, the rotation sits
% in the CLAP take, and its yaw is (clap relative) - (voice per-take), not the
% even split. Then run the front clap through triangulate at that yaw and see
% whether the distance comes back on its own.
addpath(fullfile(fileparts(mfilename('fullpath')), '..')); setup_paths;   % code + recordings on the path

azFrontVoiceA = 16.47;  azFrontVoiceB = -15.95;   % run_doa medians, this session
azFrontClapA  =  5.42;  azFrontClapB  = -11.16;
azBackA       = 163.86; azBackB       = -154.37;

fprintf('\n===== pairing 1: FRONT VOICE + BACK CLAP =====');
v = check_mic_yaw(azFrontVoiceA, azBackA, azFrontVoiceB, azBackB);
fprintf('\n===== pairing 2: FRONT CLAP + BACK CLAP =====');
c = check_mic_yaw(azFrontClapA,  azBackA, azFrontClapB,  azBackB);

yawClap = c.relative - v.perTake;
fprintf('\n===== ATTRIBUTION =====\n');
fprintf('  voice pairing relative  : %+7.2f deg -> per take %+6.2f (the 4.75 in use)\n', ...
        v.relative, v.perTake);
fprintf('  clap  pairing relative  : %+7.2f deg -> even split %+6.2f\n', ...
        c.relative, c.perTake);
fprintf('  the BACK take carries %+.2f (from pairing 1), so the FRONT CLAP take\n', v.perTake);
fprintf('  carries %+.2f - %+.2f = %+.2f deg. That is the yaw to use for it.\n', ...
        c.relative, v.perTake, yawClap);

B = 1.00;
geom.posA = [0 -B/2];  geom.posB = [0 +B/2];  geom.yawA = 0;
cfgA.inFormat='ambix'; cfgA.order=3; cfgA.micRadius=0.056;
cfgA.fBand=[1000 12000]; cfgA.nBins=60;
cfgB.inFormat='ambix'; cfgB.order=1; cfgB.micRadius=0;
cfgB.fBand=[800 4000]; cfgB.nBins=60;
for s = {'A','B'}
    q = eval(['cfg' s{1}]);
    q.frameLen=1024; q.hop=512; q.energyGateDb=-25; q.snrGateDb=10;
    q.azGrid=deg2rad(0:1:359); q.elGrid=deg2rad(-40:5:40); q.rGrid=1.5; q.c=343;
    eval(['cfg' s{1} ' = q;']);
end

fa = '2micclapzyliafront_(ACN-SN3D-3).wav';
fb = '2micclapzoomfront.WAV';
al = align_two_mics(fa, fb, 'verbose', false);

fprintf('\n===== FRONT CLAP take, swept over yawB =====\n');
fprintf('%-42s %8s %10s %8s %8s\n', 'yawB', 'azBeff', 'parallax', 'r [m]', 'err');
fprintf('%s\n', repmat('-', 1, 80));
cand = [0, 4.75, c.perTake, yawClap];
lbl  = {'none', 'the 4.75 assumed from the OTHER pairing', ...
        'even split (assumes rig held still)', 'ATTRIBUTED to this take'};
for k = 1:numel(cand)
    cA = cfgA; cA.wavFile = fa; cA.tWindow = al.overlap;
    cB = cfgB; cB.wavFile = fb; cB.tWindow = al.overlap + al.offset;
    g = geom; g.yawB = cand(k);
    o = evalc('tri = triangulate(cA, cB, g);'); %#ok<NASGU>
    azBeff = tri.azB - cand(k);
    par = mod(tri.azA - azBeff + 180, 360) - 180;
    fprintf('%+6.2f  %-34s %8.2f %10.1f %8.2f %+7.0f%%\n', cand(k), lbl{k}, ...
            azBeff, par, tri.rA, 100*(tri.rA - 1.5)/1.5);
end
fprintf('\ntruth 1.50 m, ideal parallax 36.87 deg\n\n');
