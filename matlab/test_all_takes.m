function test_all_takes()
%TEST_ALL_TAKES  Regression check. NOT the script you use to analyse a take.
%
%   test_all_takes
%
% >>> TO ANALYSE A RECORDING, USE main_2mic.m, ONE TAKE AT A TIME. <<<
% This file is only for checking that a CODE CHANGE did not break a take that
% used to work. It prints one summary table and no figures. If you are not
% editing code, you never need it.
%
% Rebuilds main_2mic.m once per take, swapping nothing but the take block in
% section 1, runs the REAL script each time, and prints one scoreboard.
%
% It edits a copy of main_2mic.m rather than reimplementing it, so it cannot
% drift away from what main_2mic actually does: change the script and this
% tests the change. That is the whole point -- a harness that reimplements the
% thing it is testing will happily agree with itself while both are wrong.
%
% Use it after ANY edit to main_2mic.m, triangulate.m or the geometry, to check
% that a fix for one take did not quietly break another. Takes a few minutes;
% every take re-runs the full SRP on two multichannel files.
%
% WHAT GOOD LOOKS LIKE (measured 2026-08-18, and the reason each row is here):
%   the five non-degenerate takes report a distance and are TRUSTED
%   the two +-90 deg takes are REJECTED by the guards, not reported as answers
%   azimuth error stays inside a few degrees on every take that is not on the
%     blind axis, and elevation lands within about 1.5 deg
%   ONE UNRESOLVED ROW: the 11 Aug front clap reads +85% and passes every guard.
%     Its r err is only meaningful if its 1.50 m truth is -- and that is exactly
%     what is in doubt, because the same bearings are also explained by the
%     source standing at 2.64 m with the mics untouched. Read the r err column
%     on that row as "disagrees with the assumed truth", not as "wrong". See
%     main_2mic.m section 1.
%
% Written 2026-08-18. Voice pair added and the clap diagnosis corrected
% 2026-08-20.
setup_paths;   % code + recordings on the path

T = local_takes();

set(0, 'DefaultFigureVisible', 'off');
cleanupFig = onCleanup(@() set(0, 'DefaultFigureVisible', 'on'));

fprintf('\n%s\n', repmat('=', 1, 104));
fprintf('  main_2mic.m over every take on record\n');
fprintf('%s\n', repmat('=', 1, 104));
fprintf('%-20s %8s %8s %8s %8s %8s %8s %7s  %s\n', ...
        'take', 'az est', 'az err', 'el est', 'el err', 'r est', 'r err', 'broad', 'distance');
fprintf('%s\n', repmat('-', 1, 104));

nErr = 0;  nRej = 0;
for k = 1:numel(T)
    try
        R = run_one(T(k));
        % A distance the guards have REJECTED must not be printed in a scored
        % column. A number under "r est" reads as an answer no matter what the
        % last column says, and for a source on the blind axis there is no
        % answer to give: every range produces the identical pair of bearings,
        % so the recording holds no distance to be right or wrong about. What
        % the map peaked at is an artefact of which way the noise leaned. Show
        % it as absent, which is what it is.
        if strcmp(R.verdict, 'TRUSTED')
            rEst = sprintf('%8.2f', R.r);
            rErr = sprintf('%+7.0f%%', 100*(R.r - R.gtR)/R.gtR);
        else
            rEst = sprintf('%8s', '--');
            rErr = sprintf('%8s', '--');
        end
        fprintf('%-20s %+8.1f %+8.1f %+8.1f %+8.1f %s %s %6.0fd  %s\n', ...
                T(k).name, R.az, wrap180(R.az - R.gtAz), R.el, R.el - R.gtEl, ...
                rEst, rErr, R.off, R.verdict);
        nRej = nRej + strcmp(R.verdict, 'rejected');
    catch ME
        nErr = nErr + 1;
        fprintf('%-20s  *** MATLAB ERROR: %s\n', T(k).name, ME.message);
        for f = 1:numel(ME.stack)
            fprintf('%22s at %s line %d\n', '', ME.stack(f).name, ME.stack(f).line);
        end
    end
    close all;
end

fprintf('%s\n', repmat('-', 1, 104));
fprintf(['  az/el in degrees, r in metres. "broad" is degrees off broadside:\n' ...
         '  0 is straight out the perpendicular bisector, 90 is the blind axis\n' ...
         '  through both mics, where no range information exists at all.\n' ...
         '  A rejected row shows NO distance on purpose: the guards found the\n' ...
         '  geometry untrustworthy, so any number there would be an artefact.\n' ...
         '  Read the take''s own VERDICT line for which guard fired -- r/B too\n' ...
         '  large, rays not crossing in front, or a peak on the mic mask.\n' ...
         '  Azimuth and elevation on a rejected row are still real.\n' ...
         '\n' ...
         '  A TRUSTED row is not automatically a CORRECT one. The RIGHT take\n' ...
         '  (+60%%) is knowingly wrong and passes every guard: one unmeasured\n' ...
         '  relative yaw, which nothing here can see. And on the 11 Aug front\n' ...
         '  clap the r err column compares against a truth that is itself in\n' ...
         '  doubt -- read it as "disagrees with what was assumed", not as an\n' ...
         '  error. main_2mic.m section 1 has both readings of that take.\n']);
fprintf('\n  %d of %d takes ran, %d distances rejected by the guards, %d MATLAB errors.\n', ...
        numel(T)-nErr, numel(T), nRej, nErr);
if nErr > 0
    fprintf('  ^^ a MATLAB error is always a real failure. Fix it before trusting any row.\n');
end
end


% ===================== the takes =====================================
function T = local_takes()
% Every pair of recordings with a known ground truth. gtR is measured from the
% MIDPOINT of the two mics, so standing 1.50 m in front of one MIC is
% hypot(1.50, 0.50) = 1.5811 m from the midpoint, at +-18.43 deg -- not 1.50 m
% and not 0 deg. Getting that wrong makes a correct answer look like an error.
T = struct('name', {}, 'tag', {}, 'zylia', {}, 'zoom', {}, ...
           'az', {}, 'el', {}, 'r', {}, 'yaw', {}, 'layout', {});

add = @(varargin) struct('name', varargin{1}, 'tag', varargin{2}, ...
        'zylia', varargin{3}, 'zoom', varargin{4}, 'az', varargin{5}, ...
        'el', varargin{6}, 'r', varargin{7}, 'yaw', varargin{8}, 'layout', varargin{9});

% ---- 2026-08-11 session, yawB from check_mic_yaw on the front/back pair ----
% The front position was recorded TWICE that session: speech only (the VOICE
% pair) and claps + speech (the CLAP pair). Both are here on purpose. The voice
% pair is the one to quote; the clap pair is the known-bad row, and keeping them
% adjacent is what makes the failure legible -- same position, same rig, same
% day, -3% against +85%.
T(end+1) = add('11 Aug front VOICE','t0', '2miczyliafront_(ACN-SN3D-3).wav', ...
               '2miczoomfront.WAV',        0.0,  0.0, 1.50,   4.75, 'LR');
% UNRESOLVED. At the session's yaw this reads 2.77 m against the 1.50 m that was
% expected. Either the mics did not move and the SOURCE was at 2.64 m for this
% take (so the 1.50 below is the wrong truth and the +85% is not an error), or
% the rig turned ~20 deg (so 1.50 is right). Both fit the bearings exactly and
% the audio cannot separate them -- see main_2mic.m section 1. Left at the
% session yaw because the user is confident the mics did not move.
T(end+1) = add('11 Aug front clap', 't1', '2micclapzyliafront_(ACN-SN3D-3).wav', ...
               '2micclapzoomfront.WAV',    0.0,  0.0, 1.50,   4.75, 'LR');
T(end+1) = add('11 Aug back clap',  't2', '2micclapzyliaback_(ACN-SN3D-3).wav',  ...
               '2micclapzoomback.WAV',   180.0,  0.0, 1.50,   4.75, 'LR');

% ---- 2026-08-17 limit tests, source 1.50 m from the midpoint, yawB = 5.40 ----
T(end+1) = add('in front of ZYLIA', 't3', '2micdirectfrontzylia1_(ACN-SN3D-3).wav', ...
               '2micdirectfrontzoom1.WAV', -18.43, 0.0, 1.5811, 5.40, 'LR');
T(end+1) = add('in front of ZOOM',  't4', '2micdirectfrontzylia2_(ACN-SN3D-3).wav', ...
               '2micdirectfrontzoom2.WAV', +18.43, 0.0, 1.5811, 5.40, 'LR');
% gtEl here is NOT tape-measured -- it is what the Zylia map and direct-path
% pseudo-intensity on both mics agree on. Replace it if you ever measure the
% real clap and mic heights; +16.9 deg at 1.5 m means 0.46 m above the mic.
T(end+1) = add('centre + elevated', 't5', '2micfrontelzylia_(ACN-SN3D-3).wav', ...
               '2micfrontelzoom.WAV',        0.0, 16.9, 1.568,  5.40, 'LR');
% The two side takes were recorded on a FRONT-BACK rig, and with the mics
% SWAPPED between them: Zylia in front for LEFT ('FB'), Zoom in front for RIGHT
% ('BF'). Both are therefore broadside to the BASELINE, 0 deg off -- the ideal
% geometry -- and their AZIMUTH is fine (Zylia within 3.4 and 4.4 deg). The
% distances are wrong for one reason: yaw was never measured for either build,
% so the 0.0 below is a placeholder, not a calibration. Expect +109% and +64%.
% Applying the pair's standing +4.75 only gets them to +65% and +35%, because
% these two takes need +18.87 and +13.87 -- see test_side_takes.m and the long
% note in main_2mic.m section 1. What is NOT wrong is your building: the two
% independent rigs came out only 5.0 deg apart. What is wrong is that the source
% sat ~90 deg off the mics' OWN front axis, which no other take does.
% Do NOT paper over it by fitting yaw to the known azimuth.
% The two side takes were recorded on a FRONT-BACK rig, and with the mics
% SWAPPED between them: Zylia in front for LEFT ('FB'), Zoom in front for RIGHT
% ('BF'). Both are therefore broadside, 0 deg off -- the ideal geometry. Their
% distances are still wrong, but for a different and fixable reason: yaw was
% never measured for either setup, so yawB = 0 below is a placeholder, not a
% calibration. Expect roughly +109% and +64%. Do NOT paper over that by fitting
% yaw to the known azimuth; see the long note in main_2mic.m section 1.
T(end+1) = add('LEFT (FB, no yaw)',  't6', '2micleftzylia_(ACN-SN3D-3).wav', ...
               '2micleftzoom.WAV',         +90.0,  0.0, 1.50,   0.0, 'FB');
T(end+1) = add('RIGHT (BF, no yaw)', 't7', '2micrightzylia_(ACN-SN3D-3).wav', ...
               '2micrightzoom.WAV',        -90.0,  0.0, 1.50,   0.0, 'BF');
end


% ===================== one take ======================================
function R = run_one(t)
% Build a copy of main_2mic.m carrying this take, run it, read the answers out
% of its workspace. The copy is written into the CURRENT folder, not tempdir,
% because main_2mic refers to the wav files by relative name.
src = fileread('main_2mic.m');

blk = sprintf(['zyliaFile = ''%s'';\nzoomFile  = ''%s'';\ngtAzDeg   = %g;\n' ...
               'gtElDeg   = %g;\ngtR       = %g;\nyawB      = %g;\nlayout    = ''%s'';'], ...
              t.zylia, t.zoom, t.az, t.el, t.r, t.yaw, t.layout);

i0 = regexp(src, '^zyliaFile = ', 'lineanchors', 'once');
i1 = regexp(src, '^layout    = [^\n]*', 'lineanchors', 'once', 'end');
if isempty(i0) || isempty(i1) || i1 < i0
    error(['could not find the take block in main_2mic.m. It must still have an ' ...
           'uncommented "zyliaFile = ..." line followed by a "layout    = ..." line.']);
end
src = [src(1:i0-1) blk src(i1+1:end)];

% 'clear' would wipe this function's own workspace, including the variables
% holding the filename we are about to delete.
src = strrep(src, 'clear; clc; close all;', 'close all;');

f = fullfile(pwd, sprintf('tmp_take_%s_%d.m', t.tag, feature('getpid')));
fid = fopen(f, 'w');
if fid < 0, error('cannot write %s', f); end
fwrite(fid, src);  fclose(fid);
cleanupFile = onCleanup(@() delete(f));

[~, fname] = fileparts(f);
evalc(fname);        % runs the script here, quietly; its vars land in scope

R.az  = azC;   R.el = elC;   R.r = rC;
R.gtAz = gtAzDeg;  R.gtEl = gtElDeg;  R.gtR = gtR;
R.off = offBroadside;
if isempty(tri.warning), R.verdict = 'TRUSTED'; else, R.verdict = 'rejected'; end
end


function y = wrap180(x)
y = mod(x + 180, 360) - 180;
end
