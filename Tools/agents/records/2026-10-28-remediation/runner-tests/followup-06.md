主代理复核发现 native 已自己产出 run/output.md 后，CLI finish --output run/output.md 会被 RunStore.finish 的 exclusive=True 拒绝（工具未覆盖原生任务常用收尾路径）。已请实现修成同内容可 finalize、不同内容保留证据且不静默覆盖、已有 result 仍不能重写。请加离线回归并核验；先前测试证据保留。
