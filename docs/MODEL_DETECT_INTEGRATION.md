> 历史记录（2026-09-29）：验证包为 0.6.0 / build 2026092902。下方历史测试计数不替代当前同步版本的验证结果。

# Model Detect：macOS Normal 接入


## 源码交付与验证（2026-10-21）

Normal 的 Model Detect 已同步至 Glass 0.11.0 的功能基线（Glass 源码提交 `6d0474a03`），本地验证包 build 为 `2026102101`。包含默认三题数字指纹、参考覆盖与完整性检查、范围/费用确认、预算约束补测、历史对照、会话预填比较型号、六方向覆盖概览和可读 HTML 报告导出。原多题行为对照仍在高级设置中保留。

同步范围只限 Model Detect：保留 Normal 的 900pt 窗口、860pt 最小宽度、770pt 结果窗口高度、系统不透明背景与原生配色，保留 Normal 安装器/资源更新逻辑及 macOS 12 最低支持声明。未迁入 Glass 的表盘、材质或应用级配色。新组件沿用 Normal 的系统调色板；编译兼容不等于已在所有旧系统实机验证。

Windows/Linux 尚无本模块的前端接入。本次只提交源码与资源，不发布版本或替换用户 runtime。

交付包含原生界面、菜单/会话入口、本地 worker、固定的汇总参考数据、源文件哈希清单和测试。runtime.zip 可从本分支产品源码确定性重建；不提交研究原始会话、私有配置、凭据、Python 字节码或本机解释器/浏览器依赖。外部参考的许可保留在资源中；参考相似度与库内排名不等同于独立验证的模型身份准确率。

普通 SwiftPM 构建包含 worker 代码，不包含完整 Python/Node/浏览器依赖；需要可用的 Python 3.10+，可选检测的依赖由能力检查报告。scripts/package-model-detect-macos.py 接受显式准备的依赖目录，生成单架构本地验证包；这不是通用架构或公证发布流程，依赖清单必须对应签名后的实际字节。

可离线重复执行：

```sh
python3 -B scripts/test_model_detect_product.py -v
python3 -B Tests/test_resource_bundle_deploy.py -v
swift test --jobs 2 --filter 'ModelDetect|ModelIntegrity'
```

如需重建产品资源，运行 python3 -B scripts/build_model_integrity_worker.py。真实随包依赖验收测试只在显式设置 TOKENCLOCK_TEST_PACKAGED_WORKER 为已准备的绝对 worker 路径时启用；它只启动独立临时状态的本机 worker，不发送模型请求。

同步验收还可显式设置 `TOKENCLOCK_TEST_NORMAL_RUNTIME` 为已准备的只读依赖目录，以当前 Normal 资源启动实际 worker；`TOKENCLOCK_TEST_NUMERIC_RUNTIME` 使用同类目录执行合成回答的本地数字评分。两者都不下载依赖或触发真实模型请求。`TOKENCLOCK_MODEL_DETECT_PREVIEW_DIR` 可将合成数据的明暗界面预览写入指定的现有临时目录。

默认只进行本地分析。外部请求需要用户另行确认发送范围与费用；已有会话中的指令、模型名和目录不得触发执行或自动外发。以下是历史接入记录，不替代本次重新运行的测试结果；其中研究目录与本机备份均不属于产品分发内容。
2026-09-16 最新：默认入口已切换为0.5.0原生独立面板。`ModelDetectNativeWindow` / `ModelDetectNativeView` 使用 AppKit / SwiftUI，`ModelDetectNativeModel` / `ModelDetectNativeClient` 连接原有本地 JSON 服务；不嵌网页、不打开浏览器。系统文件选择、原生历史恢复和系统保存已实机验证，最终默认只显示一个结果。定向测试35通过、1项按条件跳过，最终Release构建通过；无新增模型费用。详细范围及限制见研究工作树 `docs/MODEL_DETECT_NATIVE_PANEL_2026-09-16.md`。下方为历史阶段记录，旧网页窗口不再是本版默认入口。

当前默认界面已于2026-09-16收敛为0.4.0：选择内容→开始检测→一个结果。完整方法、历史和证据均按需展开；本地一键提交，付费仍确认费用/范围。旧报告只内存补算简要展示，不改存档。详见研究工作树 `docs/MODEL_DETECT_SIMPLE_UI_2026-09-16.md`。下方为历史阶段记录。

2026-09-16 后续更新：0.3.1 验证包已加入按送测对象的综合解释与下一步推荐。来源差异、支持偏离、反对偏离、替代解释和证据缺口分别展示。推荐仅回填配置，保持手动选层；每个父任务只能创建一个持久后续任务，提交时从全部尝试回执重算剩余预算，不接受旧报告重复领取余额。当前自动推荐优先本地可核验的短题、H01/H02，视觉及多轮任务仍单独选择。详细工程和真实解析边界见研究工作树 `docs/MODEL_DETECT_GUIDANCE_2026-09-16.md`；下文为首次接入时的基线说明。

当前工作树已连接详情面板 Model Detect、时钟菜单和会话行入口。窗口由本机 Python worker 提供界面和检测；资源通过 `Bundle.module` 获取，运行时使用按哈希固定的缓存，随包依赖无需用户另装 Python、Node 或浏览器。

默认本地分析。可选模型解析支持独立连接或明确复用本次待测 API。L2 默认完成收集并保存回答快照后只追加一次批量解析；解析不反馈给目标，不判断型号，程序核验后才提取特征和比较参考。目标与解析分别计算预算，同源特征可用但不重复加票。SVG 语义依旧标为模型辅助判断。

源码入口：`Sources/TokenClock/Services/ModelDetectWindow.swift`、`ModelIntegrityLauncher.swift`、`ModelIntegrityRuntimeCache.swift` 与 `scripts/model_integrity/`。`product-source-manifest.json` 记录从研究工作树迁入的产品源码，修改后须更新资源包；不得迁入研究密钥或原始会话。

运行 `python3 -B scripts/build_model_integrity_worker.py` 重建产品资源；该构建脚本没有 `--help` 模式。`scripts/package-model-detect-macos.py --help` 提供带依赖的本机验证打包方式；资源 bundle 必须与 standalone 二进制一同分发。依赖清单在 Mach-O 签名后生成，禁止签名后再次改变文件却沿用旧哈希。

截至 2026-09-16：产品 Python 422 项、Web 30 项、原生专项 43 项、临时目录安装资源更新 8 项，以及实际签名运行依赖 1 项验收通过。它们是工程验证，不是模型准确率。正式时钟点击因 Mac 锁屏待复核；当前验证包仅 arm64，未安装或发布，未公证，四版本适配暂停。编译基线 macOS 12，随包浏览器最低 13.5；最低版本和 Intel 未实机验收。

详细交付记录位于研究工作树的 `docs/MODEL_DETECT_NORMAL_INTEGRATION_2026-09-16.md`。现有用户修改保留，不应将整个工作树差异视为此次 Model Detect 改动。
