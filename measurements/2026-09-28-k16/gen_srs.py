#!/usr/bin/env python3
import json, os, sys, time
import ezkl

out_dir = sys.argv[1]
settings_path = os.path.join(out_dir, "settings.json")
srs_path = os.path.join(out_dir, "srs.bin")

with open(settings_path) as f:
    logrows = json.load(f)["run_args"]["logrows"]

print(f"gen_srs logrows={logrows} -> {srs_path}", flush=True)
t0 = time.perf_counter()
ezkl.gen_srs(srs_path, logrows)
dt = time.perf_counter() - t0
size = os.path.getsize(srs_path)
print(f"done in {dt:.2f}s, size={size} bytes ({size/1e6:.2f} MB)", flush=True)
