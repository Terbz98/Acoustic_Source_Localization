function test_level_bias
% TEST_LEVEL_BIAS  2026-08-20.
%
% The two 11 Aug front takes disagree by 11 deg on the ZYLIA alone:
%   front VOICE  az 16.47   (matches the 1.5 m centre-line geometry)
%   front CLAP   az  5.42
% Only three things can do that: the mic turned, the source stood somewhere
% else, or the CLAP RECORDING ITSELF biases the bearing. User is confident the
% mics did not move, so this tests the third.
%
% The clap take is 40 dB hotter than the voice take (raw peak -4.9 dBFS against
% -45.1). If level is corrupting the bearing, the bearing must MOVE WITH LEVEL
% inside the clap take: loud frames biased, quiet frames not. If instead every
% level agrees, the recording is fine and the 11 deg is real geometry.
% Also prints azimuth against TIME, which catches a source that moved mid-take.
%
% GATING: uses exactly what main_2mic uses -- az_power_map's gate (relative to
% the 95th percentile, not the single loudest frame) fed back into run_doa via
% gateRelMaxDb. Gating on the max instead keeps only the clap and its tail on a
% clap take -- 47 frames of reverberation -- and every conclusion drawn from
% that is about the room, not the source.
addpath(fullfile(fileparts(mfilename('fullpath')), '..')); setup_paths;   % code + recordings on the path

files = {
  '2miczyliafront_(ACN-SN3D-3).wav'      'FRONT VOICE'  0
  '2micclapzyliafront_(ACN-SN3D-3).wav'  'FRONT CLAP '  0
  '2micclapzyliaback_(ACN-SN3D-3).wav'   'BACK  CLAP '  1
};

cfg.inFormat='ambix'; cfg.order=3; cfg.micRadius=0.056;
cfg.fBand=[1000 12000]; cfg.nBins=60;
cfg.frameLen=1024; cfg.hop=512; cfg.energyGateDb=-25; cfg.snrGateDb=10;
cfg.azGrid=deg2rad(0:1:359); cfg.elGrid=deg2rad(-40:5:40); cfg.rGrid=1.5; cfg.c=343;

for k = 1:size(files,1)
    f = files{k,1};  isBack = files{k,3};
    c = cfg;  c.wavFile = f;  c.tWindow = [];
    o = evalc('m = az_power_map(c);');            %#ok<NASGU>
    c.energyGateDb = m.gateRelMaxDb;              % same frames main_2mic uses
    o = evalc('res = run_doa(c);');               %#ok<NASGU>

    [x, fs] = audioread(f);
    b = convert_to_acn_n3d(x, c.inFormat, c.order);
    L = c.frameLen; hop = c.hop;
    win = 0.5*(1 - cos(2*pi*(0:L-1).'/L));
    fAx = (0:L/2)*fs/L;
    inB = find(fAx >= c.fBand(1) & fAx <= c.fBand(2));
    sel = unique(inB(round(linspace(1, numel(inB), min(c.nBins, numel(inB))))));
    n = numel(res.t);  rms = zeros(n,1);
    for fr = 1:n
        idx = (fr-1)*hop + (1:L);
        F = fft(b(idx,1).*win);
        rms(fr) = sqrt(mean(abs(F(sel)).^2));
    end
    lvl = 20*log10(rms / max(rms));

    a = res.azDeg(res.active);
    if isBack, a = mod(a, 360); else, a = mod(a + 180, 360) - 180; end
    v = lvl(res.active);  tv = res.t(res.active);

    fprintf('\n=== %s  (%s) ===\n', files{k,2}, f);
    fprintf('  gate %.1f dB below the 95th pct -> %d active frames, median %.2f deg\n', ...
            -m.gateRelMaxDb, numel(a), median(a));
    fprintf('  %-18s %7s %9s %9s\n', 'level below peak', 'frames', 'median az', 'MAD');
    edges = [-70 -50 -40 -30 -20 -10 0];
    for e = 1:numel(edges)-1
        msk = v >= edges(e) & v < edges(e+1);
        if nnz(msk) < 8, continue; end
        fprintf('  %5.0f..%-4.0f dB        %7d %9.2f %9.2f\n', edges(e), edges(e+1), ...
                nnz(msk), median(a(msk)), median(abs(a(msk)-median(a(msk)))));
    end
    fprintf('  %-18s %7s %9s %9s\n', 'time band', 'frames', 'median az', 'MAD');
    q = linspace(min(tv), max(tv), 6);
    for e = 1:5
        msk = tv >= q(e) & tv < q(e+1);
        if nnz(msk) < 8, continue; end
        fprintf('  %5.1f..%-5.1f s       %7d %9.2f %9.2f\n', q(e), q(e+1), nnz(msk), ...
                median(a(msk)), median(abs(a(msk)-median(a(msk)))));
    end
end
fprintf('\n');
