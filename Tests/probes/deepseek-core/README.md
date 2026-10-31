# FogArchive / GPXWriter 边界探针

本目标编译实际产品源码，离线检查 N-20 文件名区块号边界和 N-26 非法选择的可处理失败；也检查合法 GPX 的真段/窗口/合成点身份，以及已有单段并行写出分支的完整点数。仅复用 `Tests/segments/core/Support.swift` 的 GPU 发布隔离与 `PointKey` 值结构，不启动产品窗口。

```sh
python3 Tests/probes/deepseek-core/run.py /private/tmp/gpxpv-deepseek-core-unique
```

必须给全新目录。命令、完整编译与运行 stdout/stderr、真实退出码、源码哈希、夹具与 `checks.json` 均保存在该目录。`.fwdb` 单格夹具由 Python zlib 产生，预期世界键直接来自格式布局；导出文件由 Foundation XMLParser 独立核对。此目标不是全套回归或性能基准。
