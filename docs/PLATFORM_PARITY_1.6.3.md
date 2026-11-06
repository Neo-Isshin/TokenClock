# v1.6.3 功能对齐

基准：已发布的 macOS Glass `111af169`。只纳入发布基准及本次平台适配，未复制原开发工作树的未提交内容。

## 共同能力

- 工具／模型归一化、只读日志、外部目录、并发请求归属、缓存与 API 等价费用及 Fast 拆分。
- 新 harness、真实 t/s 与 TTFT 口径、每三分钟刷新、历史逐小时数据及自然日／周／月报告。
- 多账号订阅、续费提醒、已确认的 X 共享周额度及去重、最多四项额度选择和两项分页、Antigravity 三类额度。
- AI 速递、厂商 logo／轨道、两小时抓取、行事本与提醒、通知分类和已读、十二小时版本检查。
- 总结面板的小时图、同比、缓存、额度重置时间、工具／模型费用列表与快捷区域。
- 可编辑快捷按钮、边缘拉伸、分享周期与缓存开关、自然风光背景、Ailyre 标识。
- 网络／本地工具箱、按需探测、增量／全面检查、上次结果与检查时间、脱敏 API key 验活。

## 保留的平台设计

Normal 保留自己的表盘、主题、对比度和文字颜色作用范围，最低 macOS 12；Glass 的透明材质与专属光学效果不移植到 Normal。

Linux 使用 GTK／Cairo。浏览器 DNS／WebRTC／DoH 检测直接打开 Ailyre 完整检测页；本机出口、IPv6、地区、AI 分流和 Globalping 对照在原生窗口展示。模型检测通过同一打包的本机 worker 打开浏览器界面；仅用户明确启动的检测会发起模型请求。Linux 菜单提供总结入口，维持 PARITY-006 登记的原生入口差异。

Claude 优先读取已有 App 保存的真实额度历史／响应；缺失、过期、损坏或组织不明的记录不作为当前额度。不同平台可复用的登录来源按系统实际支持处理，无需为读取 App 记录额外安装 CLI。

Linux Grok Bot 支持已有 Linux OSCrypt v10/v11 存储和桌面 Secret Service：后台不请求解锁，仅主动授权按钮可请求目标密钥解锁；不写回原 App。无法识别的新存储格式保持不可用，不以反复授权或假额度代替。

Windows 原生验证按用户要求暂停，等待自有 Windows 开机；不发布未经验证的新 Windows 安装包。

## 构建与测试约束

自 2026-11-06 用户明确要求后，不在 GitHub Actions 执行测试。测试使用本机和自有 Debian／Windows。Windows 离线时保留待验证改动，不能把 Mac／Linux 通过视为 Windows 验收。GitHub Actions 已恢复关闭；价格自动刷新继续使用 Ailyre。

## 实现依据与依赖

- [Chromium Linux OSCrypt](https://chromium.googlesource.com/chromium/src.git/+/refs/tags/138.0.7204.304/components/os_crypt/sync/os_crypt_linux.cc)：现行 v10/v11 编码及 Linux PBKDF2 参数。
- [libsecret search](https://gnome.pages.gitlab.gnome.org/libsecret/method.Service.search_sync.html)：未显式解锁时只取可读取项；授权动作仅针对所选 App 的 Safe Storage。
- [Electron Safe Storage](https://github.com/electron/electron/blob/main/docs/api/safe-storage.md)：各平台存储差异。未知格式不能视为退出登录。
- zstd、GTK、libsecret 和 OpenSSL 通过随包动态库或系统库使用；保留各自许可证。
