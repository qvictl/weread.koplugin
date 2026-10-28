# 单元测试覆盖率提升计划

本文档是 [`.ci/coverage-policy.json`](../.ci/coverage-policy.json) 的路线图：说明怎样复现 CI 的单元覆盖率、
按什么顺序补测试、每个阶段要达到的数字。门禁规则见 [CONTRIBUTING.md](../CONTRIBUTING.md#coverage-policy--覆盖率策略)。

## 1. 基线与测量方法

首日基线（2026-10-27，`main@3daba0c`）：单元 **73.80%**（14842/20110 行，85 个文件），单元 + 模拟器 **80.78%**。

本地复现（与 CI `tests-policy` 完全一致：LuaCov v0.16.0、`luajit -joff`、每个 spec 单独统计后合并、
未被任何 spec 加载的插件文件按 0% 计入）：

```bash
git clone --depth 1 --branch v0.16.0 https://github.com/lunarmodules/luacov.git /tmp/luacov
LUA_PATH="/tmp/luacov/src/?.lua;;" bash scripts/run_lua_coverage.sh      # -> coverage/unit.report.out
python3 scripts/coverage_tools.py total coverage/unit.report.out         # 73.80% (14842/20110)
```

`content_base64_spec`、`footnote_marker_scan_spec`、`footnotes_perf_spec` 在覆盖率模式（JIT 关闭 + 行钩子）下
会因内存或计时预算失败，脚本只记录它们失败前的命中行（advisory），普通 spec 任务仍完整执行它们。

## 2. 里程碑

| 生效日期 | 单元（整体） | 单元 + 模拟器（整体） | 每个 `weread/lib/*` 文件单元 |
| --- | --- | --- | --- |
| 2026-10-27（基线） | 73.80% | 80.78% | 8 个文件 < 70% |
| 2026-11-24 | ≥ 80% | ≥ max(75%, 80.78%) | — |
| 2026-12-22 | ≥ 88% | ≥ 85% | ≥ 70% |

三项都写在 `.ci/coverage-policy.json` 的 `targets`（`unit_min`、`combined_min`、`module_unit_min`）里：
生效日前只在 PR 报告中显示，生效日起成为阻塞项。按 20110 行可执行代码估算，80% 需要再覆盖约 1250 行，
88% 约 2860 行。另外每个 PR 仍需满足改动行单元 ≥ 80%、合计 ≥ 90%，整体覆盖率不得下降（ratchet）。

## 3. 优先级

分数 = 未覆盖行数 × 风险。风险 3：联网、下载、同步或插件/阅读器生命周期主路径；风险 2：持久化
（数据库、设置、缓存删除），或曾在设备卡顿时运行在 UI 线程上的代码；风险 1：纯渲染或无副作用的辅助函数。
同分时先做覆盖率更低的文件。

| # | 文件 | 单元覆盖率 | 未覆盖行 | 风险 | 分数 | 风险说明 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `weread/lib/content.lua` | 51.3% (816/1591) | 775 | 3 | 2325 | 下载/解析/打包 |
| 2 | `weread/lib/read_report.lua` | 72.0% (774/1075) | 301 | 3 | 903 | 同步/生命周期，曾在 UI 线程卡顿 |
| 3 | `weread/ui/library.lua` | 60.6% (693/1143) | 450 | 2 | 900 | 书架加载，断网曾卡死 |
| 4 | `weread/ui/menu.lua` | 49.4% (305/617) | 312 | 2 | 624 | 菜单回调触发同步/下载 |
| 5 | `weread/lib/qr_login.lua` | 57.7% (265/459) | 194 | 3 | 582 | 网络/凭据持久化 |
| 6 | `weread/lib/downloader.lua` | 83.5% (969/1160) | 191 | 3 | 573 | 下载/断点续传 |
| 7 | `weread/ui/cache.lua` | 50.6% (291/575) | 284 | 2 | 568 | 删除缓存/UI 线程 |
| 8 | `weread/lib/client.lua` | 72.6% (414/570) | 156 | 3 | 468 | 网络/超时 |
| 9 | `weread/ui/annotations_controller.lua` | 45.0% (166/369) | 203 | 2 | 406 | 划线 UI 线程 |
| 10 | `weread/lib/reader_lifecycle.lua` | 60.5% (185/306) | 121 | 3 | 363 | 生命周期，开关书/休眠 |
| 11 | `weread/lib/progress_sync.lua` | 88.3% (849/961) | 112 | 3 | 336 | 进度同步 |
| 12 | `weread/ui/read_stats_view.lua` | 0.0% (0/328) | 328 | 1 | 328 | 渲染/纯 UI |
| 13 | `weread/ui/common.lua` | 35.9% (56/156) | 100 | 3 | 300 | UI 线程网络任务 |
| 14 | `weread/lib/updater.lua` | 74.6% (259/347) | 88 | 3 | 264 | 下载/安装/回滚 |
| 15 | `weread/ui/updater.lua` | 50.2% (120/239) | 119 | 2 | 238 | 更新安装 UI |
| 16 | `weread/lib/read_stats.lua` | 0.0% (0/116) | 116 | 2 | 232 | 网络 |
| 17 | `weread/lib/thought_db.lua` | 0.0% (0/108) | 108 | 2 | 216 | 持久化 |
| 18 | `main.lua` | 61.5% (96/156) | 60 | 3 | 180 | 插件生命周期/事件 |
| 19 | `weread/lib/background_worker.lua` | 78.1% (189/242) | 53 | 3 | 159 | 后台子进程/超时 |
| 20 | `weread/ui/thought_popup/face_factory.lua` | 0.0% (0/138) | 138 | 1 | 138 | 渲染/纯 UI |
| 21 | `weread/ui/annotation_sync_controller.lua` | 91.6% (697/761) | 64 | 2 | 128 | 同步/UI 线程 |
| 22 | `weread/ui/library_view.lua` | 88.7% (732/825) | 93 | 1 | 93 | 渲染/纯 UI |
| 23 | `weread/lib/thoughts.lua` | 36.8% (25/68) | 43 | 2 | 86 | 网络 |
| 24 | `weread/ui/thought_popup/center_widget.lua` | 71.7% (213/297) | 84 | 1 | 84 | 渲染/纯 UI |
| 25 | `weread/lib/protocol.lua` | 78.0% (145/186) | 41 | 2 | 82 | 网络协议 |
| 26 | `weread/ui/read_report.lua` | 77.6% (135/174) | 39 | 2 | 78 | 上报状态 UI |
| 27 | `weread/ui/thought_popup/scroll_container.lua` | 46.2% (66/143) | 77 | 1 | 77 | 渲染/纯 UI |
| 28 | `weread/lib/external_annotations_db.lua` | 88.2% (277/314) | 37 | 2 | 74 | 持久化 |
| 29 | `weread/ui/thought_popup/widget.lua` | 67.5% (131/194) | 63 | 1 | 63 | 渲染/纯 UI |
| 30 | `weread/ui/book_detail_view.lua` | 77.0% (184/239) | 55 | 1 | 55 | 渲染/纯 UI |
| 31 | `weread/lib/annotations.lua` | 89.1% (213/239) | 26 | 2 | 52 | 网络 |
| 32 | `weread/lib/external_annotations.lua` | 93.6% (350/374) | 24 | 2 | 48 | 持久化 |
| 33 | `weread/lib/library_db.lua` | 90.3% (223/247) | 24 | 2 | 48 | 持久化 |
| 34 | `weread/ui/xpointer_overlay_controller.lua` | 68.7% (103/150) | 47 | 1 | 47 | 渲染/纯 UI |
| 35 | `weread/lib/book_reviews.lua` | 83.2% (94/113) | 19 | 2 | 38 | 网络 |
| 36 | `weread/ui/download_dialog.lua` | 81.7% (85/104) | 19 | 2 | 38 | 下载 UI |
| 37 | `weread/ui/progress_sync_dialog.lua` | 78.6% (66/84) | 18 | 2 | 36 | 同步 UI |
| 38 | `weread/lib/reader_state.lua` | 50.0% (15/30) | 15 | 2 | 30 | 阅读器状态 |
| 39 | `weread/ui/book_reviews_view.lua` | 79.5% (116/146) | 30 | 1 | 30 | 渲染/纯 UI |
| 40 | `weread/lib/cover_cache.lua` | 90.2% (119/132) | 13 | 2 | 26 | 磁盘缓存 |
| 41 | `weread/lib/book_store.lua` | 93.9% (184/196) | 12 | 2 | 24 | 持久化 |
| 42 | `weread/lib/plugin_util.lua` | 47.4% (18/38) | 20 | 1 | 20 | 渲染/纯 UI |
| 43 | `weread/ui/reader_navigation.lua` | 70.1% (47/67) | 20 | 1 | 20 | 渲染/纯 UI |

其余 28 个文件合计 176 行未覆盖（单个文件 ≤ 14 行，覆盖率大多 ≥ 90%），另有 15 个文件已 100%。

## 4. 批次

**第 1 批（2026-10-27 起，目标单元 ≥ 80%）**：高风险、低覆盖模块，一个模块或主题一个 PR。

- `content.lua`：下载工作区与断点、EPUB 打包；分片解码、图片/资源下载、CSS、公众号文章。
- `client.lua` / `cookie.lua` / `protocol.lua`：HTTP 错误、超时、重定向与 Cookie 边界、部分下载清理。
- `read_report.lua`：上报/跳过决策、休眠与恢复时的定时器、失败重试、待上报时长持久化。
- `qr_login.lua`、`lib/updater.lua`：登录轮询状态机与凭据只在成功时保存；版本比较、校验和、安装备份与回滚。
- `downloader.lua` 边缘路径、`background_worker.lua`：取消、断网与服务端错误的区分、子进程超时。
- `reader_lifecycle.lua`、`progress_sync.lua`：开关书/休眠时的调度，进度上传/下载/冲突决策。
- `read_stats.lua`、`thought_db.lua`、`thoughts.lua`、`library_db.lua`：持久化与重开后的数据完整性。
- `ui/cache.lua`、`ui/common.lua`：只删除插件缓存目录、下载中拒绝操作、UI 线程网络任务。

**第 2 批（至 2026-11-24）**：`ui/library.lua`、`ui/menu.lua`、`ui/annotations_controller.lua`、`ui/updater.lua`、
`main.lua`、`ui/annotation_sync_controller.lua` 的剩余分支，以及第 1 批未达 70% 的 `weread/lib/*` 文件。

**第 3 批（至 2026-12-22，目标单元 ≥ 88%）**：渲染层 `ui/read_stats_view.lua`、`ui/thought_popup/*`、
`ui/library_view.lua`、`ui/book_detail_view.lua`、`ui/xpointer_overlay_controller.lua`，并把所有
`weread/lib/*` 文件提升到 ≥ 70%。

## 5. 写法约定

- 纯 LuaJIT spec（`spec/*_spec.lua`），用 `package.preload` 替身隔离 KOReader、网络和时间；不访问网络、不真实 sleep，
  在 `-joff` + 行钩子下也要快且省内存。
- 断言行为而不是"执行到某行"：请求内容、写入的文件、状态变化、回调、错误结果、重试与取消、空输入和畸形输入。
- 错误信息只做子串匹配，不固定 Lua 源码位置前缀。
- 写测试时发现的真实缺陷：先写一个在修复前失败的回归测试，再用独立的小 PR（修复 + 测试）提交，不混进测试 PR。
- 只有确实无法注入依赖时才做最小的可测性重构，并单独提 PR。
