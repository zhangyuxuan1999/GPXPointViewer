#!/bin/zsh
# 下载行政区边界原始数据（需要用户批准后再运行；本脚本只下载，不生成 Regions.bin）。
# 来源与大小（2026-10 时的估计）：
#   Natural Earth 10m（公共领域，GitHub 镜像 nvkelso/natural-earth-vector）：
#     ne_10m_admin_0_countries.geojson            国家，约 24 MB
#     ne_10m_admin_1_states_provinces.geojson     一级行政区（州/省），约 42 MB
#   阿里云 DataV GeoAtlas（areas_v3/bound/<省级 adcode>_full.json）：34 份省级文件，每份 0.3–3 MB，合计约 40 MB，
#     每份含该省全部地级（直辖市为区）边界。
# 下载到 data/regions-src/{ne,datav}/（各自独立目录；下载内容按不可信数据处理，只作为参数传给 build_regions.py）。
# 之后：python3 -I Tools/build_regions.py --countries data/regions-src/ne/ne_10m_admin_0_countries.geojson \
#        --admin1 data/regions-src/ne/ne_10m_admin_1_states_provinces.geojson --china-dir data/regions-src/datav \
#        --out GPXPointViewer/Regions.bin
set -e
cd "$(dirname "$0")/.."
NE=data/regions-src/ne; DV=data/regions-src/datav
mkdir -p "$NE" "$DV"
NE_TAG=v5.1.2   # 钉住版本：master 会悄悄改字段名/边界
BASE=https://raw.githubusercontent.com/nvkelso/natural-earth-vector/$NE_TAG/geojson
for f in ne_10m_admin_0_countries.geojson ne_10m_admin_1_states_provinces.geojson; do
  if [[ ! -s "$NE/$f" ]]; then
    curl -fL --retry 3 -o "$NE/$f.part" "$BASE/$f" && python3 -I -c "import json,sys; json.load(open(sys.argv[1]))" "$NE/$f.part" && mv "$NE/$f.part" "$NE/$f" || { echo "FAILED $f"; rm -f "$NE/$f.part"; exit 1; }
  fi
  ls -la "$NE/$f"
done
# 省级 adcode：4 直辖市、23 省、5 自治区、2 特区（台湾 710000 DataV 无地级数据，跳过不报错）
# 31 个大陆省级 adcode（港澳台在 NE 里是独立国家，不走 DataV）
for code in 110000 120000 130000 140000 150000 210000 220000 230000 310000 320000 330000 340000 350000 360000 370000 \
            410000 420000 430000 440000 450000 460000 500000 510000 520000 530000 540000 610000 620000 630000 640000 650000; do
  if [[ ! -s "$DV/${code}_full.json" ]]; then
    curl -fL --retry 3 -o "$DV/${code}_full.json.part" "https://geo.datav.aliyun.com/areas_v3/bound/${code}_full.json" || { echo "FAILED $code"; exit 1; }
    python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); assert any(f.get('properties',{}).get('level') in ('city','district') for f in d['features'])" "$DV/${code}_full.json.part" \
      || { echo "BAD CONTENT $code"; rm -f "$DV/${code}_full.json.part"; exit 1; }
    mv "$DV/${code}_full.json.part" "$DV/${code}_full.json"
  fi
  sleep 0.5   # 公共服务，别并发
done
# 港澳：DataV 有分区数据（世界迷雾也细分到区）；NE 里它们是独立国家，构建时挂到 HK / MO 之下
for code in 810000 820000; do
  if [[ ! -s "$DV/${code}_full.json" ]]; then
    curl -fL --retry 3 -o "$DV/${code}_full.json.part" "https://geo.datav.aliyun.com/areas_v3/bound/${code}_full.json" || { echo "FAILED $code"; exit 1; }
    python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); assert len(d['features'])>0" "$DV/${code}_full.json.part" || { echo "BAD CONTENT $code"; rm -f "$DV/${code}_full.json.part"; exit 1; }
    mv "$DV/${code}_full.json.part" "$DV/${code}_full.json"
  fi
  sleep 0.5
done
# 每份都得是合法 GeoJSON 且含 city/district 要素；顺手印 sha256 以便复现
python3 -I - "$NE" "$DV" <<'PY'
import json, sys, glob, os, hashlib
ne, dv = sys.argv[1], sys.argv[2]
for f in sorted(glob.glob(os.path.join(ne, "*.geojson"))):
    d = json.load(open(f, encoding="utf-8")); print(os.path.basename(f), len(d.get("features", [])), "features", hashlib.sha256(open(f, "rb").read()).hexdigest()[:16])
bad = 0
for f in sorted(glob.glob(os.path.join(dv, "*_full.json"))):
    try:
        d = json.load(open(f, encoding="utf-8")); n = sum(1 for ft in d.get("features", []) if ft.get("properties", {}).get("level") in ("city", "district"))
    except Exception as e: n = 0; print("BAD", f, e)
    if n == 0: bad += 1
    print(os.path.basename(f), n, "city/district features")
if bad: raise SystemExit(f"{bad} DataV files unusable")
PY
# 国界换成 geoBoundaries CGAZ ADM0（按美国国务院国界线裁剪；CC BY 4.0，各国源另有许可；港澳在里面并入中国，构建时保留 NE 的）
CG=data/regions-src/cgaz; mkdir -p "$CG"
if [[ ! -s "$CG/geoBoundariesCGAZ_ADM0.geojson" ]]; then
  curl -fL --retry 3 -o "$CG/geoBoundariesCGAZ_ADM0.geojson.part" "https://github.com/wmgeolab/geoBoundaries/raw/main/releaseData/CGAZ/geoBoundariesCGAZ_ADM0.geojson" \
    && python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); assert len(d['features'])>200" "$CG/geoBoundariesCGAZ_ADM0.geojson.part" \
    && mv "$CG/geoBoundariesCGAZ_ADM0.geojson.part" "$CG/geoBoundariesCGAZ_ADM0.geojson" || { echo "FAILED CGAZ"; rm -f "$CG/geoBoundariesCGAZ_ADM0.geojson.part"; exit 1; }
fi
du -sh data/regions-src
echo "构建：python3 -I Tools/build_regions.py --countries $NE/ne_10m_admin_0_countries.geojson --admin1 $NE/ne_10m_admin_1_states_provinces.geojson --china-dir $DV --countries-geom $CG/geoBoundariesCGAZ_ADM0.geojson --tolerance-m-l0 100 --out GPXPointViewer/Regions.bin"
