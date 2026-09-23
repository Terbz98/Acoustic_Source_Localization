function test_clip_check
% TEST_CLIP_CHECK  2026-08-20. Is the FRONT CLAP pair clipped?
%
% The front clap take reads 2.78 m; DRR says the source was not that far, so
% the bearings themselves are bad. Both mics under-read (Zylia 5 vs 18.4 truth,
% Zoom -10 vs -18.4), i.e. both point too close to straight ahead. Clipping
% does exactly that: the distortion is common to every capsule, so it inflates
% the omni (W) part relative to the directional parts and flattens the beam.
% run_doa reported "0 clipped dropped" for the Zylia on this take -- check
% whether that is true of the RAW file or only of the rescaled converted one.
addpath(fullfile(fileparts(mfilename('fullpath')), '..')); setup_paths;   % code + recordings on the path

files = {
  '2micclapzyliafront.wav'               'FRONT clap  Zylia RAW'
  '2micclapzyliafront_(ACN-SN3D-3).wav'  'FRONT clap  Zylia CONV'
  '2micclapzoomfront.WAV'                'FRONT clap  Zoom'
  '2micclapzyliaback.wav'                'BACK  clap  Zylia RAW'
  '2micclapzyliaback_(ACN-SN3D-3).wav'   'BACK  clap  Zylia CONV'
  '2micclapzoomback.WAV'                 'BACK  clap  Zoom'
  '2miczyliafront.wav'                   'FRONT voice Zylia RAW'
  '2miczyliafront_(ACN-SN3D-3).wav'      'FRONT voice Zylia CONV'
  '2miczoomfront.WAV'                    'FRONT voice Zoom'
};

fprintf('\n%-24s %9s %9s %10s %12s\n', 'file', 'peak', 'peak dBFS', 'ch@peak', 'samples>0.999');
fprintf('%s\n', repmat('-', 1, 70));
for i = 1:size(files,1)
    if ~isfile(files{i,1})
        fprintf('%-24s  MISSING\n', files{i,2});  continue
    end
    [x, ~] = audioread(files{i,1});
    [pk, idx] = max(abs(x(:)));
    [~, ch] = ind2sub(size(x), idx);
    nclip = nnz(abs(x) > 0.999);
    fprintf('%-24s %9.4f %9.1f %10d %12d\n', files{i,2}, pk, 20*log10(pk), ch, nclip);
end
fprintf('\n');
