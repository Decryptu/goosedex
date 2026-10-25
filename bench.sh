#!/bin/bash
# Compares goosedex with other Pokemon sprite viewers: the time of `random`
# with hyperfine, its peak memory, and the binary's size.
#
# Usage: ./bench.sh [runs] [binary...]
# Defaults to out/goosedex plus zigdex, pokeget and krabby where installed.
set -euo pipefail

runs=${1:-2000}
shift || true
bins=("$@")
if [ ${#bins[@]} -eq 0 ]; then
    bins=(out/goosedex)
    for b in zigdex pokeget krabby; do
        if command -v "$b" > /dev/null; then bins+=("$(command -v "$b")"); fi
    done
fi

json=$(mktemp)
trap 'rm -f "$json"' EXIT
cmds=()
for b in "${bins[@]}"; do cmds+=("$b random"); done
hyperfine -N --warmup 200 --runs "$runs" --export-json "$json" "${cmds[@]}" > /dev/null

python3 - "$json" "${bins[@]}" <<'PY'
import json, os, statistics, sys

results = json.load(open(sys.argv[1]))["results"]
print("%-16s %10s %10s %10s %10s" % ("binary", "mean", "median", "memory", "size"))
for path, r in zip(sys.argv[2:], results):
    ms = r["measurements"]
    wall = [m["time_wall_clock"]["value"] * 1e3 for m in ms]
    mem = max(m["memory_peak_resident"]["value"] for m in ms) / 2**20
    print("%-16s %7.3f ms %7.3f ms %6.2f MiB %7.2f MB" % (
        os.path.basename(path), statistics.mean(wall), statistics.median(wall), mem,
        os.path.getsize(path) / 1e6))
PY
