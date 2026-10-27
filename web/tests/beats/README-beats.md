# Beat tracker scorecard (real songs)

The chop engine's beat tracker is tuned on real recordings, not just the synthetic songs in `test_screw_*.js`.

```
sh fetch.sh /tmp/beats          # once: downloads librosa's public test songs (CC licensed), makes reference beats
node score.js /tmp/beats        # how often it's locked, on the right tempo (or half/double), and on the beat
SR=48000 node score.js /tmp/beats   # same at 48 kHz (iPhones, many browsers)
node neg.js /tmp/beats          # things with no beat (noise, held chord, whale song): should not lock
```

Reference beats come from `ref.py`, an offline whole-song tracker (spectral flux, autocorrelation, dynamic-programming
beats, after Ellis 2007). "Let's Go Fishin'" is genuinely ambiguous (118 BPM vs a 3:2 feel), so it scores low on any setting.

| version | locked | right tempo | on the beat (±50 ms) |
|---|---|---|---|
| 1.6 (energy bands, 6 s, no memory) | 90% | 39% | 23% |
| 1.7 (spectral flux, tempo memory, harmonic votes) | 98% | 78% | 62% |
