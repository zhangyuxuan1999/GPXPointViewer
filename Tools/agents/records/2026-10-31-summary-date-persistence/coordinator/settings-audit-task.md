# 语言与闲置展示持久化回归根因调查 — Sol ultra
请求gpt-6.1-sol，ultra。只读产品/历史记录；仅写本run证据与建议，暂不改产品。使用engineering:debug方法。
用户明确报告：语言、是否开启闲时展示，每次打开App都得重设；以前已实现持久化，现回归。root当前查到TrackStore.swift:931–990仍用UserDefaults.standard恢复/保存idleDisabled、idleGlobeSeconds、idleMapSeconds、appearanceMode、mapStyle；ContentView language/AppLanguage也有写AppleLanguages逻辑。要查实际根因，不止确认代码存在。
关键时间线：本次安装从已验收unsigned/no-sign archive Builds/20261030T060514Z_release_4bd65c63/archive/GPXPointViewer.app复制到Applications；新exeSHA64d5101be7c3239d10e0cfd01109b3220899f992f9865d1eda0dc2b606b5e883。安装前旧appSHAa901e819c26dab26af37366507792c7cbc670093f1c90050ccfa08f5a04c2210，备份Tools/agents/records/2026-10-31-install/20261031T010133.762744Z/backup/GPXPointViewer.app。旧启动AX中文、新默认启动AX英文；安装仅复制bundle、未改用户偏好。此前UI副本继承/恢复偏好是否用正确domain也须查。怀疑sandbox entitlement/签名导致UserDefaults域变化，但必须证据核实。
允许只读 codesign/Info.plist/二进制元数据，历史构建manifest、修改快照、AppLanguage.swift/TrackStore/Settings/测试驱动/Tools归档相关源。真实偏好只允许读取这几个已知键的值/类型/路径：AppleLanguages、idleDisabled、idleGlobeSeconds、idleMapSeconds、appearanceMode、mapStyle；绝不输出完整plist、其他私有字段、轨迹、凭据。读不到权限可请root提供白名单读证据，不自动扩大读取。
比较旧版/新签名entitlement与偏好存储机制；检查更新设置异步main任务/重启写入竞争、测试cleanup、已有defaults逻辑。可在独立临时目录做不涉及真实偏好的最小孤立探针，先写原因并保存源码/输出，不编全app、不跑UI，不重复既有测试。给根因置信度、证据、推荐兼容迁移/写入策略（不覆盖用户最近选择）以及最小验证。root会根据发现安排实施；不要直接在两个偏好域复制整份真实plist或修改真实设置。

## 协作留档与禁止项
先读项目AGENTS.md，遵守原始证据复用；只有具体矛盾/缺证/修复后受影响行为才做最小定向验证，理由预先写入本run。所有命令通过项目已有capture.py保存正常argv/stdout/stderr/exit，环境GPXPV_COMMAND_RECORD_ROOT设成本run/artifacts/capture。帮助脚本路径：/Users/zyx/Documents/GPXPointViewer/Tools/agents/records/2026-10-30-journey-summary/coordinator/capture.py。任何新脚本先保存再执行，不经未留档stdin。读大文件分段，完整输出存盘。
每主要阶段写progress.md并调用 python3 Tools/agents/agent_run.py event RUN --type progress --json ...。记录请求模型强度、实际agentID，供应商模型/费用未暴露unknown/null。不索取/记录思维链。不创建侧栏聊天或其他代理。保存完整output.md/result证据后调用finish(provider succeeded, acceptance pending)，主代理独立verify。
保留工作区大量既有改动，无gitreset/清理/commit/push。不得运行正式App、修改真实偏好、关闭用户App、安装应用、跑UI、调用公共路由；安装由主代理最终协调。任何允许修改文件必须前后逐字节快照/哈希及新增删除清单，记录不覆盖失败。
