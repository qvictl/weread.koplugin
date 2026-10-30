# weread.koplugin 维护与交付报告（2026-10-29）

证据快照：2026-10-29 17:30 UTC；报告整理：2026-10-30 UTC。

本轮插件开发子任务已结束，[v1.6.92](https://github.com/qvictl/weread.koplugin/releases/tag/v1.6.92)
已发布，tag/source 为 `c5855b317477db59c8896e2bc4832d6961d0ab48`。
三仓总报告见 [KOReader 维护报告](https://github.com/qvictl/koreader/blob/main/doc/reports/2026-10-29-maintenance.md)。
本文记录本轮已确认修复和实测，不表示全库无缺陷或原 811 章真机卡死已消失。

## 缺陷修复和结构变化

| 问题范围 | 已交付结果 | PR |
| --- | --- | --- |
| 持久化和 UI 测试暴露的缺陷 | 增加真实组件回归，修复已有缺陷及 thought DB 缺失目录 | [#43](https://github.com/qvictl/weread.koplugin/pull/43)、[#44](https://github.com/qvictl/weread.koplugin/pull/44)、[#45](https://github.com/qvictl/weread.koplugin/pull/45)、[#47](https://github.com/qvictl/weread.koplugin/pull/47) |
| 阅读进度和资源解包 | 正确同步滚动位置，失败 TAR/ZIP 资源回滚 | [#48](https://github.com/qvictl/weread.koplugin/pull/48) |
| 下载与 checkpoint 等待 | 避免冗余等待，保留恢复和最终 EPUB 正确性 | [#49](https://github.com/qvictl/weread.koplugin/pull/49) |
| 字面缓存目录和失败预取 | 不把目录名当 shell 语法；父进程 save 失败后释放作业 | [#50](https://github.com/qvictl/weread.koplugin/pull/50)、[#51](https://github.com/qvictl/weread.koplugin/pull/51) |
| 书架、书评、目录、统计与扫描 | 网络等待移出 UI；扫描协作分片，取消和窗口生命周期可控 | [#52](https://github.com/qvictl/weread.koplugin/pull/52)、[#53](https://github.com/qvictl/weread.koplugin/pull/53) |
| 公众号、登录及其余网络交互 | 列表和内容下载、QR 轮询、批注网络操作保持响应，可取消且拒绝过期结果 | [#54](https://github.com/qvictl/weread.koplugin/pull/54)、[#55](https://github.com/qvictl/weread.koplugin/pull/55)、[#57](https://github.com/qvictl/weread.koplugin/pull/57)、[#58](https://github.com/qvictl/weread.koplugin/pull/58) |
| 账号与请求归属 | 隔离预取/手动下载旧账号结果、进度网络工作及请求所有权 | [#56](https://github.com/qvictl/weread.koplugin/pull/56)、[#59](https://github.com/qvictl/weread.koplugin/pull/59)、[#61](https://github.com/qvictl/weread.koplugin/pull/61) |
| 封面资源命名 | 处理同名封面冲突，避免挂起与重复扫描，缓存有界 | [#62](https://github.com/qvictl/weread.koplugin/pull/62) |
| 进程级 fork 预算 | Runtime 内共享串行预算，槽位保持到精确 PID reap，取消/owner/排队路径有回归 | [#63](https://github.com/qvictl/weread.koplugin/pull/63) |
| 手动待同步进度 | 关闭关书自动上传时，重开/恢复阅读后重试此前手动发起的快照，保留冲突判断 | [#63](https://github.com/qvictl/weread.koplugin/pull/63) |
| 章节状态跨进程传输 | 返回当前章节增量，父进程只在接受结果后应用；避免回传整书 dl.state | [#64](https://github.com/qvictl/weread.koplugin/pull/64) |
| reader 会话 | 同一下载任务复用 reader 状态，保持 catalog UID/idx；缺元数据、失败和外层重试走 fresh 回退 | [#67](https://github.com/qvictl/weread.koplugin/pull/67) |

上述边界将 Runtime、owner、fork 预算、章节状态和 reader 会话分开管理，避免旧实例或旧账号结果写回当前 UI。
它们已有单位/组件与真实 worker 场景回归；不把带替身的 fixture 一概描述成完整操作系统或真实网站端到端测试。

## 性能结果与局限

| 项目 | 主机观察 | 限定 |
| --- | --- | --- |
| 资源同名分配 | 2,000 候选中位耗时 4,453.852→10.136 ms；1,000 候选 810.468→4.838 ms | 保留堆约 123.3→128.9 KiB，非内存下降或 Kindle 吞吐测量 |
| 章节状态文件 | 旧整状态 1,767,176 B→当前结果文件约 5.7 KB | 实际 BackgroundWorker 跨进程文件通道；不是 pipe 容量测量，不据此声称 RSS 或整书加速 |
| reader 会话请求 | 控制场景 GET 4→2，含初始请求 | 真实两章 reuse/fresh 协议样本解码一致；不是全网站/全书籍保证；最终 release 完整场景也覆盖该逻辑 |
| 缓存扫描/导入历史样本 | 峰值 RSS 285,068→112,900 KiB；UI 间隔 5,478→374 ms | 总耗时 5,998→8,713 ms，约慢 45%，明确保留此代价 |

v1.6.92 真实发布矩阵的 200 章预算结果如下；它们是受控 mock 输入下的 Linux 主机结果，
不是 Kindle 成绩，也不是拿不同运行时作优化前后对比：

| 运行时 | 下载任务总耗时 | Lua 下载后增长 | RSS 峰增长 | finalize 最大批次 |
| --- | --- | --- | --- | --- |
| fork nightly `8e9a159e` | 33.723 s | 920 KiB | 12,720 KiB | 202 ms |
| 官方 v2026.07.1 | 34.159 s | 887 KiB | 12,400 KiB | 179 ms |

两者均通过预算并验证 200 章 EPUB。本文不将 RSS 峰增长与下载后增长混用。

## 发布验收和覆盖率

[唯一自动 Release 40919127472](https://github.com/qvictl/weread.koplugin/actions/runs/40919127472)
整体成功，用时 7 分 56 秒；发布源来自版本 [PR #69](https://github.com/qvictl/weread.koplugin/pull/69)。

| 项目 | 结果 |
| --- | --- |
| 完整普通 UT | 145 个业务 spec 文件通过 |
| 真实集成 | fork 30/30，官方 30/30，均含 200 章；固定 KOReader 版本的 PluginLoader 通过 |
| 全量 unit | 91.55%，19,734/21,555 |
| unit + emulator | 93.65%，20,278/21,653 |
| 未发布整批改动 combined diff | 95.83%，368/384；基线 `d653e154d49363657410724d4be5ec7e7770daa4` |
| 覆盖率与发布顺序 | 原当前 blocking gates、真实三分片来源绑定、同步 persist/attempt ack 后再打包发布，全部通过 |
| 公开包 | SHA-256 `579e0659c4f6fa7bbe26b26bc7ce6dcb5fdf98220f94358ce8e8f3b12985adc4`；104 个文件等于 tag 源码和预验内容 |

LuaCov 的 `footnote_marker_scan_spec.lua`、`footnotes_perf_spec.lua` 有既有 instrumentation-only advisory；
阻断的完整普通 UT 已先通过，未为本报告降低门槛。未来每模块目标中 `plugin_util.lua` 55.9% 尚未达标，须继续补齐。
本次 release 使用的 fork 是 `8e9a159e16f39541a9c3c406e548f5cac65e1bc3`，不是之后发布的 KOReader `ab190e63`。

额外预验在精确 main `a2c7697c`、官方 v2026.07.1、精确 stable `aef4bb9d` 运行时各过 29 个非预算场景，
预算 200 章由完整 Release 强制执行。实际旧 1.6.90/1.6.91 ZIP 在三套运行时升级到实际 1.6.92 成功，
目标 104 文件和完整旧 97/101 备份均核对；最终重包后又做两旧版本升级及真新进程重启。
重启保留已有设置、正常激活并清理旧备份、同版本不再触发下载。该 profile 没有缓存 WeRead EPUB，不能声称完成该恢复子项。

这些额外自动化是 Linux SDL headless 验证，不是 macOS 全部人工清单或 Kindle 硬件实测。
复杂选择、checkpoint 损坏恢复、全部字体/旋转/插件组合与旧用户数据迁移矩阵等人工子项未全部覆盖。

## CI/CD 策略

[#65](https://github.com/qvictl/weread.koplugin/pull/65)、[#66](https://github.com/qvictl/weread.koplugin/pull/66)、
[#68](https://github.com/qvictl/weread.koplugin/pull/68) 已合入：

- 普通 PR/main 按完整改动范围与两版依赖图选择整个业务 UT 文件；动态/未知依赖保守处理，框架、共享 fixture 等必要时 full，文档可 none。
- ci/tests-policy 保留工具自检、lint、包结构、敏感信息检查和改动行 unit ≥80%；部分结果的整体覆盖率是未测，不写全局 baseline/徽章。
- 普通合代码不运行真实 IT，也不在后台再做一次全量 coverage。版本发布才执行完整普通 UT、全量 LuaCov、fork/官方/PluginLoader 真实 IT。
- 发布保留整批 diff90、独立全局 unit/combined 棘轮、日期/模块目标和 0.1 个百分点容忍，读取历史失败不能当作首次测量绕过。
- 原受保护 main、当前 head AI review、review thread 和自动 gate 保留，没有新增人工审批。

本报告只改文档，不改变版本号或再次发布。细则见 [CONTRIBUTING](../../CONTRIBUTING.md)、
[测试说明](../testing.md) 和 [发布说明](../releasing.md)。

## 设备状态及未闭环事项

截至最后一次授权 USB 安装记录，Oasis 3 已装入此前完整 KOReader HF `938e5d52` 与插件 **1.6.91**，保存完整原目录备份，
核验 1155 个程序文件和 18 个原配置后安全卸载。刚发布的插件 **1.6.92 未重新装入该设备**。

原 811 章整机冻结/OOM/COW 的真机因果、长书压力、取消/重开与休眠恢复验收仍未闭环。
进程串行预算和状态减量是已交付缓解，不能替代硬件复测。
批注 DB 每操作开销、checkpoint 增量化等性能建议也未全部实施；后续先以可复现热点、语义一致和前后指标决定改动。
上游 PR 的接收与否由 maintainer 决定，不因本 fork 修复就制造“所有上游问题已关闭”的结论。
