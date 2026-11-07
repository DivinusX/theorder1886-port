#!/usr/bin/env python3
"""Sample /proc + amdgpu sysfs for a process tree every 0.5 s until the target exits.

Usage: sampler.py <out.csv> <pid>
Records: per-thread CPU (jiffies delta normalized to % of one core), RSS, whole-tree CPU,
GPU busy %, VRAM used, disk read bytes. Read-only; no state changes. VERIFIED interfaces:
/proc/<pid>/task/<tid>/stat fields 14/15 (utime/stime), /proc/<pid>/statm RSS,
/sys/class/drm/card*/device/gpu_busy_percent and mem_info_vram_used (amdgpu),
/proc/<pid>/io read_bytes.
"""
import os
import sys
import time
from pathlib import Path

PID = int(sys.argv[2])
out = open(sys.argv[1], 'w')
out.write('t,tree_cpu_pct,rss_mb,gpu_busy,vram_mb,rd_kbs\n')
CLK = os.sysconf('SC_CLK_TCK')


def threads(p):
    total = 0
    top = []
    try:
        for tid in os.listdir(f'/proc/{p}/task'):
            try:
                with open(f'/proc/{p}/task/{tid}/stat') as f:
                    parts = f.read().rsplit(') ', 1)[1].split()
                ut, st = int(parts[11]), int(parts[12])
                total += ut + st
                name = open(f'/proc/{p}/task/{tid}/comm').read().strip()
                top.append((ut + st, name))
            except OSError:
                pass
    except OSError:
        pass
    top.sort(reverse=True)
    return total, top[:6]


def children(p):
    kids = []
    try:
        for tid in os.listdir(f'/proc/{p}/task'):
            with open(f'/proc/{p}/task/{tid}/children') as f:
                kids += f.read().split()
    except OSError:
        pass
    return kids


def gpu():
    busy = vram = -1
    for card in Path('/sys/class/drm').glob('card*/device'):
        try:
            b = int((card / 'gpu_busy_percent').read_text())
            v = int((card / 'mem_info_vram_used').read_text()) // (1024 * 1024)
            if b > busy:
                busy, vram = b, v
        except OSError:
            pass
    return busy, vram


prev = None
t0 = time.time()
while True:
    try:
        pids = [PID] + children(PID)
        cpu = 0
        names = {}
        for p in pids:
            tot, top = threads(p)
            cpu += tot
            for ticks, name in top:
                names[name] = max(names.get(name, 0), ticks)
        with open(f'/proc/{PID}/statm') as f:
            rss = int(f.read().split()[1]) * os.sysconf('SC_PAGESIZE') // (1024 * 1024)
        rd = int(open(f'/proc/{PID}/io').read().split('read_bytes:')[1].split()[0]) // 1024
        busy, vram = gpu()
        now = time.time() - t0
        if prev:
            dt = now - prev[0]
            pct = (cpu - prev[1]) / CLK / max(dt, 1e-6) * 100.0
            top_s = '|'.join(f'{n}:{(v - prev[2].get(n, v)) / CLK / max(dt, 1e-6) * 100:.0f}'
                             for n, v in sorted(names.items(), key=lambda x: -x[1])[:4])
            out.write(f'{now:.1f},{pct:.1f},{rss},{busy},{vram},{rd - prev[3]},{top_s}\n')
            out.flush()
        prev = (now, cpu, dict(names), rd)
    except (OSError, ProcessLookupError):
        break
    time.sleep(0.5)
out.close()
