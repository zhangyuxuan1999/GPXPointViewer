#!/bin/zsh
# 地区索引/统计离线探针：编 app 里的 RegionIndex.swift + RegionStats.swift（Foundation-only）+ 桩 TrackData，跑合成边界的全部断言。
# 用法：Tests/probes/regions/run.sh   （约 20 秒；TZ 默认 Europe/Berlin，可 TZ=America/New_York Tests/probes/regions/run.sh）
set -e
cd "$(dirname "$0")/../../.."
OUT=${TMPDIR:-/tmp}/regions_probe
swiftc -O -o "$OUT" GPXPointViewer/RegionIndex.swift GPXPointViewer/RegionStats.swift GPXPointViewer/FogArchive.swift Tests/probes/regions/Stub.swift Tests/probes/regions/realdata.swift Tests/probes/regions/main.swift
[[ -f Tests/synth/regions_synthetic2.bin ]] || python3 -I Tools/build_regions.py --synthetic2 Tests/synth/regions_synthetic2.bin
# 真实数据模式：run.sh --real <Regions.bin> --csv|--fwdb|--lookup|--audit …（见 realdata.swift）
if [[ "$1" == "--real" ]]; then shift; exec "$OUT" "$@"; fi
TZ=${TZ:-Europe/Berlin} "$OUT" Tests/synth/regions_synthetic.bin Tests/synth/regions_synthetic2.bin
