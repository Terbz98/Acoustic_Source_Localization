function [W, grid] = build_steering_matrix(cfg, freqs)

[AZ, EL, R] = ndgrid(cfg.azGrid, cfg.elGrid, cfg.rGrid);
grid.az   = AZ(:).';
grid.el   = EL(:).';
grid.r    = R(:).';
grid.size = size(AZ);                 % [nAz nEl nR]

K   = numel(AZ);
nCh = (cfg.order + 1)^2;

Ymat   = real_sh_matrix(cfg.order, grid.az, grid.el);   % nCh x K (real)
nOfAcn = floor(sqrt(0:nCh - 1));                        % order of each channel

% ---- Spherical-array order cut-on -------------------------------------
% A small spherical mic (Zoom H3-VR, Zylia ZM-1, ...) only carries usable
% order-n information ABOVE the cut-on frequency  f_n = n*c/(2*pi*R), where
% R is the capsule-sphere radius. Below f_n the order-n ambisonic channels
% are dominated by regularisation / self-noise (their energy blows up well
% past the omni), and folding them into the SRP wrecks the estimate.
%
% So we make the effective order FREQUENCY DEPENDENT: at each analysis bin
% we only keep the orders whose cut-on lies below that frequency (order 0-1
% low, up to cfg.order high). This is the standard way to run a rigid/open
% spherical microphone and it is what previously broke the 3rd-order Zylia
% runs -- the old [800 4000] Hz band sat below the order-2 (~2.2 kHz) and
% order-3 (~3.3 kHz) cut-ons, so channels 5-15 were pure noise.
if isfield(cfg, 'micRadius') && cfg.micRadius > 0
    fCut = (0:cfg.order) * cfg.c / (2*pi*cfg.micRadius);   % 1 x (order+1)
else
    fCut = zeros(1, cfg.order + 1);                        % disabled -> all orders
end

W = complex(zeros(nCh, K, numel(freqs)));

for fi = 1:numel(freqs)
    kf = 2 * pi * freqs(fi) / cfg.c;                    % wavenumber
    h0 = sph_hankel2(0, kf * grid.r);                   % 1 x K

    Wf = complex(zeros(nCh, K));
    for n = 0:cfg.order
        if freqs(fi) < fCut(n + 1)
            continue;                                   % order n not valid yet here
        end
        Rn = (1i)^(-n) * sph_hankel2(n, kf * grid.r) ./ h0;   % near-field term
        rows = (nOfAcn == n);
        Wf(rows, :) = Ymat(rows, :) .* Rn;              % Y * R_n
    end

    % Unit-normalize each candidate template (guard against all-zero columns
    % that can occur when no order is valid at a very low frequency).
    nrm = sqrt(sum(abs(Wf).^2, 1));
    nrm(nrm == 0) = 1;
    W(:, :, fi) = Wf ./ nrm;
end
end
