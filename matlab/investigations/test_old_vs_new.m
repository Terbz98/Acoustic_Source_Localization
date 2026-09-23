function test_old_vs_new
% TEST_OLD_VS_NEW  2026-08-20.
%
% Direct answer to "the code changed and broke the front clap take".
% Runs the Aug-11 triangulate.m (recovered from the D:\專題\專題 snapshot,
% renamed triangulate_aug11.m, otherwise byte-identical) and today's
% triangulate.m over the same takes with the same settings. Everything else in
% the chain -- run_doa, az_power_map, align_two_mics, build_steering_matrix,
% real_sh_matrix, sph_hankel2 -- is already confirmed byte-identical by md5, so
% the per-mic bearings cannot have moved. This checks the one file that DID
% change.
addpath(fullfile(fileparts(mfilename('fullpath')), '..')); setup_paths;   % code + recordings on the path

pairs = {
  '2miczyliafront_(ACN-SN3D-3).wav'      '2miczoomfront.WAV'       'FRONT VOICE'
  '2micclapzyliafront_(ACN-SN3D-3).wav'  '2micclapzoomfront.WAV'   'FRONT CLAP '
  '2micclapzyliaback_(ACN-SN3D-3).wav'   '2micclapzoomback.WAV'    'BACK  CLAP '
};

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

fprintf('\n%-12s %6s | %8s %8s | %8s %8s | %s\n', ...
        'take','yawB','r AUG11','r TODAY','x AUG11','x TODAY','identical?');
fprintf('%s\n', repmat('-',1,78));
for k = 1:size(pairs,1)
    al = align_two_mics(pairs{k,1}, pairs{k,2}, 'verbose', false);
    for yawB = [0 4.75]
        cA = cfgA; cA.wavFile = pairs{k,1}; cA.tWindow = al.overlap;
        cB = cfgB; cB.wavFile = pairs{k,2}; cB.tWindow = al.overlap + al.offset;
        g = geom; g.yawB = yawB;
        o = evalc('t1 = triangulate_aug11(cA, cB, g);');  %#ok<NASGU>
        o = evalc('t2 = triangulate(cA, cB, g);');        %#ok<NASGU>
        same = abs(t1.rA - t2.rA) < 1e-9 && all(abs(t1.pos - t2.pos) < 1e-9);
        if yawB == 0, nm = pairs{k,3}; else, nm = ''; end
        fprintf('%-12s %+6.2f | %8.4f %8.4f | %8.4f %8.4f | %s\n', ...
                nm, yawB, t1.rA, t2.rA, t1.pos(1), t2.pos(1), ...
                string(same));
    end
end
fprintf('\n');
