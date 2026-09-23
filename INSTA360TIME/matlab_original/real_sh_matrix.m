function Y = real_sh_matrix(order, az, el)

az = az(:).';
el = el(:).';
K  = numel(az);
Y  = zeros((order + 1)^2, K);

for n = 0:order
    % legendre() returns P_n^m(x) for m = 0..n
    % Condon-Shortley phase (-1)^m
    Pn = legendre(n, sin(el));          % (n+1) x K
    if n == 0
        Pn = Pn(:).';                   % make sure it is 1 x K
    end
    for m = -n:n
        acn = n^2 + n + m + 1;          % +1 for MATLAB 1-based indexing
        am  = abs(m);

        P = ((-1)^am) * Pn(am + 1, :);  % remove Condon-Shortley phase

        c = sqrt((2*n + 1) * factorial(n - am) / factorial(n + am));
        if m ~= 0
            c = c * sqrt(2);
        end

        if m < 0
            trig = sin(am * az);
        else
            trig = cos(am * az);
        end

        Y(acn, :) = c * P .* trig;
    end
end
end
