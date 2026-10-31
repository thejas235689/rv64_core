def modexp_model(base, exp, n, r2, r_one, words, ebits):
    R = 1 << (64 * words); rinv = pow(R, -1, n)
    mont = lambda x, y: (x * y * rinv) % n
    ops, trace = [], []
    ops.append((base, r2)); base_m = mont(base, r2); trace.append(base_m)
    acc = r_one
    for bit in range(ebits - 1, -1, -1):
        ops.append((acc, acc)); acc = mont(acc, acc); trace.append(acc)
        if (exp >> bit) & 1:
            ops.append((acc, base_m)); acc = mont(acc, base_m); trace.append(acc)
    ops.append((acc, 1)); acc = mont(acc, 1); trace.append(acc)
    return ops, trace, acc
