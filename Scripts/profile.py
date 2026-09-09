#!/usr/bin/env python3
"""Read-only RSS, physical-footprint and CPU measurement of an already-running app."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('pid', type=int)
parser.add_argument('--seconds', type=int, default=30)
parser.add_argument('--output', type=Path)
args = parser.parse_args()
if args.pid <= 0 or not 1 <= args.seconds <= 60:
    parser.error('Use a positive PID and a duration between 1 and 60 seconds')

def sample():
    value = subprocess.check_output(['ps', '-p', str(args.pid), '-o', 'rss=,time='], text=True).split()
    cpu = sum(float(n) * 60 ** i for i, n in enumerate(reversed(value[1].split(':'))))
    return int(value[0]) / 1024, cpu

try:
    _, start_cpu = sample()
    start = time.monotonic()
    time.sleep(args.seconds)
    rss, end_cpu = sample()
    duration = time.monotonic() - start
    vmmap = subprocess.check_output(['vmmap', '-summary', str(args.pid)], text=True, stderr=subprocess.STDOUT)
except subprocess.CalledProcessError as error:
    raise SystemExit(f'Cannot measure process {args.pid}; it may have exited or access was denied (status {error.returncode}).')
footprint = re.search(r'^Physical footprint:\s*(.+)$', vmmap, re.MULTILINE)
peak = re.search(r'^Physical footprint \(peak\):\s*(.+)$', vmmap, re.MULTILINE)
result = {
    'pid': args.pid, 'duration_seconds': round(duration, 2),
    'rss_mib': round(rss, 2), 'physical_footprint': footprint.group(1).strip() if footprint else 'unavailable',
    'peak_physical_footprint': peak.group(1).strip() if peak else 'unavailable',
    'cpu_seconds': round(end_cpu - start_cpu, 3),
    'cpu_percent_one_core': round(100 * (end_cpu - start_cpu) / duration, 3),
}
encoded = json.dumps(result, indent=2) + '\n'
print(encoded, end='')
if args.output:
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(encoded)
    args.output.with_suffix('.vmmap.txt').write_text(vmmap)
