function test_voice_front
% TEST_VOICE_FRONT  Regression check, 2026-08-20.
%
% Answers one question: did anything in the code change the 2026-08-11 result
% of ~1.7 m on the FRONT VOICE pair?
%
% The 1.7 m that session reported came from
%       2miczyliafront_(ACN-SN3D-3).wav  +  2miczoomfront.WAV      (voice)
% NOT from
%       2micclapzyliafront_(ACN-SN3D-3).wav + 2micclapzoomfront.WAV (clap)
% which reported 4.12 m that same day and 2.77 m now. Two different takes.
%
% This is a test_ script: it never becomes the headline. main_2mic.m stays the
% one-take-at-a-time entry point.
addpath(fullfile(fileparts(mfilename('fullpath')), '..')); setup_paths;   % code + recordings on the path

pairs = {
    '2miczyliafront_(ACN-SN3D-3).wav',     '2miczoomfront.WAV',      'FRONT VOICE  (the 1.7 m one)'
    '2micclapzyliafront_(ACN-SN3D-3).wav', '2micclapzoomfront.WAV',  'FRONT CLAP   (the 2.78 m one)'
    '2micclapzyliaback_(ACN-SN3D-3).wav',  '2micclapzoomback.WAV',   'BACK CLAP    (the 1.56 m one)'
};

B = 1.00;
geom.posA = [0 -B/2];
geom.posB = [0 +B/2];
geom.yawA = 0;

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

fprintf('\n%-30s %8s %8s %9s %8s %8s\n', 'take', 'yawB', 'azA', 'azB', 'parallax', 'r [m]');
fprintf('%s\n', repmat('-', 1, 78));

for k = 1:size(pairs, 1)
    fa = pairs{k,1};  fb = pairs{k,2};  lbl = pairs{k,3};
    al = align_two_mics(fa, fb, 'verbose', false);
    for yawB = [0 4.75]
        cA = cfgA;  cA.wavFile = fa;  cA.tWindow = al.overlap;
        cB = cfgB;  cB.wavFile = fb;  cB.tWindow = al.overlap + al.offset;
        g = geom;  g.yawB = yawB;
        tri = triangulate(cA, cB, g);
        if yawB == 0, name = lbl; else, name = ''; end
        fprintf('%-30s %+8.2f %8.2f %9.2f %8.1f %8.2f\n', ...
                name, yawB, tri.azA, tri.azB, tri.azA - (tri.azB - yawB), tri.rA);
    end
end
fprintf('\n');
