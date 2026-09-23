function setup_paths()
%SETUP_PATHS  Put this project's MATLAB code and the recordings on the path.
%   Every script calls this first, so it works whichever folder MATLAB is in.
%   Recordings (.wav) are found in either of:
%       <repo>/data/   -- recommended: put your recordings here
%       <repo>/        -- where the original recordings live
%   audioread and fileread search the MATLAB path, so plain file names such
%   as '2miczoomfront.WAV' in the scripts keep working.
here = fileparts(mfilename('fullpath'));          % <repo>/matlab
repo = fileparts(here);
addpath(here, fullfile(here, 'investigations'));
addpath(repo);
if isfolder(fullfile(repo, 'data'))
    addpath(fullfile(repo, 'data'));
end
end
