cd('D:\專題');
% DECISIVE TEST. The two clap takes each contain an impulse, so each gives a
% direct-to-reverberant ratio. In one room, direct energy falls as 1/r^2 while
% the reverberant field is roughly uniform, so
%       DRR difference (dB) = 20*log10(r_far / r_near)
% DRR does not care how loud the clap was or what the recording gain was --
% both scale the direct and the reverberant parts equally. So this settles
% whether the source really was further away on the front clap take.
%
% Triangulation says: back clap 1.36 m, front clap 3.43 m -> expect the front
% clap take to have about 8 dB LOWER DRR.
% If the person stood in the same place both times -> expect about 0 dB.

files = {'2micclapzyliaback_(ACN-SN3D-3).wav','BACK  clap'
         '2micclapzyliafront_(ACN-SN3D-3).wav','FRONT clap'
         'zyliafloorclapback_(ACN-SN3D-3).wav','floor back clap'
         'zyliafloorclapfront_(ACN-SN3D-3).wav','floor front clap'};

fprintf('\n%-18s %9s %9s %9s %9s %9s\n', ...
        'take','noise dB','clap dB','DRR dB','RT60 s','peak t');
res = zeros(size(files,1),1);
for i = 1:size(files,1)
    [x, fs] = audioread(files{i,1});
    w = x(:,1);
    [b,a] = butter(4,[500 5000]/(fs/2),'bandpass');
    w = filtfilt(b,a,w);

    % noise floor from the quietest 10% of 50 ms blocks
    L = round(0.05*fs); n = floor(numel(w)/L);
    e = sum(reshape(w(1:n*L),L,n).^2, 1).';
    noise = quantile(e,0.10)/L;                       % mean square per sample

    % clap onset
    [~, ip] = max(abs(w));
    sr = max(1,ip-round(0.02*fs)):ip;
    k = find(abs(w(sr)) >= 0.25*max(abs(w(ip))),1,'first');
    n0 = sr(1)+k-1;

    dW = round(0.0025*fs);                            % direct: first 2.5 ms
    rW = round(0.200*fs);                             % reverb tail
    direct = sum(w(n0:n0+dW-1).^2) - dW*noise;
    tail   = w(n0+dW : min(numel(w), n0+rW));
    reverb = sum(tail.^2) - numel(tail)*noise;
    DRR = 10*log10(max(direct,eps)/max(reverb,eps));

    % RT60 by Schroeder backward integration of the tail
    sch = flipud(cumsum(flipud(tail.^2)));
    sch = 10*log10(max(sch/sch(1), 1e-12));
    t = (0:numel(sch)-1).'/fs;
    sel = sch <= -5 & sch >= -25;
    if nnz(sel) > 50
        p = polyfit(t(sel), sch(sel), 1);
        rt60 = -60/p(1);
    else
        rt60 = NaN;
    end

    res(i) = DRR;
    fprintf('%-18s %9.1f %9.1f %9.2f %9.2f %9.3f\n', files{i,2}, ...
            10*log10(noise), 10*log10(max(w(n0:n0+dW-1).^2)), DRR, rt60, n0/fs);
end

fprintf('\nDRR difference, front clap minus back clap : %+.2f dB\n', res(2)-res(1));
fprintf('  implied distance ratio r_front / r_back  : %.2f\n', 10^(-(res(2)-res(1))/20));
fprintf('  triangulation said 3.43 / 1.36           = %.2f\n', 3.43/1.36);
fprintf('\nfloor takes, front minus back              : %+.2f dB (ratio %.2f)\n', ...
        res(4)-res(3), 10^(-(res(4)-res(3))/20));

fprintf(['\nIf the ratio comes out near 1, the source was the SAME distance in both\n' ...
         'takes and something else is rotating the bearings. If it comes out near\n' ...
         '2.5, the person really was standing further back on the front clap take.\n']);
