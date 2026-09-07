function test_front_clap_window
% TEST_FRONT_CLAP_WINDOW  2026-08-20.
%
% The 11 Aug FRONT CLAP pair reads 2.78 m against a 1.50 m truth. Its twin from
% the same session, the FRONT VOICE pair, reads 1.78 m (1.52 m with yaw) and is
% right. Same rig, same session, same source spot -- so the difference cannot be
% the geometry. This sweeps the analysis window to find out where it comes from.
%
% Both mics read SMALLER |az| on the clap take (17/-16 becomes 5/-10). A rig
% rotation cannot do that: it moves one mic only. Something that shrinks both
% bearings toward the look axis is pulling them toward the room average, which
% is what reverberant tails do. If that is the cause, a window on the direct
% sound should restore the parallax.

fa = '2micclapzyliafront_(ACN-SN3D-3).wav';
fb = '2micclapzoomfront.WAV';

wins = {
    []            'whole file (auto)'
    [7.1  8.6]    'the CLAP only'
    [9.5 18.0]    'the speech only'
    [7.0 12.0]    'clap + start of speech'
    [12.0 18.0]   'late speech'
    [18.0 23.8]   'tail'
};

B = 1.00;
geom.posA = [0 -B/2];  geom.posB = [0 +B/2];
geom.yawA = 0;  geom.yawB = 4.75;

cfgA.inFormat = 'ambix';  cfgA.order = 3;  cfgA.micRadius = 0.056;
cfgA.fBand = [1000 12000];  cfgA.nBins = 60;
cfgB.inFormat = 'ambix';  cfgB.order = 1;  cfgB.micRadius = 0;
cfgB.fBand = [800 4000];  cfgB.nBins = 60;
for s = {'A','B'}
    q = eval(['cfg' s{1}]);
    q.frameLen = 1024;  q.hop = 512;  q.energyGateDb = -25;  q.snrGateDb = 10;
    q.azGrid = deg2rad(0:1:359);  q.elGrid = deg2rad(-40:5:40);
    q.rGrid = 1.5;  q.c = 343;
    eval(['cfg' s{1} ' = q;']);
end

al = align_two_mics(fa, fb, 'verbose', false);

fprintf('\ntruth: azA +18.43, azB -18.43, parallax 36.87, r 1.50 m\n\n');
fprintf('%-24s %8s %8s %10s %8s %8s\n', 'window', 'azA', 'azB', 'parallax', 'r [m]', 'err');
fprintf('%s\n', repmat('-', 1, 72));

for k = 1:size(wins, 1)
    w = wins{k,1};
    if isempty(w), wa = al.overlap; else, wa = w; end
    cA = cfgA;  cA.wavFile = fa;  cA.tWindow = wa;
    cB = cfgB;  cB.wavFile = fb;  cB.tWindow = wa + al.offset;
    try
        tri = triangulate(cA, cB, geom);
        par = tri.azA - (tri.azB - geom.yawB);
        par = mod(par + 180, 360) - 180;
        fprintf('%-24s %8.2f %8.2f %10.1f %8.2f %+7.0f%%\n', ...
                wins{k,2}, tri.azA, tri.azB, par, tri.rA, 100*(tri.rA-1.5)/1.5);
    catch err
        fprintf('%-24s  failed: %s\n', wins{k,2}, err.message);
    end
end
fprintf('\n');
