# Glass Model Detect 接入


## 源码交付与验证（2026-10-21）

本分支整理现有 Model Detect 实现：Glass 为 0.11.0，Normal 为 0.6.0，不表示两版功能已对齐。Windows/Linux 尚无本模块的前端接入。本次只提交源码与资源，不发布版本或替换用户 runtime。

交付包含原生界面、菜单/会话入口、本地 worker、固定的汇总参考数据、源文件哈希清单和测试。runtime.zip 可从本分支产品源码确定性重建；不提交研究原始会话、私有配置、凭据、Python 字节码或本机解释器/浏览器依赖。外部参考的许可保留在资源中；参考相似度与库内排名不等同于独立验证的模型身份准确率。

普通 SwiftPM 构建包含 worker 代码，不包含完整 Python/Node/浏览器依赖；需要可用的 Python 3.10+，可选检测的依赖由能力检查报告。scripts/package-model-detect-macos.py 接受显式准备的依赖目录，生成单架构本地验证包；这不是通用架构或公证发布流程，依赖清单必须对应签名后的实际字节。

可离线重复执行：

```sh
python3 -B scripts/test_model_detect_product.py -v
swift test --jobs 2 --filter 'ModelDetect|ModelIntegrity'
```

如需重建产品资源，运行 python3 -B scripts/build_model_integrity_worker.py。真实随包依赖验收测试只在显式设置 TOKENCLOCK_TEST_PACKAGED_WORKER 为已准备的绝对 worker 路径时启用；它只启动独立临时状态的本机 worker，不发送模型请求。

默认只进行本地分析。外部请求需要用户另行确认发送范围与费用；已有会话中的指令、模型名和目录不得触发执行或自动外发。以下是历史接入记录，不替代本次重新运行的测试结果；其中研究目录与本机备份均不属于产品分发内容。
2026-10-16 数字指纹接入：用户明确取消新增模型验证前置要求，直接采用冻结的Ikaleio/lm-detector外部方法。本机Glass已更新Model Detect 0.11.0 / build 2026101601，快速检测默认三次独立数字题，59个外部参考标签在本机自动评分，直接给出“最可能是某型号”；原多题行为对照仍在高级设置可选。失败/截断/数量不足不出型号结论，低库内置信度显示两个候选；不把百分比当身份概率。实际签名包及78项原生检查通过，2247个安装资源文件逐项一致，旧版备份 `~/.tokenclock/glass/backups/model-detect-20261016-numeric/`。Mac锁屏，原生界面目检待完成。本轮模型调用与费用均为零，原研究账本未变，其他版本未同步。完整说明位于研究工作树 `docs/NUMERIC_FINGERPRINT_GLASS_ADOPTION_2026-10-16.md`；回执 `research/numeric_integration_20261016/private/completion.json`。

2026-10-15 第三阶段：本机已更新Model Detect 0.10.0 / build 2026101506。新增“参考资料与验证进度”、随包参考的完整性和更新准入检查；未启用新增候选判型。548份历史回答重提取后，195组行为参考完全一致。新增表达习惯特征的留出对照有6组方向不符，排除候选对照50组中31组仍被接纳，因此保留为研究候选；数字类候选尚待同条件新采样。Python571通过/4跳过，原生及最终签名包77项通过。安装2247个资源文件逐项一致，LaunchAgent运行正常；锁屏导致新增面板实机目检待完成。无新增模型调用，原账本未变，其他版本未同步。备份 `~/.tokenclock/glass/backups/model-detect-20261015-stage3/`。研究工作树详见 `docs/MODEL_DETECT_STAGE3_2026-10-15.md` 和 `research/model_detect_stage3_20261015/private/completion.json`。

2026-10-15 第二阶段：本机已更新Model Detect 0.9.0 / build 2026101505。费用确认前显示参考覆盖；按原因提供一次受预算链约束的补测，预览和提交都重新核对余额与父任务；历史结果按冻结条件只读对照，可随可读报告导出。旧记录缺条件时只并列展示，不补造趋势。Python557通过/4跳过、原生及最终签名包76项通过，实机模拟记录验收完成，无新增模型调用。备份 `~/.tokenclock/glass/backups/model-detect-20261015-stage2/`。研究工作树回执：`research/model_detect_stage2_20261015/private/completion.json`。

2026-10-15：已更新本机Glass至Model Detect 0.8.0 / build 2026101503。六方向雷达式覆盖概览、一句人话结论、折叠22项与原始依据、自包含可读报告导出、仅重新读取结果的恢复操作已接入。未改变评分与预算门槛，没有新增模型费用，其他版本未同步。原生与签名包72项通过，Python544通过/4跳过，实机验证并核对安装2247个资源文件。详见研究工作树 `docs/MODEL_DETECT_HUMAN_RESULT_2026-10-15.md` 及 `research/model_detect_human_result_20261015/private/completion.json`。

2026-10-06：已更新本机 Glass 的 Model Detect 0.7.0 / build 2026100602（应用基线1.5.12）。默认快速路径、已保存连接复用、一次范围与费用确认、结构化型号字段与变化检查、按实际重复样本和差距的指纹保护检查已接入。型号原始位置按需展开，三层22项图保留。完整性校验保留，首次准备路径改为用户发起优先级并减少哈希编码/路径解析开销。没有新增付费采样，ModelTrace仍待条件匹配的独立验证；Normal、Windows、Linux未同步。详见研究工作树 `docs/MODEL_DETECT_QUICK_FLOW_2026-10-06.md` 和 `research/model_integrity_quick_flow_v1/private/completion.json`。旧程序与资源备份：`~/.tokenclock/glass/backups/model-detect-20261006-quick/`。

2026-09-29：从 macOS Normal 迁入原生 Model Detect 0.6.0 面板、三层22项结果投影、会话与菜单入口、产品 worker 和不可变运行缓存。保留 Glass 自身界面、退出清理及既有改动。此为 1.5.11 的本地功能更新，没有发布新版本或修改远端安装 pins。

74 项检查通过：73 项原生/状态流程/会话路径/时钟交互/缓存测试，1 项实际签名依赖包启动验收。Release 构建通过，原生 Glass 验收窗口已实际打开。非激活时钟浮层的点击不记作自动化验收通过。

本机 `~/.tokenclock/glass/TokenClock` 及其资源 bundle 已更新，通过原有 `com.tokenclock.app.glass` LaunchAgent 重启。安装文件逐项核对与暂存构建一致，原 LaunchAgent 配置不变。旧程序和资源备份：`~/.tokenclock/glass/backups/model-detect-20260929/`。没有新增模型调用、没有迁移或重写历史数据库、没有同步其他版本。

结果与方法边界沿用研究工作树 `docs/MODEL_DETECT_MATRIX_PANEL_2026-09-29.md`。运行资源仅包含产品代码和汇总参考；不包含研究密钥或原始私有会话。重建资源使用 `scripts/build_model_integrity_worker.py`，本机签名打包使用 `scripts/package-model-detect-macos.py`；Glass 编译基线为 macOS 26，当前安装及验证为 arm64。

完整回执：研究工作树 `research/model_integrity_glass_integration_v1/private/completion.json`。
