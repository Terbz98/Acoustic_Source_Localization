function b = convert_to_acn_n3d(x, fmt, order)

nCh = (order + 1)^2;
if size(x, 2) < nCh
    error(['Recording has %d channels but order %d needs %d.\n' 'Check the recorder was in Ambisonics (FuMa/AmbiX) mode, ' ...
           'not stereo/binaural.'], size(x, 2), order, nCh);
end
x = x(:, 1:nCh);

switch lower(fmt)
    case 'ambix'                 % already ACN / SN3D
        b = x;

    case 'fuma'                  % 1st order: [W X Y Z], W recorded at -3 dB
        if order ~= 1
            error('FuMa conversion is implemented for 1st order only.');
        end
        %        W (restore -3dB)   Y        Z        X      -> ACN order
        b = [x(:,1) * sqrt(2),  x(:,3),  x(:,4),  x(:,2)];

    otherwise
        error('Unknown input format "%s" (use ''ambix'' or ''fuma'').', fmt);
end

% SN3D -> N3D : multiply every order-n channel by sqrt(2n + 1)
nOfAcn = floor(sqrt(0:nCh - 1));         % ambisonic order of each ACN channel
b = b .* sqrt(2 * nOfAcn + 1);
end
