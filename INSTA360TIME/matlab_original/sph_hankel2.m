function h = sph_hankel2(n, x)

x = max(x, 1e-6);
h = sqrt(pi ./ (2 * x)) .* (besselj(n + 0.5, x) - 1i * bessely(n + 0.5, x));
end
