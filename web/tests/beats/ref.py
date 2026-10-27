import numpy as np, glob, sys
sr, hop, nfft = 44100, 512, 2048
def flux(x):
    w = np.hanning(nfft); n = (len(x) - nfft) // hop
    fr = np.lib.stride_tricks.as_strided(x, (n, nfft), (x.strides[0] * hop, x.strides[0])) * w
    S = np.log1p(100 * np.abs(np.fft.rfft(fr, axis=1)))
    # mel-ish: pool into 40 log-spaced bands
    edges = np.unique(np.geomspace(2, S.shape[1] - 1, 41).astype(int))
    B = np.stack([S[:, a:b].mean(1) for a, b in zip(edges[:-1], edges[1:])], 1)
    o = np.maximum(0, np.diff(B, axis=0)).mean(1)
    o = o - np.convolve(o, np.ones(16) / 16, "same")
    return np.maximum(o, 0)
def track(x, rate=1.0):
    o = flux(x); hps = sr / hop
    ac = np.correlate(o - o.mean(), o - o.mean(), "full")[len(o) - 1:]
    lags = np.arange(int(hps * 60 / 200), int(hps * 60 / 50))
    bpm = 60 * hps / lags
    w = np.exp(-0.5 * (np.log2(bpm / 120) / 1.0) ** 2)
    L = lags[np.argmax(ac[lags] * w)]
    # parabolic refine
    a, b, c = ac[L - 1], ac[L], ac[L + 1]; Lr = L + 0.5 * (a - c) / (a - 2 * b + c)
    # Ellis DP
    P = Lr; score = o.copy(); back = -np.ones(len(o), int)
    for t in range(len(o)):
        lo, hi = int(t - 2 * P), int(t - P / 2)
        if hi <= 0: continue
        rng = np.arange(max(lo, 0), hi)
        cost = -100 * (np.log((t - rng) / P)) ** 2
        k = np.argmax(score[rng] + cost); score[t] += score[rng][k] + cost[k]; back[t] = rng[k]
    t = np.argmax(score[-int(P):]) + len(o) - int(P); beats = []
    while t >= 0: beats.append(t); t = back[t]
    beats = (np.array(beats[::-1]) + 1) * hop / sr + nfft / 2 / sr
    return 60 * hps / Lr, beats
for f in sorted(glob.glob(sys.argv[1] + "/*.f32")):
    x = np.fromfile(f, dtype=np.float32).reshape(-1, 2).mean(1).astype(np.float64)
    for rate in (1.0, 0.8):
        if rate != 1.0:
            m = int(len(x) / rate); xi = np.arange(m) * rate; y = np.interp(xi, np.arange(len(x)), x)
        else: y = x
        bpm, beats = track(y)
        np.save(f.replace(".f32", f".x{rate}.beats.npy"), beats)
        print(f.split("/")[-1], rate, round(bpm, 1), len(beats), round(float(np.median(np.diff(beats))), 3))
