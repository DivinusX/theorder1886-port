#!/usr/bin/env python3
"""Turn one run's artifacts into a metrics JSON.

Inputs: frame-trace CSV (event,timestamp_ns,render_serial,buffer_address,loading),
boot log (Stall/VideoOut/Pipeline/Settings lines), sampler CSV.
Frame pacing is computed from guest flip timestamps (VERIFIED format:
gpu/shim/ps4_frame_trace.h). Loading flips are excluded from steady-state stats but
counted separately as load stalls.

Usage: metrics.py <label> <trace.csv> <boot.log> <sampler.csv> <out.json>
"""
import csv
import json
import re
import sys
import statistics


def pct(sorted_vals, p):
    if not sorted_vals:
        return None
    i = min(len(sorted_vals) - 1, max(0, int(round((p / 100.0) * (len(sorted_vals) - 1)))))
    return sorted_vals[i]


label, trace, boot, samp, out = sys.argv[1:6]
flips = []
presents = []
loading = 0
try:
    with open(trace) as f:
        for row in csv.DictReader(f):
            ev = row.get('event')
            if ev == 'guest_flip':
                if row.get('loading') == '1':
                    loading += 1
                else:
                    flips.append(int(row['timestamp_ns']))
            elif ev == 'host_present':
                presents.append(int(row['timestamp_ns']))
except OSError:
    pass

intervals = [(b - a) / 1e6 for a, b in zip(flips, flips[1:])]
# keep the sane range; a >1 s gap is a load/pause, count it as hitch separately
big = [ms for ms in intervals if ms > 1000]
intervals = [ms for ms in intervals if 0 < ms <= 1000]
res = {'label': label, 'flips': len(flips), 'loading_flips': loading,
       'long_gaps': len(big), 'presents': len(presents)}
if presents:
    p = sorted((b - a) / 1e6 for a, b in zip(presents, presents[1:]) if 0 < (b - a) / 1e6 <= 1000)
    if p:
        res['pres_med'] = round(statistics.median(p), 2)
        res['pres_p95'] = round(pct(p, 95), 2)
        res['pres_p99'] = round(pct(p, 99), 2)
        res['pres_max'] = round(p[-1], 2)
if intervals:
    s = sorted(intervals)
    med = statistics.median(s)
    fps = [1000.0 / ms for ms in s]
    fs = sorted(fps)
    res.update({
        'avg_fps': round(1000.0 / statistics.mean(s), 2),
        'median_fps': round(1000.0 / med, 2),
        'p01_low_fps': round(fs[0], 2),          # worst frame = 0.1% low
        'p1_low_fps': round(pct(fs, 1), 2),
        'ft_min': round(s[0], 2), 'ft_med': round(med, 2),
        'ft_p95': round(pct(s, 95), 2), 'ft_p99': round(pct(s, 99), 2),
        'ft_max': round(s[-1], 2),
        'hitches_gt_2x_med': sum(1 for ms in s if ms > 2 * med),
        'hitch_ms_sum': round(sum(ms - med for ms in s if ms > 2 * med), 1),
        'jitter_p95_minus_med': round(pct(s, 95) - med, 2),
    })
    # gameplay window: the last 100 s of flips (scenario idles/looks around in-scene there)
    if flips:
        cutoff = flips[-1] - 100_000_000_000
        gw = sorted((b - a) / 1e6 for a, b in zip(flips, flips[1:])
                    if a >= cutoff and 0 < (b - a) / 1e6 <= 1000)
        if gw:
            gmed = statistics.median(gw)
            gfps = sorted(1000.0 / ms for ms in gw)
            res['game'] = {'avg_fps': round(1000.0 / statistics.mean(gw), 2),
                           'ft_med': round(gmed, 2), 'ft_p95': round(pct(gw, 95), 2),
                           'ft_p99': round(pct(gw, 99), 2), 'ft_max': round(gw[-1], 2),
                           'p1_low_fps': round(pct(gfps, 1), 2),
                           'hitches': sum(1 for ms in gw if ms > 2 * gmed),
                           'n': len(gw)}

text = open(boot, errors='replace').read() if len(boot) > 4 else ''
for name, pat in [('pipeline_cache', r'Pipeline binary cache: .*'),
                  ('settings', r'Settings: .*'),
                  ('swapchain', r'Swapchain: .*'),
                  ('upscaler', r'Upscaler: .*'),
                  ('frame_limit', r'VideoOut: frame limit .*'),
                  ('output', r'Output: .*'),
                  ('dmem', r'.*DMEM.*')]:
    m = re.search(pat, text)
    res[name] = m.group(0) if m else None
res['stall_lines'] = len(re.findall(r'Stall: ', text))
res['runtime_profile'] = re.findall(r'Runtime:   .*', text)[:8]
res['cpu_total'] = re.findall(r'Runtime: CPU time by thread: .*', text)
res['srt_errors'] = len(re.findall(r'SRT offset failure', text))
res['layer_guard'] = len(re.findall(r'exceeds.*layer|refus', text, re.I))
res['errors'] = re.findall(r'ERROR: .*', text)[:6]

try:
    rows = list(csv.DictReader(open(samp)))
    if rows:
        res['cpu_tree_mean'] = round(statistics.mean(float(r['tree_cpu_pct']) for r in rows), 1)
        res['rss_max_mb'] = max(int(r['rss_mb']) for r in rows)
        gpus = [int(r['gpu_busy']) for r in rows if int(r['gpu_busy']) >= 0]
        res['gpu_busy_mean'] = round(statistics.mean(gpus), 1) if gpus else None
        res['vram_max_mb'] = max((int(r['vram_mb']) for r in rows if int(r['vram_mb']) >= 0), default=-1)
except OSError:
    pass

json.dump(res, open(out, 'w'), indent=1)
print(json.dumps(res, indent=1))
