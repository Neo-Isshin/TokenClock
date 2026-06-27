#!/usr/bin/env bash
#
# install.sh — TokenClock 一键安装器
#
# 自动：检查环境 → 按 macOS 版本构建对应变体（26+ 双变体:液态玻璃 + 普通 / 15+ 普通）→
#      安装到 ~/.tokenclock → 安装 tokenclock CLI 到 PATH → 首次启动（自动扫描 AI 工具路径）。
#
# 用法:
#   ./cli/install.sh              # 自动检测变体 · release 构建 · 装完即启动
#   ./cli/install.sh --debug      # debug 构建（更快，适合试用）
#   ./cli/install.sh --normal     # 强制 normal 变体
#   ./cli/install.sh --glass      # 强制 liquid-glass 变体
#   ./cli/install.sh --no-start       # 装完不自动启动
#
# 一行安装（公开托管后替换 <your-host>）:
#   curl -fsSL https://<your-host>/raw/main/cli/install.sh | bash
#
# 可用环境变量覆盖默认值:
#   TOKENCLOCK_REPO     git 仓库地址            （默认: 仓库 origin）
#   TOKENCLOCK_HOME     安装根目录              （默认: ~/.tokenclock）
#   TOKENCLOCK_BIN_DIR  CLI 安装目录            （默认: ~/.local/bin）
#   TOKENCLOCK_BUILD    克隆 + 构建目录         （默认: $TOKENCLOCK_HOME/src）
#
set -uo pipefail
export LC_ALL=C      # bash 3.2 在 UTF-8 locale 下会把紧跟 $var 的多字节字符(如中文括号)误并入变量名;C locale 按字节解析可避免。中文字符串仍按 UTF-8 字节正常输出。

DEFAULT_REPO="http://localhost:3000/nxc8335/TokenClock.git"
REPO_URL="${TOKENCLOCK_REPO:-$DEFAULT_REPO}"
HOME_DIR="${TOKENCLOCK_HOME:-$HOME/.tokenclock}"
BIN_DIR="${TOKENCLOCK_BIN_DIR:-$HOME/.local/bin}"
BUILD_DIR="${TOKENCLOCK_BUILD:-$HOME_DIR/src}"

CONFIG="release"
VARIANT=""          # "" = 按系统版本自动
NO_START=0
BUILT_BINS=()       # 收集所有变体的 构建产物路径:variant

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
    --debug)     CONFIG=debug ;;
    --release)   CONFIG=release ;;
    --no-start)     NO_START=1 ;;
    -h|--help)      usage ;;
    *)              die "未知参数: $1（可用 --glass / --normal / --debug / --release / --no-start）" ;;
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

# ── 4. 构建 ──
for i in "${!VARIANTS[@]}"; do
  variant="${VARIANTS[$i]}"
  branch="${BRANCHES[$i]}"
  subdir="$BUILD_DIR/$branch"
  step "构建 [$variant]（swift build -c $CONFIG · 首次可能需要几分钟）"
  ( cd "$subdir" && swift build -c "$CONFIG" ) || die "[$variant] 构建失败"
  BIN_PATH="$subdir/.build/$CONFIG/TokenClock"
  [ -f "$BIN_PATH" ] || die "找不到构建产物: $BIN_PATH"
  BUILT_BINS+=("$BIN_PATH:$variant")
done

# ── 5. 暂存二进制 ──
for entry in "${BUILT_BINS[@]}"; do
  bin_path="${entry%:*}"
  variant="${entry##*:}"
  step "安装时钟 [$variant] 到 $HOME_DIR/$variant"
  mkdir -p "$HOME_DIR/$variant"
  cp "$bin_path" "$HOME_DIR/$variant/TokenClock"
  chmod +x "$HOME_DIR/$variant/TokenClock"
  say "  ✓ $HOME_DIR/$variant/TokenClock"
done

# ── 6. 安装 tokenclock CLI ──
step "安装 tokenclock CLI"
mkdir -p "$BIN_DIR"
cp "$BUILD_DIR/cli/tokenclock" "$BIN_DIR/tokenclock"
chmod +x "$BIN_DIR/tokenclock"
say "  ✓ $BIN_DIR/tokenclock"
export PATH="$BIN_DIR:$PATH"   # 让本脚本后续命令能直接用 tokenclock

# ── 7. 开机自启动（LaunchAgent） ──
# 启动器不再注册 plist；LaunchAgent 由 Swift 时钟的右键菜单统一管理。
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

# y/N 提示；默认 N（最少惊喜）。非交互（curl | bash）下跳过。
prompt_api_server() {
  local API_PORT_DEFAULT=9988
  local API_PORT_TRIES=5
  local API_PORT_FALLBACK_MSG="（启动可能失败）"
  local API_PORT_RANGE_END=$((API_PORT_DEFAULT + API_PORT_TRIES))   # 9993

  # 非交互模式（pipe / 无 TTY）：默认关闭，安静跳过
  if [ ! -t 0 ]; then
    defaults delete TokenClock TC_apiServerEnabled 2>/dev/null || true
    say "  ⏭ API 服务器: 跳过（非交互模式，默认关闭）"
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

  开机自启动:  默认开启（在时钟右键菜单中可关闭）
  API 服务器: $API_LINE
EOF

[ -n "$API_URL" ] && printf '  API 端点:   %s\n' "$API_URL"

cat <<EOF

常用命令（新开终端或 source ~/.zshrc 后即可直接用）:
  tokenclock start [--glass|--normal]   启动（按系统版本自动选）
  tokenclock stop                       停止
  tokenclock restart [--glass|--normal] 重启
  tokenclock doctor                     诊断环境与已安装版本
  tokenclock update                     更新（占位，服务器待部署）

关闭开机自启: 在时钟上右键 → 取消勾选「开机自启」

── tokenclock doctor ──
EOF
printf '%s\n' "$DOCTOR_OUT"

cat <<EOF

一行安装（公开托管后替换 <your-host>）:
  curl -fsSL https://<your-host>/raw/main/cli/install.sh | bash

EOF
