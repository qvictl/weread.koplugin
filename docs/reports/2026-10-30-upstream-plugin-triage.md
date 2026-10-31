# 插件上游问题调研与二维码显示修复（2026-10-30）

快照来源：`finlater/weread.koplugin`，开放条目快照时间为2026-10-30 03:24:37 UTC；本fork条目核查基线为`a88722251de308fe802a41503c58c1fcae0950d9`。二维码首版实现/回归对应`8866be78738538f1582777c0aaad71cde1f4baaf`；显示前取消修复对应`013ec1d9cbcbcbf51426f61cff05a7d570d20747`；最高密度小屏空码修复及首轮回归记录对应`185581df08045936a35413d24de7352e4eabfa7b`，当前场景兼容性结论以本次验证表及源码资格为准，见下文。

## 范围和结论

完整分页读取了28个开放issue、25个开放PR，closed PR元数据共81条（该集合不足一页，完整读取）；额外读取有评论的开放issue及重点PR的24个评论端点。元数据完整不等于每个问题已复现；下表明确区分已有修复、功能请求和证据不足。

所有上游访问只读，未评论、反应、打标签、评审、推送或关闭上游条目。我们自己的PR正文、评论及commit message也不引用上游条目，以避免自动cross-reference通知；来源链接只保存在本文件。

## 选定修复与证据

来源：[c4po 的二维码显示提案](https://github.com/finlater/weread.koplugin/pull/225)。上述核查基线仍使用QRMessage的版本相关布局，先指定屏幕短边72%，再对QRWidget已经按整数模块编码的位图做0.9倍缩放。官方v2026.07.1的真实回归中，377px编码图被重采样为339px；新增回归在旧代码失败。

只扩大现有框并取消二次缩放的试验能得到551px，但固定框padding不足以保证quiet zone，因此没有采用该试验版本。按[DENSO WAVE的要求](https://www.qrcode.com/en/howto/code.html)，四边至少应有四模块空白。最终复用原QRWidget、FrameContainer和InputContainer组合一个小型登录容器：保留整数像素，依据最小21模块符号保守留出四模块白边，并为ceil舍入预留2px。登录URL不能被截断或拆成多码；过长/无法绘制的payload显示可关闭错误；显示前取消也通过公开getSize绑定处置路径，原生位图只释放一次，dismiss callback至多一次（框架的free方法可以幂等重复调用）；保留Back和F5全刷新及物理键盘连接注册。

未修改任何登录URL、认证参数、401行为、长轮询或请求重试；也未删除原先的登录提示。首次显示请求full refresh，但SDL只能证明调用/绘制路径，不能作为Kindle扫码成功或残影改善的硬件证明。

| 验证 | 结果 |
| --- | --- |
| QR布局单测 | 123 checks，含600×800、800×600、320×240、240×320；21/29/177模块、失败/过长payload、关闭和释放 |
| QRLogin与流程组件 | 69 + 241 checks通过；保留会话、取消、OTP、异常及owner行为 |
| 修前真实负例 | 官方QRWidget原始377px→渲染339px，整数像素保持检查失败 |
| 本次真实场景02 | fork a2c 240×320、官方071 240×320、fork a2c 600×800，3组均10步骤通过；分别覆盖最高密度图为nil、0×0、354px的真实路径 |
| 静态检查 | 变更Lua的luacheck、命名空间与git diff --check通过 |

真实场景直接核对QRWidget原始与绘制位图尺寸、模块整数像素、四边相对Frame边界的至少四模块白边和视口边界。流程继续验证扫码完成、错误OTP后恢复、过期不落凭据、userInfo掉线原有重试，以及实际触摸关闭取消进程、过长payload错误关闭、2953字节最高密度码的边界和未显示时重复关闭后的原生allocated标志1→0。合成服务与UID不涉及真实账号或私人内容。

首轮历史记录曾汇总六组官方/fork竖横屏及小屏结果；本轮没有重建各组当时的完整运行时资格，不以该旧汇总证明当前场景兼容性，也不猜测旧通过记录与本轮nil负例的差异原因。当前结论仅依据以下三组新场景结果：

| 真实运行时 | 实际视口 | 普通登录图：原生/绘制、模块/白边 | 2953字节密集图 |
| --- | --- | --- | --- |
| fork a2c7697 | 240×320 | 145/145px、5/28px | `image=nil`，可关闭错误 |
| 官方 v2026.07.1 | 240×320 | 145/145px、5/28px | 0×0 image，可关闭错误并释放 |
| fork a2c7697 | 600×800 | 406/406px、14/78px | 354px，必须生成正尺寸图且适屏 |

实际视口由场景的Screen指标、启动framebuffer日志及绘制截图尺寸交叉核对。小屏场景接受nil或零尺寸，只有图像存在时才检查原生释放；屏幕短边至少600px时仍强制最高密度图像存在且宽高为正，避免生成失败被错误提示掩盖。正常关闭的有效原生缓冲释放一次，框架幂等free允许重复调用，未显示时关闭也立即释放。

两种独立负例均已保留：旧强制图像存在的场景在真实fork 240×320下准确失败；放宽后的2349e3e场景在纯Lua模拟的大屏编码失败中错误通过，补回大屏断言后准确拒绝。该模拟负例不涉及原生故障。生产QRDialog保持185581d的内容，未修改认证或重试逻辑；123+69+241项目标检查与Lua lint通过。

本次场景源码SHA-256：`094f29005c62e5ff98b677c7971a4d831cb160258f63d5182581a28c0f3c7d6d`。复用fork模拟器为原a2c7697构建，QRWidget文件与该Git提交逐字节一致，其SHA-256为`85d67fcd0787d5e23c60da65c2dedffcf9d1afa7b40ab624c7ffa8a4e170279c`；官方071对应文件SHA-256为`bd2be7609720604e387b792dd42c5f2c98816752bea1a913f75e889ec945b890`。这不是新core主线的原生构建或Kindle/手机扫码验收。

对[资源包失败提案](https://github.com/finlater/weread.koplugin/pull/226)，不能只看Content中单次GET就断言本fork缺少重试。现有Downloader已将source+images放在同一worker，失败经过0.8/1.6秒合作调度共3次；针对合成499/429的实际Downloader调用链10项检查确认该路径恢复且保留图片。499本身不等于已证明服务端限流；不叠加内部重试，不采纳最终失败后丢图却宣称完整成功的策略。

## 合成UI对照

真实官方v2026.07.1模拟器，600×800：旧图339px且被二次采样；新图406px、整数模块并保留已测四模块白边。这里只是合成服务截图，不是真机扫码验收。

| 修前 | 修后 |
| --- | --- |
| ![旧QR显示](images/2026-10-30-qr-before.png) | ![修正QR与白边](images/2026-10-30-qr-after.png) |

## 开放issue逐项处理判断

| 来源 | 当前判断 | 本fork处理依据/后续 |
| --- | --- | --- |
| [214](https://github.com/finlater/weread.koplugin/issues/214) [Bug] 扫码登录失败：getLoginInfo 返回 401（-2013 鉴权失败），疑似 /r/weread-skills 不再下发 Cookie | 未证实/协议 | 仅UI QR候选不改变401行为；真实登录服务变化需独立协议验证，不用匿名401猜修复 |
| [211](https://github.com/finlater/weread.koplugin/issues/211) [Question] 阅读时长整段未上报，且没有任何提示 | fork已有修复 | progress_sync默认report gate及pull失败重试已有源/UT；真实服务端计时仍待硬件验收 |
| [209](https://github.com/finlater/weread.koplugin/issues/209) [Bug] 截图失效bug | 待复现 | 想法弹窗截图手势冲突需真实全局gesture链，当前未确证 |
| [205](https://github.com/finlater/weread.koplugin/issues/205) [Bug] 菜单上清理划线和想法后，设备上的空间没有释放 | fork已有修复 | annotation_store.clearKinds已VACUUM+checkpoint，已有实际文件大小/保留kind回归 |
| [204](https://github.com/finlater/weread.koplugin/issues/204) [Feature] 阅读时间上报的间隔希望可以调整，以减少联网耗电 | fork已有功能 | read_report UI已有30/60秒等间隔预设与picker回归 |
| [198](https://github.com/finlater/weread.koplugin/issues/198) [Feature] 本地书籍阅读时长上报时实现自动切换至关联的微信读书书目 | 功能请求 | 关联本地书自动切换目标需独立交互/映射验收 |
| [135](https://github.com/finlater/weread.koplugin/issues/135) [Bug] kindle3 按键kindle，想法怎么看 | 硬件/功能候选 | 评论含Kindle3分支及用户反馈，原生键盘导航/本页想法快捷键未作硬件验收 |
| [125](https://github.com/finlater/weread.koplugin/issues/125) [Feature] 在线阅读 / 按需加载章节，减少整本或章节预下载 | 功能请求 | 现有章节预取/导航覆盖部分能力，不等于完整在线阅读产品设计 |
| [62](https://github.com/finlater/weread.koplugin/issues/62) [Bug] 公众号文章无法阅读 报错凭证过期解决办法：在手机微信读书 app 里 设置--登录设备 把已登录设备全部清理掉 然后重新扫码登录 | 待复现/服务端 | 公众号凭据拒绝涉及账号/服务状态，当前不访问真实账号、不猜参数 |
| [171](https://github.com/finlater/weread.koplugin/issues/171) 下载书没有简介页和每章的标题 | 部分覆盖/待样本 | 已有intro metadata，章节标题/原书转换现象仍需可合法使用样本 |
| [184](https://github.com/finlater/weread.koplugin/issues/184) [Bug] 下载书籍存在空格问题 | 待样本 | 特定导入EPUB字间空格无可复现fixture，不猜排版修复 |
| [180](https://github.com/finlater/weread.koplugin/issues/180) [Bug] 通过微信读书API应该可以获得自己的划线评论 | 功能请求 | 私有划线评论获取需协议证据和隐私边界 |
| [173](https://github.com/finlater/weread.koplugin/issues/173) [Feature] 新增手动上报阅读时间及同步阅读进度按钮 | fork已有功能 | 手动阅读时长/进度入口已有，真实服务端计时效果非本次验收 |
| [148](https://github.com/finlater/weread.koplugin/issues/148) [Feature] 将高亮和评论上传到云端的微信读书中。 | 功能请求 | 双向上传批注未实施，不能当本地匹配bug |
| [163](https://github.com/finlater/weread.koplugin/issues/163) 增加个性化推荐书籍功能 | 功能请求 | 个性化推荐无确认缺陷 |
| [155](https://github.com/finlater/weread.koplugin/issues/155) [Bug] 同步阅读进度失败，无法确定当天位置 | 部分覆盖/待复现 | 精确进度/手动恢复已增强，原Colorsoft样本未验收 |
| [154](https://github.com/finlater/weread.koplugin/issues/154) [Bug] 大量注释的文章存在很多空白页 | 待样本 | 密集脚注空白页需原文与分页fixture，已有线性脚注并非该现象因果证明 |
| [126](https://github.com/finlater/weread.koplugin/issues/126) [Feature] 可否将标注的想法同步到微信读书功能 | 功能请求 | 想法双向上传未实施 |
| [104](https://github.com/finlater/weread.koplugin/issues/104) [Feature] 能否支持查看想法评论 | 功能请求 | 想法的评论展示需独立UI/API契约 |
| [147](https://github.com/finlater/weread.koplugin/issues/147) [Feature] 同步过来的划线想法下划线样式能否自主调整 | 功能请求 | 下划线样式定制需明确配置需求 |
| [149](https://github.com/finlater/weread.koplugin/issues/149) [Feature] 书籍详情 阅读 按钮行为不明确 | 交互请求 | 阅读按钮选择与上次章节语义需产品定义，非已证崩溃 |
| [134](https://github.com/finlater/weread.koplugin/issues/134) [Bug] 本地书匹配想法时，下载想法频繁提示请求频率超限 | 部分缓解/待复现 | 已有错误分类/暂停续跑；账户限流样本不以资源包499等价代替 |
| [97](https://github.com/finlater/weread.koplugin/issues/97) [Bug] koreader 重启会和weread插件cache冲突导致koreader无法启动 | 部分缓解/待复现 | 已有原子EPUB/workspace隔离；旧启动崩溃缺稳定复现，不宣称原因闭环 |
| [38](https://github.com/finlater/weread.koplugin/issues/38) [Bug] 书籍每章节标题消失 | 待样本 | 转换书章节标题/图片差异需要合法源和转换输入 |
| [102](https://github.com/finlater/weread.koplugin/issues/102) [Feature] 微信阅读翻译失效 | 功能/协议候选 | 内联翻译PR为行为/API选择，未经协议验证不直接合入 |
| [71](https://github.com/finlater/weread.koplugin/issues/71) 欢迎贡献！无论是功能实现、性能优化、UI设计、还是想法点子！问题反馈和功能需求请按模板提交，自由讨论可移步Discussion区！ | 社区说明 | 不是缺陷 |
| [60](https://github.com/finlater/weread.koplugin/issues/60) [Feature] 书签/笔记展示 | 功能请求 | 书签/笔记展示未作为本轮修复 |
| [56](https://github.com/finlater/weread.koplugin/issues/56) [Bug] 微信公众号部分文章下载失败 | 待样本/协议 | 特定公众号大响应正文提取失败需可公开复现fixture |

## 开放PR逐项处理判断

| 来源 | 当前判断 | 本fork处理依据/后续 |
| --- | --- | --- |
| [223](https://github.com/finlater/weread.koplugin/pull/223) fix(library): keep bookshelf, chapter list and cache screens responsive and in place | 本fork既有实现/自有上游PR，不动原分支 | 按当前fork生产代码和已交付回归去重；不对上游发完成通知 |
| [226](https://github.com/finlater/weread.koplugin/pull/226) fix(download): survive resource package rate limiting | 已有协作重试缓解，不整包采纳 | 实际Downloader source+images worker catch路径对合成499/429已3次重试/0.8,1.6；不采用失败丢图假成功或多层重试叠乘 |
| [225](https://github.com/finlater/weread.koplugin/pull/225) fix: display the login QR code correctly | 选定：QR显示与四模块白边修复 | 独立最小QR容器保留整数模块及保守四模块白边，触摸/Back关闭与释放恰一次；不采纳401重试或删除提示。原339px样本修正为406px，最终native回归结果见下。 |
| [224](https://github.com/finlater/weread.koplugin/pull/224) fix(progress-sync): no network on suspend or close, never move cloud progress back | 本fork既有实现/自有上游PR，不动原分支 | 按当前fork生产代码和已交付回归去重；不对上游发完成通知 |
| [222](https://github.com/finlater/weread.koplugin/pull/222) fix(annotations): keep annotation work off the UI thread and survive a busy database | 本fork既有实现/自有上游PR，不动原分支 | 按当前fork生产代码和已交付回归去重；不对上游发完成通知 |
| [221](https://github.com/finlater/weread.koplugin/pull/221) fix(runtime): share services per process and make book records durable | 本fork既有实现/自有上游PR，不动原分支 | 按当前fork生产代码和已交付回归去重；不对上游发完成通知 |
| [220](https://github.com/finlater/weread.koplugin/pull/220) fix(updater): hash the package in chunks and keep the backup until restart | 本fork既有实现/自有上游PR，不动原分支 | 按当前fork生产代码和已交付回归去重；不对上游发完成通知 |
| [219](https://github.com/finlater/weread.koplugin/pull/219) fix(download): make EPUB image names unique, FAT-safe and href-safe | 本fork既有实现/自有上游PR，不动原分支 | 按当前fork生产代码和已交付回归去重；不对上游发完成通知 |
| [218](https://github.com/finlater/weread.koplugin/pull/218) fix(standby_guard): pause KOReader AutoSuspend during long jobs on Kindle | 本fork既有实现/自有上游PR，不动原分支 | 按当前fork生产代码和已交付回归去重；不对上游发完成通知 |
| [217](https://github.com/finlater/weread.koplugin/pull/217) fix(download): pause on network loss, bound request timeouts, never wedge a job | 本fork既有实现/自有上游PR，不动原分支 | 按当前fork生产代码和已交付回归去重；不对上游发完成通知 |
| [216](https://github.com/finlater/weread.koplugin/pull/216) fix(download): stop full-book downloads from exhausting memory on e-readers | 本fork既有实现/自有上游PR，不动原分支 | 按当前fork生产代码和已交付回归去重；不对上游发完成通知 |
| [215](https://github.com/finlater/weread.koplugin/pull/215) perf(footnotes): make chapter scanning linear | 本fork既有实现/自有上游PR，不动原分支 | 按当前fork生产代码和已交付回归去重；不对上游发完成通知 |
| [202](https://github.com/finlater/weread.koplugin/pull/202) fix: credit reading time for the open book and send real progress uploads | 相关路径fork已覆盖 | read_report_progress含真实progress POST/enter拒绝回归，非真实服务器时长验收 |
| [213](https://github.com/finlater/weread.koplugin/pull/213) fix(progress-sync): stop the report gate from dropping reading time | 本fork既有实现/自有上游PR，不动原分支 | 按当前fork生产代码和已交付回归去重；不对上游发完成通知 |
| [208](https://github.com/finlater/weread.koplugin/pull/208) fix: reclaim disk space after clearing underlines and thoughts | 相关路径fork已覆盖 | clearKinds已有VACUUM和文件大小回归 |
| [207](https://github.com/finlater/weread.koplugin/pull/207) refactor(settings): read and write book records per book | 相关路径fork已覆盖 | Settings已有按书get/put和Runtime使用 |
| [206](https://github.com/finlater/weread.koplugin/pull/206) perf(book_store): skip unchanged writes and per-book mkdir shell spawns | 相关路径fork已覆盖 | book_store已有未变写入跳过/避免每次mkdir |
| [203](https://github.com/finlater/weread.koplugin/pull/203) fix: compare precise chapter progress and preserve manual recovery | 相关路径fork已覆盖 | 精确chapter进度/手动冲突恢复已有相关组件测试 |
| [199](https://github.com/finlater/weread.koplugin/pull/199) feat: 移植「本页想法」到 1.6.0，并兼容匹配本地书（unified） | 不整包采纳/后续候选 | 有部分能力已优化；旧基线/默认策略/新功能或并发资源代价尚未证明行为等价，不把PR标题当现fork确定bug |
| [168](https://github.com/finlater/weread.koplugin/pull/168) 严重 Bug 修复：高密度划线和想法完整落盘（基于 v1.5.2） | 不整包采纳/后续候选 | 有部分能力已优化；旧基线/默认策略/新功能或并发资源代价尚未证明行为等价，不把PR标题当现fork确定bug |
| [170](https://github.com/finlater/weread.koplugin/pull/170) 性能优化：降低批注覆盖层与翻页路径开销（基于 v1.5.2） | 不整包采纳/后续候选 | 有部分能力已优化；旧基线/默认策略/新功能或并发资源代价尚未证明行为等价，不把PR标题当现fork确定bug |
| [131](https://github.com/finlater/weread.koplugin/pull/131) feat: tag downloaded books with weread for ZenOS/SimpleUI/Bookshelf | 不整包采纳/后续候选 | 有部分能力已优化；旧基线/默认策略/新功能或并发资源代价尚未证明行为等价，不把PR标题当现fork确定bug |
| [123](https://github.com/finlater/weread.koplugin/pull/123) feat:keep WeRead's inline translation | 不整包采纳/后续候选 | 有部分能力已优化；旧基线/默认策略/新功能或并发资源代价尚未证明行为等价，不把PR标题当现fork确定bug |
| [114](https://github.com/finlater/weread.koplugin/pull/114) feat: add bounded concurrent downloads | 不整包采纳/后续候选 | 有部分能力已优化；旧基线/默认策略/新功能或并发资源代价尚未证明行为等价，不把PR标题当现fork确定bug |
| [122](https://github.com/finlater/weread.koplugin/pull/122) feat: load thoughts on demand when tapping underlines | 不整包采纳/后续候选 | 有部分能力已优化；旧基线/默认策略/新功能或并发资源代价尚未证明行为等价，不把PR标题当现fork确定bug |

开放条目可能在上游继续变化。这里不将issue数量当作bug数量，也不因本fork已有相同修复而关闭或打扰上游。用户随后已确认原811章整机卡死问题闭环；全部真实服务端计时不属于本轮验收。

## 后续筛选：畸形想法记录的断点恢复

再次核查以本fork `4afb5d3` 为基线，开放PR没有新增；本fork当时没有开放PR。
从[高密度批注提案](https://github.com/finlater/weread.koplugin/pull/168)中独立选取
畸形记录容错问题，而不是移植其旧基线上的缓存迁移、匹配预算或同步策略。

当前流程先把原始想法批次写入SQLite并推进`next_batch`，随后才提取摘要、生成弹窗记录。
若`pageReviews`中的元素、`review`或`author`为标量，原来的直接索引会抛错；
顶层range记录为标量也会在最终写入前抛错。已经保存的批次会在续跑时再次遇到同一异常。

本次最小实现跳过无法使用的嵌套记录、保留有效相邻想法和首条有效摘要，
畸形作者回退匿名，并仅持久化具有非空字符串range的想法。
摘要查找保留原文优先和旧式直接摘要格式，跳过畸形条目后寻找可用摘要。
不改变网络请求、账号、缓存格式或同步范围。

回归包含独立payload形状规格、真实SQLite已保存坏批次的离线续跑与重新打开，
以及模拟器场景`09_annotations_thoughts.lua`中的真实存储恢复步骤。
这些新增回归的执行结果以对应PR的最新CI及实际模拟器运行记录为准；
新增场景本身不构成已执行或真机验收的证据。
