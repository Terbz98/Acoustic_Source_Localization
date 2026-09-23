function out = check_mic_yaw(azFrontA, azBackA, azFrontB, azBackB, verbose)
% CHECK_MIC_YAW  Did either microphone rotate between takes?
%
%   out = check_mic_yaw(azFrontA, azBackA, azFrontB, azBackB)
%       azFrontA, azBackA : mic A's median azimuth with the source in FRONT
%                           and BEHIND the rig, in degrees
%       azFrontB, azBackB : the same two numbers for mic B
%   Read all four straight off the "PER-MIC BEARINGS" table that main_2mic.m
%   prints -- run it once on a front take and once on a back take.
%
%   THE INVARIANT THIS USES
%   Put the source anywhere on the centre line of the rig, in front. Mic A, at
%   -y, sees it at +atan((B/2)/d). Move the source to the mirror position
%   behind, and mic A sees 180 - atan((B/2)/d). The two add to exactly 180 --
%   and the distance d has cancelled out completely. Mic B, at +y, gives -180
%   the same way.
%
%   So the sum needs NO ground truth, NO measured distance and NO measured
%   baseline. It does assume the source was on the centre line both times AND
%   THE SAME DISTANCE OUT both times.
%
%   *** READ THIS BEFORE USING THE RESULT TO BLAME A MICROPHONE (2026-08-20) ***
%   The distance does NOT cancel in general. It cancels only for MIRRORED source
%   positions. What the sum actually is:
%
%       sum = 180 + atan(B/2 d_front) - atan(B/2 d_back)
%
%   so an unequal pair of distances shifts it exactly like a rotation does, and
%   this test CANNOT TELL THE TWO APART. Worked example from the 2026-08-11
%   session, mic A, B = 1.00 m, d_back = 1.56 m: the measured sum of 169.28 is
%   produced by 20 deg of rotation, and equally by ZERO rotation with the source
%   at 4.03 m. Both to the decimal. An earlier version of this header claimed the
%   distance "cancelled out completely" and that anything off +-180 meant the mic
%   had turned; that claim is wrong and it sent a whole diagnosis the wrong way.
%
%   To use this as a yaw measurement you must know the front and back source
%   positions were mirrored -- which is a thing you arrange AT RECORD TIME, with
%   a tape measure or a floor mark, not something you can check afterwards. If
%   you did not, a non-180 sum tells you only that ONE OF the two assumptions
%   broke, not which.
%
%   WHY YOU SHOULD CARE MORE ABOUT THIS THAN ABOUT DIRECTION ERROR
%   Distance comes from the DIFFERENCE between the two bearings. The parallax
%   at 1.5 m on a 1 m baseline is only about 33 degrees, so 15 degrees of
%   relative rotation nearly halves it and roughly doubles the reported range.
%   The same 15 degrees looks like a merely mediocre direction error. A rig
%   that is fine for azimuth can be useless for distance.
%
%   MEASURED ON THE 2026-08-11 SESSION
%       front voice + back clap :  Zylia off by  0.33 deg, Zoom off by  9.84
%       front clap  + back clap :  Zylia off by -10.72,    Zoom off by 14.47
%   The voice pairing is clean and gives the +4.75 that session uses. The clap
%   pairing is 25.19 deg out and CANNOT BE INTERPRETED, for the reason above:
%   the front clap source position was never measured, so an unequal pair of
%   distances explains it as well as a turned mic does. An earlier version of
%   this header asserted the mics turned and cited DRR as proof the source had
%   not moved. DRR only leans that way -- it assumes a uniform reverberant
%   field, and at these distances in this small untreated room the tail is early
%   reflections, which is the same physics that closed floor_bounce_distance.m.
%   See the front clap block in main_2mic.m section 1 for the full trail.

if nargin < 5, verbose = true; end

out.sumA = azFrontA + azBackA;
out.sumB = azFrontB + azBackB;
out.errA = wrap180(out.sumA - 180);
out.errB = wrap180(out.sumB + 180);

% sum - 180 = (yaw in the front take) + (yaw in the back take) for each mic,
% so the difference below is the SUM of the relative misalignment in the two
% takes. If the rig held still between them it was the same both times, and
% half of this is the standing misalignment -- which is the number to feed back
% in as geom.yawB. If it did NOT hold still, this is the total and the two
% takes cannot be separated without a third.
out.relative = out.errB - out.errA;
out.perTake  = out.relative / 2;
% triangulate resamples mic B's map at (grid + yawB), so its effective bearing
% becomes (measured - yawB). We want (measured - perTake). Hence the sign.
out.yawB     = out.perTake;       % pass to triangulate as geom.yawB
out.ok = abs(out.perTake) < 5;

if verbose
    fprintf('\nMicrophone yaw check\n');
    fprintf('  mic A : front %7.2f + back %7.2f = %8.2f   (want +180, off by %+6.2f)\n', ...
            azFrontA, azBackA, out.sumA, out.errA);
    fprintf('  mic B : front %7.2f + back %7.2f = %8.2f   (want -180, off by %+6.2f)\n', ...
            azFrontB, azBackB, out.sumB, out.errB);
    fprintf('  RELATIVE misalignment, both takes combined: %+.2f deg\n', out.relative);
    fprintf('  per take, if the rig held still            : %+.2f deg\n', out.perTake);
    fprintf('  -> set geom.yawB = %+.2f to correct it\n', out.yawB);
    if out.ok
        fprintf('  VERDICT: acceptable. Distance from these takes is trustworthy.\n');
    else
        d = abs(out.perTake);
        fprintf(['  VERDICT: THE RIG MOVED. %.1f deg of relative rotation.\n' ...
                 '  At 1.5 m on a 1 m baseline the true parallax is 36.9 deg, so this\n' ...
                 '  error is %.0f%% of the entire measurement. Expect the reported\n' ...
                 '  distance to be wrong by roughly a factor of %.1f.\n' ...
                 '  Azimuth and elevation are only shifted by %.0f deg and still look fine --\n' ...
                 '  which is exactly why this fault is easy to miss.\n'], ...
                 d, 100*d/36.9, 36.9/max(36.9-d, 1), d);
        fprintf(['\n  FIX IT AT THE RIG, not in software:\n' ...
                 '    1. Mark the front of each mic and line both up against a straight\n' ...
                 '       edge or a tape line on the floor before every take.\n' ...
                 '    2. Strain-relieve the cables. A cable pulling on a sphere on a\n' ...
                 '       stand is enough to turn it 15 degrees.\n' ...
                 '    3. Do not lift or re-seat a mic mid-session. If you must, redo the\n' ...
                 '       front/back pair afterwards and re-run this check.\n' ...
                 '    4. Photograph the rig from above at the start and end.\n']);
    end
end
end

function y = wrap180(x)
y = mod(x + 180, 360) - 180;
end
