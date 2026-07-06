#!/usr/bin/env bash
#
# install.sh — TokenClock 一键安装器
#
# 自动：检查环境 → 按 macOS 版本构建对应变体（26+ 双变体:液态玻璃 + 普通 / 15+ 普通）→
#      安装到 ~/.tokenclock → 安装 tokenclock CLI 到 PATH → 首次启动（自动扫描 AI 工具路径）。
#
# 用法:
#   ./cli/install.sh              # 自动检测变体 · 默认下载预编译二进制 · 装完即启动
#   ./cli/install.sh --debug      # debug 构建（更快，适合试用；隐含 --build-from-source）
#   ./cli/install.sh --normal     # 强制 normal 变体
#   ./cli/install.sh --glass      # 强制 liquid-glass 变体
#   ./cli/install.sh --no-start       # 装完不自动启动
#   ./cli/install.sh --build-from-source  # 跳过预编译下载，强制本地 swift build
#
# 一行安装:
#   curl -fsSL https://gitea.nxc8335.cloud/nxc8335/TokenClock/raw/main/cli/install.sh | bash
#
# 可用环境变量覆盖默认值:
#   TOKENCLOCK_REPO     git 仓库地址            （默认: 仓库 origin）
#   TOKENCLOCK_HOME     安装根目录              （默认: ~/.tokenclock）
#   TOKENCLOCK_BIN_DIR  CLI 安装目录            （默认: ~/.local/bin）
#   TOKENCLOCK_BUILD    克隆 + 构建目录         （默认: $TOKENCLOCK_HOME/src）
#
set -uo pipefail
export LC_ALL=C      # bash 3.2 在 UTF-8 locale 下会把紧跟 $var 的多字节字符(如中文括号)误并入变量名;C locale 按字节解析可避免。中文字符串仍按 UTF-8 字节正常输出。

DEFAULT_REPO="https://gitea.nxc8335.cloud/nxc8335/TokenClock.git"
REPO_URL="${TOKENCLOCK_REPO:-$DEFAULT_REPO}"
HOME_DIR="${TOKENCLOCK_HOME:-$HOME/.tokenclock}"
BIN_DIR="${TOKENCLOCK_BIN_DIR:-$HOME/.local/bin}"
BUILD_DIR="${TOKENCLOCK_BUILD:-$HOME_DIR/src}"
# 更新源（cmd_update 拉取此 URL；tokenclock wrapper 默认同值）
INSTALL_URL="${TOKENCLOCK_INSTALL_URL:-https://gitea.nxc8335.cloud/nxc8335/TokenClock/raw/main/cli/install.sh}"

CONFIG="release"
VARIANT=""          # "" = 按系统版本自动
NO_START=0
FORCE=0             # --force：跳过"无变化"短路，强制重新部署二进制
DEPLOYED_ANYTHING=0 # 本次是否真的部署了变更（回报给 tokenclock update 决定是否重启）
BUILT_BINS=()       # 收集所有变体的 构建产物路径:variant
BUILD_FROM_SOURCE=0 # --build-from-source：跳过预编译下载，强制本地 swift build

say()  { printf '%s\n' "$*"; }
step() { printf '\n🛠  %s\n' "$*"; }
die()  { printf '\n❌ %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '3,22p' "$0" 2>/dev/null || true
  exit 0
}

# ── 参数 ──
while [ $# -gt 0 ]; do
  case "$1" in
    --glass)     VARIANT=glass ;;
    --normal)    VARIANT=normal ;;
    --debug)     CONFIG=debug; BUILD_FROM_SOURCE=1 ;;   # debug 无预编译，走源码
    --release)   CONFIG=release ;;
    --no-start)     NO_START=1 ;;
    --force)        FORCE=1 ;;
    --build-from-source) BUILD_FROM_SOURCE=1 ;;
    -h|--help)      usage ;;
    *)              die "未知参数: $1（可用 --glass / --normal / --debug / --release / --no-start / --force / --build-from-source）" ;;
  esac
  shift
done

# ── 1. 前置检查 ──
step "检查环境"
command -v sw_vers >/dev/null || die "需要 macOS（未找到 sw_vers）。"
command -v git    >/dev/null || die "未找到 git。请先安装 Xcode 命令行工具：xcode-select --install"
command -v swift  >/dev/null || die "未找到 Swift 工具链。请先安装 Xcode 或命令行工具：xcode-select --install"

OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
say "  macOS $(sw_vers -productVersion) · 主版本 $OS_MAJOR · 工具链 $(swift --version 2>/dev/null | head -1)"

# ── 2. 选变体 ──
if [ -z "$VARIANT" ]; then
  if [ "$OS_MAJOR" -ge 26 ]; then
    # macOS 26+:同时拉两个变体(Liquid Glass + normal)
    VARIANTS=(glass normal)
    BRANCHES=(main normal)
    PRIMARY_VARIANT=glass    # 默认/首启变体
  elif [ "$OS_MAJOR" -ge 15 ]; then
    # macOS 15-25:只 normal(经典不透明版)
    VARIANTS=(normal)
    BRANCHES=(normal)
    PRIMARY_VARIANT=normal
  else
    die "需要 macOS 15 或更高版本（当前主版本 $OS_MAJOR）。"
  fi
else
  # 手动 --glass / --normal 时,只装指定那一个
  case "$VARIANT" in
    glass)  VARIANTS=(glass);  BRANCHES=(main);   PRIMARY_VARIANT=glass ;;
    normal) VARIANTS=(normal); BRANCHES=(normal); PRIMARY_VARIANT=normal ;;
  esac
fi
VARIANT_LABELS=""
for i in "${!VARIANTS[@]}"; do
  if [ -z "$VARIANT_LABELS" ]; then
    VARIANT_LABELS="${VARIANTS[$i]} (${BRANCHES[$i]})"
  else
    VARIANT_LABELS="$VARIANT_LABELS + ${VARIANTS[$i]} (${BRANCHES[$i]})"
  fi
done
say "  变体: $VARIANT_LABELS · 构建: $CONFIG"

# ── 3. 获取源码 ──
for i in "${!VARIANTS[@]}"; do
  variant="${VARIANTS[$i]}"
  branch="${BRANCHES[$i]}"
  subdir="$BUILD_DIR/$branch"
  step "获取源码 [$variant]（$REPO_URL · $branch）"
  if [ -d "$subdir/.git" ]; then
    git -C "$subdir" fetch --depth 1 origin "$branch" >/dev/null 2>&1 || die "git fetch [$variant] 失败（检查网络或 TOKENCLOCK_REPO）"
    git -C "$subdir" checkout "$branch" >/dev/null 2>&1 || die "切换分支 $branch 失败（[$variant]）"
    git -C "$subdir" reset --hard "origin/$branch" >/dev/null 2>&1
    say "  已更新: $subdir"
  else
    mkdir -p "$subdir"
    git clone --depth 1 --branch "$branch" "$REPO_URL" "$subdir" >/dev/null 2>&1 \
      || die "git clone [$variant] 失败（检查 TOKENCLOCK_REPO=$REPO_URL 或网络）"
    say "  已克隆: $subdir"
  fi
done

# ── 4. 获取二进制（优先下载预编译，失败 / --build-from-source 则回退源码编译）──
# 预编译资产来自 Gitea release（universal：arm64+x86_64），免 Xcode / 免编译。
# 升级 release 时同步更新 RELEASE_TAG 与两个 SHA256。
RELEASE_TAG="${TOKENCLOCK_RELEASE_TAG:-v1.1.0}"
RELEASE_URL_BASE="${TOKENCLOCK_RELEASE_BASE:-https://gitea.nxc8335.cloud/nxc8335/TokenClock/releases/download/$RELEASE_TAG}"

# 变体 → tarball 文件名 / 期望 SHA256（bash 3.2 无关联数组，用 case）
tarball_name() {
  case "$1" in
    glass)  echo "TokenClock-glass-universal.tar.gz" ;;
    normal) echo "TokenClock-normal-universal.tar.gz" ;;
  esac
}
tarball_sha256() {
  case "$1" in
    glass)  echo "6741cfdcf605a136ec2fe28c4717c7dc962322d43989986b4c2a7418bdb0d671" ;;
    normal) echo "bbebd21842a029c342e945778b604a39191d966e18cb90687364bd52d768d3e0" ;;
  esac
}

# 下载 + SHA256 校验 + 解压 [$variant]。成功 → 解压目录写入全局 $DL_DIR，返回 0；
# 失败 → 返回 1（调用方回退源码编译）。临时目录登记到 DOWNLOAD_TMPDIRS，脚本退出时清理。
DL_DIR=""
DOWNLOAD_TMPDIRS=()
trap '[ "${#DOWNLOAD_TMPDIRS[@]}" -gt 0 ] && rm -rf "${DOWNLOAD_TMPDIRS[@]}" 2>/dev/null || true' EXIT
download_variant() {
  local variant="$1" name expect url tmp got
  name="$(tarball_name "$variant")"
  expect="$(tarball_sha256 "$variant")"
  [ -n "$name" ] && [ -n "$expect" ] || return 1
  url="$RELEASE_URL_BASE/$name"
  step "下载预编译二进制 [$variant]（$RELEASE_TAG）"
  tmp="$(mktemp -d 2>/dev/null)" || return 1
  if ! curl -fL --retry 3 --retry-delay 1 -o "$tmp/$name" "$url" 2>/dev/null; then
    say "  ⚠ [$variant] 预编译下载失败（$url）→ 回退源码编译"
    rm -rf "$tmp"; return 1
  fi
  got="$(shasum -a 256 "$tmp/$name" | cut -d' ' -f1)"
  if [ "$got" != "$expect" ]; then
    say "  ⚠ [$variant] SHA256 不符（期望 ${expect:0:12}… 得到 ${got:0:12}…）→ 回退源码编译"
    rm -rf "$tmp"; return 1
  fi
  if ! tar xzf "$tmp/$name" -C "$tmp" 2>/dev/null || [ ! -f "$tmp/TokenClock" ]; then
    say "  ⚠ [$variant] 解压失败或包内无 TokenClock → 回退源码编译"
    rm -rf "$tmp"; return 1
  fi
  chmod +x "$tmp/TokenClock"
  say "  ✓ [$variant] 预编译二进制就绪（SHA256 ${got:0:12}…）"
  DL_DIR="$tmp"
  DOWNLOAD_TMPDIRS+=("$tmp")
  return 0
}

# 本地源码编译：macOS 27 + 仅 CLT 时自动 pin 到 26 SDK（绕过 SwiftUIMacros 缺失）。
swift_build_fallback() {
  local subdir="$1"
  local sdk26="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
  if [ "${OS_MAJOR:-0}" -ge 27 ] && [ -d "$sdk26" ] \
     && [ "$(xcode-select -p 2>/dev/null)" = "/Library/Developer/CommandLineTools" ]; then
    say "  · 检测到 macOS $OS_MAJOR + 仅 CLT → 自动 SDKROOT=$sdk26 绕过 SwiftUIMacros"
    ( cd "$subdir" && SDKROOT="$sdk26" swift build -c "$CONFIG" )
  else
    ( cd "$subdir" && swift build -c "$CONFIG" )
  fi
}

for i in "${!VARIANTS[@]}"; do
  variant="${VARIANTS[$i]}"
  branch="${BRANCHES[$i]}"
  subdir="$BUILD_DIR/$branch"

  # 4a. 优先用预编译二进制
  if [ "$BUILD_FROM_SOURCE" -eq 0 ] && download_variant "$variant"; then
    BUILT_BINS+=("$DL_DIR/TokenClock:$variant")
    continue
  fi

  # 4b. 回退：本地源码编译
  step "构建 [$variant]（swift build -c $CONFIG · 首次可能需要几分钟）"
  swift_build_fallback "$subdir" \
    || die "[$variant] 构建失败（预编译下载也未成功）。常见原因：未装完整 Xcode（macOS 27 SDK 的 @State 宏需要 SwiftUIMacros，仅 CLT 不带）。请装 Xcode 后重试，或确认本机有 MacOSX26.sdk 由本脚本自动 pin。"
  BIN_PATH="$subdir/.build/$CONFIG/TokenClock"
  [ -f "$BIN_PATH" ] || BIN_PATH="$subdir/.build/out/Products/$([ "$CONFIG" = release ] && echo Release || echo Debug)/TokenClock"
  [ -f "$BIN_PATH" ] || die "找不到构建产物: $BIN_PATH"
  BUILT_BINS+=("$BIN_PATH:$variant")
done

# ── 5. 暂存二进制 + 资源 bundle（仅在变化时更新；--force 强制）──
for entry in "${BUILT_BINS[@]}"; do
  bin_path="${entry%:*}"
  variant="${entry##*:}"
  dest_bin="$HOME_DIR/$variant/TokenClock"
  mkdir -p "$HOME_DIR/$variant"
  step "安装时钟 [$variant] 到 $HOME_DIR/$variant"

  # 二进制：哈希比对决定是否覆盖（--force / 首次部署 / 哈希不同 → 覆盖）
  bin_changed=0
  if [ "$FORCE" -eq 1 ] || [ ! -f "$dest_bin" ]; then
    bin_changed=1
  elif [ "$(shasum -a 256 "$bin_path" | cut -d' ' -f1)" != "$(shasum -a 256 "$dest_bin" | cut -d' ' -f1)" ]; then
    bin_changed=1
  fi
  if [ "$bin_changed" -eq 1 ]; then
    cp "$bin_path" "$dest_bin"
    chmod +x "$dest_bin"
    say "  ✓ $dest_bin"
    DEPLOYED_ANYTHING=1
  else
    say "  · [$variant] 二进制未变化，跳过"
  fi

  # 资源 bundle：构建产物里有就部署到二进制旁（让运行时 Bundle.module 的 mainPath 命中；
  # 否则非开发机切 .glass 主题会因找不到 bundle 而 fatalError）。缺失时计入 DEPLOYED 触发重启。
  bundle_src="$(dirname "$bin_path")/TokenClock_TokenClock.bundle"
  if [ -d "$bundle_src" ]; then
    dest_bundle="$HOME_DIR/$variant/TokenClock_TokenClock.bundle"
    bundle_missing=0; [ -d "$dest_bundle" ] || bundle_missing=1
    rm -rf "$dest_bundle"
    cp -R "$bundle_src" "$dest_bundle"
    say "  ✓ $dest_bundle（资源）"
    [ "$bundle_missing" -eq 1 ] && DEPLOYED_ANYTHING=1
  fi
done

# 把"是否真的部署了变更"回报给调用方（tokenclock update 据此决定是否重启）
if [ -n "${TOKENCLOCK_STATUS_FILE:-}" ]; then
  echo "DEPLOYED=$DEPLOYED_ANYTHING" > "$TOKENCLOCK_STATUS_FILE"
fi

# ── 6. 安装 tokenclock CLI ──
step "安装 tokenclock CLI"
mkdir -p "$BIN_DIR"
# 找 PRIMARY_VARIANT 对应的分支作为 CLI 来源
# 26+ 双变体: PRIMARY_VARIANT=glass → BRANCHES[0]=main
# 15+ 单变体: PRIMARY_VARIANT=normal → BRANCHES[0]=normal
CLI_SRC_BRANCH="${BRANCHES[0]}"
if [ ! -f "$BUILD_DIR/$CLI_SRC_BRANCH/cli/tokenclock" ]; then
  # 兜底:遍历所有分支,找第一个有 cli/tokenclock 的
  for b in "${BRANCHES[@]}"; do
    [ -f "$BUILD_DIR/$b/cli/tokenclock" ] && CLI_SRC_BRANCH="$b" && break
  done
fi
[ -f "$BUILD_DIR/$CLI_SRC_BRANCH/cli/tokenclock" ] \
  || die "找不到 cli/tokenclock (已查: ${BRANCHES[*]})"
cp "$BUILD_DIR/$CLI_SRC_BRANCH/cli/tokenclock" "$BIN_DIR/tokenclock"
chmod +x "$BIN_DIR/tokenclock"
say "  ✓ $BIN_DIR/tokenclock"
export PATH="$BIN_DIR:$PATH"   # 让本脚本后续命令能直接用 tokenclock

# ── 7. 开机自启动（LaunchAgent） ──
# 与 Swift 端 LaunchAgentHelper 同格式写 plist：label / ProgramArguments /
# RunAtLoad=true / ProcessType=Interactive。Swift 端 cleanupLegacy() 会
# "继承" 这个 plist 视为用户已选自启,保证右键菜单 toggle 状态正确。
# 用户在时钟右键菜单里关掉时,Swift 端 enable/disable 会再覆盖本 plist。
# 选一个空闲端口：先试 $1，往后顺延 N 次
find_free_port() {
  local start="$1" tries="$2" p
  for p in $(seq "$start" $((start + tries))); do
    if ! lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "$p"; return 0
    fi
  done
  return 1
}

# 注册 PRIMARY_VARIANT 的 LaunchAgent plist。Swift 端 LaunchAgentHelper 的
# enable() 写 plist 用 ProcessInfo.arguments[0] 作为 binaryPath —— 本脚本
# 上下文里就是 $HOME_DIR/$PRIMARY_VARIANT/TokenClock,等价。
enable_launch_agent() {
  local variant="$1" binary_path="$2"
  local plist_dir="$HOME/Library/LaunchAgents"
  local plist_path="$plist_dir/com.tokenclock.app.${variant}.plist"
  local label="com.tokenclock.app.${variant}"

  mkdir -p "$plist_dir" || die "创建 $plist_dir 失败"

  # 幂等:plist 已存在且 RunAtLoad=true → 跳过,避免重新 load 引起 launchd 抖动
  if [ -f "$plist_path" ] && /usr/libexec/PlistBuddy -c "Print :RunAtLoad" "$plist_path" 2>/dev/null | grep -q "true"; then
    say "  ⏭ LaunchAgent 已注册: $plist_path"
    return 0
  fi

  # 写 plist:与 Swift 端 LaunchAgentHelper.renderPlist 同字段 / 同顺序
  cat > "$plist_path" <<EOF || die "写 $plist_path 失败"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$binary_path</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
    <key>KeepAlive</key>
    <dict>
        <key>Crashed</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

  # launchctl load -w:加载并标记为 "enable across reboots"（即 RunAtLoad 持久化）
  if launchctl load -w "$plist_path" 2>/dev/null; then
    say "  ✓ LaunchAgent 已注册: $plist_path"
  else
    say "  ⚠ launchctl load 失败（$plist_path 已写,Swift 端右键菜单可恢复）"
  fi
}

# y/N 提示；默认 N（最少惊喜）。非交互（curl | bash）下跳过。
prompt_api_server() {
  local API_PORT_DEFAULT=9988
  local API_PORT_TRIES=5
  local API_PORT_FALLBACK_MSG="（启动可能失败）"
  local API_PORT_RANGE_END=$((API_PORT_DEFAULT + API_PORT_TRIES))   # 9993

  # 非交互模式（curl|bash、heredoc）：默认启用，安静调端口探测
  if [ ! -t 0 ]; then
    local chosen_port
    if chosen_port="$(find_free_port "$API_PORT_DEFAULT" "$API_PORT_TRIES")"; then
      if [ "$chosen_port" != "$API_PORT_DEFAULT" ]; then
        say "  ⚠ $API_PORT_DEFAULT 被占用 → 改用 $chosen_port"
      fi
    else
      chosen_port="$API_PORT_DEFAULT"
      say "  ⚠ ${API_PORT_DEFAULT}–${API_PORT_RANGE_END} 全部被占用，仍使用 $chosen_port$API_PORT_FALLBACK_MSG"
    fi
    defaults write TokenClock TC_apiServerEnabled -bool true \
      || die "defaults write TC_apiServerEnabled 失败"
    defaults write TokenClock TC_apiServerPort -int "$chosen_port" \
      || die "defaults write TC_apiServerPort 失败"
    API_ENABLED=1
    API_CHOSEN_PORT="$chosen_port"
    say "  ✓ API 服务器: 已启用（非交互模式自动开启，端口 $chosen_port）"
    return 0
  fi

  local ans
  printf '  启用本地 API 服务器（监听 127.0.0.1:%d）? [y/N] ' "$API_PORT_DEFAULT"
  IFS= read -r ans || ans=""
  ans="$(printf '%s' "$ans" | tr 'A-Z' 'a-z')"
  case "$ans" in
    y|yes)
      local chosen_port
      if chosen_port="$(find_free_port "$API_PORT_DEFAULT" "$API_PORT_TRIES")"; then
        if [ "$chosen_port" != "$API_PORT_DEFAULT" ]; then
          say "  ⚠ $API_PORT_DEFAULT 被占用 → 改用 $chosen_port"
        fi
      else
        chosen_port="$API_PORT_DEFAULT"
        say "  ⚠ ${API_PORT_DEFAULT}–${API_PORT_RANGE_END} 全部被占用，仍使用 $chosen_port$API_PORT_FALLBACK_MSG"
      fi

      defaults write TokenClock TC_apiServerEnabled -bool true \
        || die "defaults write TC_apiServerEnabled 失败"
      defaults write TokenClock TC_apiServerPort -int "$chosen_port" \
        || die "defaults write TC_apiServerPort 失败"

      API_ENABLED=1
      API_CHOSEN_PORT="$chosen_port"
      say "  ✓ API 服务器: 已启用（端口 $chosen_port，$HOME_DIR/$PRIMARY_VARIANT/TokenClock 启动后生效）"
      ;;
    *)
      defaults delete TokenClock TC_apiServerEnabled 2>/dev/null || true
      say "  ⏭ API 服务器: 未启用（默认）"
      ;;
  esac
}

# ── 7b. 询问是否启用本地 API 服务 ──
API_ENABLED=0
API_CHOSEN_PORT=9988
if [ "$NO_START" -eq 1 ]; then
  say "  ⏭ API 服务器: 跳过（--no-start，未启动应用）"
else
  step "配置本地 API 服务器（可选）"
  prompt_api_server
fi

# ── 8. 确保 PATH（写入 shell rc，幂等）──
ensure_in_path() {
  case ":$PATH:" in *":$BIN_DIR:"*) return 0 ;; esac      # 当前 shell 已在 PATH
  local rc
  for rc in "$HOME/.zshrc" "$HOME/.bash_profile"; do
    [ -f "$rc" ] && grep -qF "$BIN_DIR" "$rc" && return 0  # 某个 rc 已配置
  done
  printf '\n# Added by tokenclock installer\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >> "$HOME/.zshrc"
  say "  已把 $BIN_DIR 加入 ~/.zshrc（新开终端生效）"
}
ensure_in_path

# ── 8b. 注册开机自启 LaunchAgent ──
# 显式注册 plist 让 install.sh 的"默认开启自启"承诺落到磁盘上。
# Swift 端 LaunchAgentHelper.cleanupLegacy() 会"继承"本 plist,避免右键菜单 toggle 状态不一致。
LAUNCH_AGENT_OK=0
LAUNCH_AGENT_PATH="$HOME/Library/LaunchAgents/com.tokenclock.app.${PRIMARY_VARIANT}.plist"
if [ "$NO_START" -eq 1 ]; then
  say "  ⏭ LaunchAgent: 跳过（--no-start）"
else
  step "注册开机自启 LaunchAgent ($PRIMARY_VARIANT)"
  enable_launch_agent "$PRIMARY_VARIANT" "$HOME_DIR/$PRIMARY_VARIANT/TokenClock"
  LAUNCH_AGENT_OK=1
fi

# ── 8c. 清理残留的"经典 Login Item" ──
# 旧版菜单（SMAppService）或开发期从 .build 运行时，可能注册过"经典 Login Item"指向
# 裸可执行文件 —— macOS 会用 Terminal 打开它，导致每次登录弹出终端窗、显示启动 stdout、
# 关闭终端还会杀进程。自启现由上面的 LaunchAgent（launchd 直接拉起、无终端）独占，
# 这里 best-effort 删掉名为 TokenClock 的经典 login item（需"自动化"权限，失败静默忽略）。
if [ "$NO_START" -eq 0 ]; then
  if osascript -e 'tell application "System Events" to delete (every login item whose name is "TokenClock")' >/dev/null 2>&1; then
    say "  ✓ 已清理残留的经典 Login Item（若有）"
  else
    # osascript 非零退出（常见:自动化权限被拒）。best-effort 不终止安装,
    # 提示用户手动处理:授权自动化 或 在系统设置里删掉残留 login item。
    say "  ⚠ 未能自动清理经典 Login Item（可能缺少「自动化」权限）。"
    say "    请在 系统设置 → 隐私与安全性 → 自动化 中授予终端「系统事件」权限,"
    say "    或在 系统设置 → 通用 → 登录项 中手动删除名为「TokenClock」的项目。"
  fi
fi

# ── 9. 首次启动（= 初始化：首次扫描各 AI 工具本地路径）──
if [ "$NO_START" -eq 1 ]; then
  say "  ⏭  跳过自动启动（--no-start）"
else
  step "首次启动 $PRIMARY_VARIANT 版并扫描 AI 工具路径"
  tokenclock stop >/dev/null 2>&1 || true                    # 停掉旧实例，确保用新二进制
  tokenclock start --"$PRIMARY_VARIANT" >/dev/null 2>&1 || die "启动失败"
  say "  已启动 $PRIMARY_VARIANT 版"
  sleep 3                                                    # 等待首次扫描
  enabled="$(defaults read TokenClock TC_enabledTools 2>/dev/null \
             | tr -d '()"' | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | paste -sd ',' - | sed 's/,/, /g')"
  if [ -n "$enabled" ]; then
    say "  🔍 检测到已启用工具: $enabled"
  else
    say "  🔍 首次扫描已完成（如未列出工具，可在时钟右键 → 设置中手动启用 / 指定路径）"
  fi

  # API 服务器烟雾测试（若启用）。TokenClock 启动后端口才会 listen。
  if [ "${API_ENABLED:-0}" -eq 1 ] && [ -n "${API_CHOSEN_PORT:-}" ]; then
    sleep 1
    if out="$(curl -fsS --max-time 2 "http://127.0.0.1:${API_CHOSEN_PORT}/api/usage" 2>/dev/null | head -c 80)"; then
      say "  ✓ API 烟雾测试: http://127.0.0.1:${API_CHOSEN_PORT}/api/usage → ${out}…"
    else
      say "  ⚠ API 烟雾测试失败（端口 ${API_CHOSEN_PORT} 未在监听；检查防火墙或稍后重试）"
    fi
  fi
fi

# ── 10. 完成 ──
step "安装完成 · 生成摘要"

# 1. 收集 doctor 输出（PATH 已在 step 6 export 过，tokenclock 可直接调用）
DOCTOR_OUT=""
if command -v tokenclock >/dev/null 2>&1; then
  DOCTOR_OUT="$(tokenclock doctor 2>&1 || true)"
else
  DOCTOR_OUT="（tokenclock 不在 PATH，跳过 doctor）"
fi

# 2. API 状态行
if [ "${API_ENABLED:-0}" -eq 1 ]; then
  API_LINE="✓ 已启用 · 端口 ${API_CHOSEN_PORT}"
  API_URL="http://127.0.0.1:${API_CHOSEN_PORT}/api/usage"
else
  API_LINE="⏭ 未启用（默认）"
  API_URL=""
fi

cat <<EOF

🎉 TokenClock 安装完成！

  变体:   $VARIANT_LABELS
  时钟:   $HOME_DIR/${VARIANTS[0]}/TokenClock
EOF
# 多变体时,挨个列路径（单变体已在上行覆盖）
if [ "${#VARIANTS[@]}" -gt 1 ]; then
  for v in "${VARIANTS[@]:1}"; do
    printf '         + %s\n' "$HOME_DIR/$v/TokenClock"
  done
fi

cat <<EOF
  CLI:    $BIN_DIR/tokenclock
EOF
# 源码:每个分支的子目录各一行
for branch in "${BRANCHES[@]}"; do
  printf '  源码:   %s/%s\n' "$BUILD_DIR" "$branch"
done

cat <<EOF

  API 服务器: $API_LINE
EOF

[ -n "$API_URL" ] && printf '  API 端点:   %s\n' "$API_URL"

# 开机自启 banner:反映真实状态
if [ "$LAUNCH_AGENT_OK" -eq 1 ] && [ -f "$LAUNCH_AGENT_PATH" ]; then
  printf '  开机自启动:  ✓ 已启用（%s）\n' "$LAUNCH_AGENT_PATH"
  printf '              在时钟右键 → 设置中可关闭\n'
else
  printf '  开机自启动:  ⏭ 未启用\n'
fi

cat <<EOF

常用命令（新开终端或 source ~/.zshrc 后即可直接用）:
  tokenclock start [--glass|--normal]   启动（按系统版本自动选）
  tokenclock stop                       停止
  tokenclock restart [--glass|--normal] 重启
  tokenclock doctor                     诊断环境与已安装版本
  tokenclock update [--glass|--normal]  拉取最新 install.sh 升级并重启
  tokenclock update --check             只下载最新脚本，不实际升级

关闭开机自启: 在时钟上右键 → 取消勾选「开机自启」

── tokenclock doctor ──
EOF
printf '%s\n' "$DOCTOR_OUT"

cat <<EOF

一行安装:
  curl -fsSL $INSTALL_URL | bash
EOF

