#!/usr/bin/env bash
#
# release.sh —— TokenClock 一键发版流水线
#
# 把手工发版（v1.2.0 那次折腾的整条链）脚本化：
#   两分支 checkout → universal 构建 → tar+SHA → 改 install.sh/tokenclock pin
#   → commit 两分支 → push（HTTP/1.1，过 EdgeOne）→ tag → Gitea release
#   → 上传资产 → 下载校验 SHA。
#
# 设计要点（踩过的坑全固化进来）：
#   * token 从 `git remote get-url origin` 解析，绝不硬编码（与 remotes 一致）；GITEA_TOKEN 可覆盖。
#   * push 前确保 http.version=HTTP/1.1 + postBuffer=524288000（EdgeOne HTTP/2 大 POST 必挂）。
#   * Gitea release 先 GET /releases/tags/<tag>：404 才创建（target_commitish=分支名），已存在则 PATCH draft:false（避免 409 "Release is has no Tag" = 已有 draft）。
#   * 资产校验下载走公网 /attachments/{uuid}（browser_download_url 是 localhost:3000，外网不可达）。
#   * install.sh + cli/tokenclock 两分支字节一致：在 main 上编辑，再 `git checkout main --` 拷到 normal。
#   * gzip -n 去 mtime/名，tarball 可复现（SHA 仍以实际上传那份为准 pin）。
#   * bash 3.2 兼容（与 install.sh / tokenclock 一致：无关联数组，用 case）。
#
# 用法：
#   scripts/release.sh v1.3.0              # 发版 v1.3.0（默认双变体）
#   scripts/release.sh 1.3.0 --dry-run     # 干跑：构建+tar+SHA+显示 diff，但不 commit/push/release
#   scripts/release.sh v1.3.0 --only normal # 只发 normal（glass 沿用旧二进制）
#   scripts/release.sh v1.3.0 --skip-build  # 跳过构建，复用已有 .build 产物（调试用）
#
set -uo pipefail

# ─────────────────────────── 配置 ───────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BR_GLASS="main"        # glass 变体所在分支（.v26）
BR_NORMAL="normal"     # normal 变体所在分支（.v12）
GITEA_HOST="gitea.nxc8335.cloud"
GITEA_OWNER="nxc8335"
GITEA_REPO="TokenClock"
API="https://${GITEA_HOST}/api/v1/repos/${GITEA_OWNER}/${GITEA_REPO}"

# 构建配方（与 memory 记录一致）：
#   normal(.v12) 触发 Swift 回退库 → CLT 缺 x86_64 切片 → 必须 Xcode-beta 工具链 + CLT 26 SDK
#   glass(.v26)  不触发回退库 + 26 SDK 里 @State 还是属性包装器 → CLT 26 SDK 直编
XCODE_BETA="/Users/neo/Downloads/Xcode-beta.app/Contents/Developer"
CLT26_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"

# ─────────────────────────── 辅助 ───────────────────────────
C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_CYAN=$'\033[1;36m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
[ -t 1 ] || { C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_DIM=''; C_RESET=''; }

die()  { printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }
say()  { printf '%s\n' "$*"; }
# 注意：step/info/ok/warn 走 stderr —— build_variant()/upload_asset() 用 $() 捕获返回值
# （末行 echo "$bin" / echo "$uuid"），若进度打到 stdout 会被一起吞进 BIN_/UUID_ 变量
# （曾导致 BIN_GLASS 变成多行垃圾 → tar "File name too long"）。say() 是最终结果，留 stdout。
step() { printf '\n%s━━ %s ━━%s\n' "$C_CYAN" "$*" "$C_RESET" >&2; }
info() { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_RESET" >&2; }
ok()   { printf '  %s✓ %s%s\n' "$C_GREEN" "$*" "$C_RESET" >&2; }
warn() { printf '  %s⚠ %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }

# 从 remote URL 解析 token（形如 https://user:TOKEN@host/...）；GITEA_TOKEN 优先。
resolve_token() {
  if [ -n "${GITEA_TOKEN:-}" ]; then echo "$GITEA_TOKEN"; return; fi
  local url; url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  local t; t="${url#*://}"; t="${t#*:}"; t="${t%%@*}"
  [ -n "$t" ] || die "无法从 origin remote 解析 token，设 GITEA_TOKEN 环境变量"
  echo "$t"
}

# 归一化版本号为 vX.Y.Z
norm_version() {
  local v="$1"
  [[ "$v" == v* ]] || v="v$v"
  echo "$v"
}

# 在 REPO_ROOT 执行 git
gc() { git -C "$REPO_ROOT" "$@"; }

# ─────────────────────────── 参数解析 ───────────────────────────
VERSION=""
DRY_RUN=0
SKIP_BUILD=0
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)     DRY_RUN=1 ;;
    --skip-build)  SKIP_BUILD=1 ;;
    --only)        shift; ONLY="$1"; [ "$ONLY" = "normal" ] || [ "$ONLY" = "glass" ] || die "--only 只接受 normal|glass" ;;
    -h|--help)
      sed -n '3,30p' "$0"; exit 0 ;;
    -*) die "未知参数: $1" ;;
    *)  [ -z "$VERSION" ] || die "版本号只能给一个（已有 ${VERSION}）"; VERSION="$(norm_version "$1")" ;;
  esac
  shift
done

[ -n "$VERSION" ] || die "用法: scripts/release.sh <version> [--dry-run] [--only normal|glass] [--skip-build]"
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号格式应为 vX.Y.Z（得到 ${VERSION}）"

# 只发一个变体时，另一个的 SHA 保持不变
DO_GLASS=1; DO_NORMAL=1
[ "$ONLY" = "normal" ] && DO_GLASS=0
[ "$ONLY" = "glass" ]  && DO_NORMAL=0

[ "$DRY_RUN" = 1 ] && warn "DRY-RUN：将构建+tar+SHA 并显示 diff，但不 commit / push / 发 release"

cd "$REPO_ROOT" || die "进不了 $REPO_ROOT"

# ─────────────────────────── 预检 ───────────────────────────
step "预检"
ORIG_BRANCH="$(gc branch --show-current)" || die "不在 git 仓库"
[ -n "$ORIG_BRANCH" ] || die "处于 detached HEAD，先 checkout 一个分支"
info "起始分支: $ORIG_BRANCH"

# 任何退出（含 die）都恢复起始分支 —— 否则构建中 die 会把仓库留在 main/normal 上。
trap 'gc checkout "$ORIG_BRANCH" --quiet 2>/dev/null || true' EXIT

# 两分支工作树必须干净（.build 是 gitignored，不影响）
for b in "$BR_GLASS" "$BR_NORMAL"; do
  dirty="$(gc -C "$REPO_ROOT" status --porcelain 2>/dev/null)"
  # status 反映当前分支；切换到各分支后再验。这里先验当前。
done
[ -z "$(gc status --porcelain)" ] || die "工作树不干净，先 commit/stash：\n$(gc status --porcelain)"

gc fetch origin --quiet || die "fetch 失败"

[ "$DO_NORMAL" = 1 ] && { (DEVELOPER_DIR="${XCODE_BETA}" xcrun --find swift >/dev/null 2>&1) || die "找不到 Xcode-beta 的 swift（normal 构建需要 Xcode universal 回退库）：${XCODE_BETA}"; }
[ -d "$CLT26_SDK" ] || die "找不到 CLT 26 SDK: $CLT26_SDK"

TOKEN="$(resolve_token)"
ok "token 已解析（${TOKEN:0:8}…）"

# --only 仅用于给【已存在】的 release 补传某一变体。全新版本号用 --only 会让被跳过的
# 变体在新 release 里缺席 tarball → installer 下载该变体时 404（脚本自己在下方上传段注释里
# 也标注了这坑）。这里提前挡住，避免静默产出残缺 release。
if [ -n "$ONLY" ]; then
  only_code="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: token $TOKEN" "$API/releases/tags/$VERSION" 2>/dev/null || true)"
  if [ "$only_code" != "200" ]; then
    die "--only 不能用于全新版本号：$VERSION 的 release 当前不存在（http=$only_code）。全新版本号必须双变体都发（去掉 --only），否则另一变体 tarball 缺席 → installer 404。--only 仅适合给已存在的 release 补传某一变体。"
  fi
  ok "--only=$ONLY：目标 release 已存在（http=$only_code），仅补传 $ONLY 变体（另一变体沿用既有资产）"
fi

# 确保 push 过 EdgeOne 的 HTTP/1.1 修复（幂等）
gc config http.version HTTP/1.1
gc config http.postBuffer 524288000
ok "git http.version=HTTP/1.1, postBuffer=524288000"

# ─────────────────────────── 构建 ───────────────────────────
# build_variant <branch> <recipe-tag>  → 产物落到 .build/release/TokenClock（fat）
build_variant() {
  local branch="$1" recipe="$2" out
  step "构建 ${branch}（配方: ${recipe}）"
  gc checkout "$branch" --quiet || die "checkout $branch 失败"
  [ -z "$(gc status --porcelain)" ] || die "$branch 工作树不干净"

  local build_env=()
  case "$recipe" in
    glass)
      build_env=(env "SDKROOT=$CLT26_SDK")
      info "SDKROOT=$CLT26_SDK swift build（CLT-only，.v26 不触发回退库）" ;;
    normal)
      build_env=(env "DEVELOPER_DIR=$XCODE_BETA" "SDKROOT=$CLT26_SDK")
      info "DEVELOPER_DIR=Xcode-beta SDKROOT=${CLT26_SDK}（.v12 触发回退库，需 Xcode universal 切片）" ;;
  esac

  if [ "$SKIP_BUILD" = 1 ]; then
    warn "--skip-build：复用已有 .build 产物"
  else
    "${build_env[@]}" swift build -c release --arch arm64 --arch x86_64 >&2 || die "$branch 构建失败"
  fi

  # 定位 fat 产物：SwiftPM 6.4 多架构产物落在 .build/out/Products/Release/TokenClock，
  # 但路径随 SwiftPM 版本/构建模式变 —— 通用法：在 .build 下找含 arm64+x86_64 的 TokenClock
  # （排除 .dSYM 里的 DWARF 副本，它也是 fat 但不是可执行产物）。
  local bin=""
  while IFS= read -r cand; do
    case "$cand" in *.dSYM*) continue ;; esac
    local archs; archs="$(lipo -info "$cand" 2>/dev/null)" || continue
    if echo "$archs" | grep -q 'x86_64' && echo "$archs" | grep -q 'arm64'; then
      bin="$cand"; break
    fi
  done < <(find .build -type f -name TokenClock 2>/dev/null)

  # 兜底：旧 SwiftPM 可能只产出单架构切片 → 找两个切片 lipo 合并
  if [ -z "$bin" ]; then
    local a64 x86
    a64="$(find .build -type f -name TokenClock ! -path '*.dSYM*' 2>/dev/null | while IFS= read -r f; do lipo -info "$f" 2>/dev/null | grep -q arm64 && { echo "$f"; break; }; done)"
    x86="$(find .build -type f -name TokenClock ! -path '*.dSYM*' 2>/dev/null | while IFS= read -r f; do lipo -info "$f" 2>/dev/null | grep -q x86_64 && { echo "$f"; break; }; done)"
    [ -n "$a64" ] && [ -n "$x86" ] || die "找不到 universal 产物，也凑不齐 arm64+x86_64 切片"
    warn "未找到现成 fat 产物，lipo 合并 $(basename "$a64") + $(basename "$x86")"
    bin=".build/release-TokenClock-fat"
    lipo -create "$a64" "$x86" -output "$bin" || die "lipo 合并失败"
  fi
  ok "universal 产物: ${bin}（$(lipo -info "$bin" 2>/dev/null | sed 's/.*: //')）"
  echo "$bin"
}

SHA_NORMAL=""; SHA_GLASS=""
BIN_NORMAL=""; BIN_GLASS=""

if [ "$DO_NORMAL" = 1 ]; then
  BIN_NORMAL="$(build_variant "$BR_NORMAL" normal)"
  # tar 到固定路径，gzip -n 去时间戳。
  # normal 分支有资源 bundle（Package.swift .copy("Resources/glass_disc.png") → TokenClock_TokenClock.bundle），
  # 必须随二进制一起分发——否则预编译用户切 .glass 主题时 Bundle.module 找不到 bundle 而 fatalError
  # （install.sh 已有把 bundle 部署到二进制旁的逻辑，缺的只是历史 tarball 里没带它）。
  NORMAL_PKG="TokenClock"
  [ -d "$(dirname "$BIN_NORMAL")/TokenClock_TokenClock.bundle" ] && NORMAL_PKG="TokenClock TokenClock_TokenClock.bundle"
  tar -C "$(dirname "$BIN_NORMAL")" -cf /tmp/tc-release-normal.tar $NORMAL_PKG || die "normal tar 失败: $BIN_NORMAL"
  gzip -n -f /tmp/tc-release-normal.tar
  SHA_NORMAL="$(shasum -a 256 /tmp/tc-release-normal.tar.gz | cut -d' ' -f1)"
  [ -n "$SHA_NORMAL" ] || die "normal SHA 为空（tarball 未生成: $BIN_NORMAL）"
  ok "normal tarball: /tmp/tc-release-normal.tar.gz  SHA=${SHA_NORMAL:0:16}…"
fi
if [ "$DO_GLASS" = 1 ]; then
  BIN_GLASS="$(build_variant "$BR_GLASS" glass)"
  # glass（main）Package.swift 无 resources → 不产 bundle，GLASS_PKG 仅 TokenClock；
  # 保留 bundle 条件以备将来给 glass 加资源时自动随包分发。
  GLASS_PKG="TokenClock"
  [ -d "$(dirname "$BIN_GLASS")/TokenClock_TokenClock.bundle" ] && GLASS_PKG="TokenClock TokenClock_TokenClock.bundle"
  tar -C "$(dirname "$BIN_GLASS")" -cf /tmp/tc-release-glass.tar $GLASS_PKG || die "glass tar 失败: $BIN_GLASS"
  gzip -n -f /tmp/tc-release-glass.tar
  SHA_GLASS="$(shasum -a 256 /tmp/tc-release-glass.tar.gz | cut -d' ' -f1)"
  [ -n "$SHA_GLASS" ] || die "glass SHA 为空（tarball 未生成: $BIN_GLASS）"
  ok "glass tarball:  /tmp/tc-release-glass.tar.gz  SHA=${SHA_GLASS:0:16}…"
fi

# ─────────────────────────── 读旧 pin → 决定哪些变了 ───────────────────────────
step "对比 install.sh 旧 pin"
gc checkout "$BR_GLASS" --quiet
OLD_NORMAL="$(grep -oE 'normal\) echo "[a-f0-9]{64}"' cli/install.sh | grep -oE '[a-f0-9]{64}')"
OLD_GLASS="$(grep -oE 'glass\)  echo "[a-f0-9]{64}"' cli/install.sh | grep -oE '[a-f0-9]{64}')"
OLD_TAG="$(grep -oE 'RELEASE_TAG="\$\{TOKENCLOCK_RELEASE_TAG:-v[0-9.]+' cli/install.sh | grep -oE 'v[0-9.]+')"

info "旧: tag=$OLD_TAG  normal=${OLD_NORMAL:0:12}…  glass=${OLD_GLASS:0:12}…"
info "新: tag=$VERSION  normal=${SHA_NORMAL:-（沿用）}  glass=${SHA_GLASS:-（沿用）}"

# 实际要写进 install.sh 的 SHA（没重建的沿用旧值）
NEW_NORMAL="${SHA_NORMAL:-$OLD_NORMAL}"
NEW_GLASS="${SHA_GLASS:-$OLD_GLASS}"

NORMAL_CHANGED=0; GLASS_CHANGED=0
[ "${SHA_NORMAL:-}" != "" ] && [ "$SHA_NORMAL" != "$OLD_NORMAL" ] && NORMAL_CHANGED=1
[ "${SHA_GLASS:-}"  != "" ] && [ "$SHA_GLASS"  != "$OLD_GLASS"  ] && GLASS_CHANGED=1
[ "$NORMAL_CHANGED" = 1 ] && ok "normal SHA 变更 → 将更新 pin + 重传资产"
[ "$GLASS_CHANGED"  = 1 ] && ok "glass SHA 变更  → 将更新 pin + 重传资产"

# SHA 与 tag 都没变时，不能直接 exit 0 —— 上次构建/发版可能中途失败（release 没建或资产不全），
# 这种"重跑"恰恰最需要继续走发布步骤。只有当 release 已存在且两变体资产齐全时才真的无事可做。
if [ "$NORMAL_CHANGED" = 0 ] && [ "$GLASS_CHANGED" = 0 ] && [ "$VERSION" = "$OLD_TAG" ]; then
  rel_code="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: token $TOKEN" "$API/releases/tags/$VERSION" 2>/dev/null || true)"
  if [ "$rel_code" = "200" ]; then
    n_assets="$(curl -fsSL -H "Authorization: token $TOKEN" "$API/releases/tags/$VERSION" 2>/dev/null \
      | python3 -c 'import json,sys; print(len((json.load(sys.stdin) or {}).get("assets",[])))' 2>/dev/null || echo 0)"
    if [ "${n_assets:-0}" -ge 2 ]; then
      warn "无任何变更（SHA 与 tag 都没变）且 release 资产齐全（$n_assets 个）—— 退出"
      exit 0
    fi
    warn "SHA 未变但 release 资产数=${n_assets:-0}（<2），上次可能中途失败 —— 继续走发布步骤补齐"
  else
    warn "SHA 未变但 release 不存在（http=$rel_code）—— 继续走发布步骤创建 release"
  fi
fi

if [ "$DRY_RUN" = 1 ]; then
  step "DRY-RUN diff（install.sh / tokenclock 预览）"
  info "RELEASE_TAG: $OLD_TAG → $VERSION"
  info "normal SHA : ${OLD_NORMAL:0:16}… → ${NEW_NORMAL:0:16}…"
  info "glass SHA  : ${OLD_GLASS:0:16}… → ${NEW_GLASS:0:16}…"
  info "CLI_VERSION: → $VERSION"
  gc checkout "$ORIG_BRANCH" --quiet
  say "\n${C_GREEN}干跑完成，未做任何写操作。${C_RESET}"
  exit 0
fi

# ─────────────────────────── 改 install.sh + tokenclock（在 main 上）───────────────────────────
step "更新 install.sh / cli/tokenclock（编辑于 ${BR_GLASS}）"
gc checkout "$BR_GLASS" --quiet

# RELEASE_TAG（文件内唯一形如 :-vX.Y.Z} 的片段）
perl -pi -e 's/(:-)v[0-9]+\.[0-9]+\.[0-9]+\}/${1}'"${VERSION}"'}/' cli/install.sh
# glass SHA（glass)  echo "<hex>"）
perl -pi -e 's/(glass\)\s+echo ")[a-f0-9]{64}(")/${1}'"$NEW_GLASS"'${2}/' cli/install.sh
# normal SHA（normal) echo "<hex>"）
perl -pi -e 's/(normal\)\s+echo ")[a-f0-9]{64}(")/${1}'"$NEW_NORMAL"'${2}/' cli/install.sh
# cli/tokenclock CLI_VERSION（注意：tokenclock 里 CLI_VERSION 不带 v 前缀）
perl -pi -e 's/^CLI_VERSION="v?[0-9.]+"/CLI_VERSION="'"${VERSION#v}"'"/' cli/tokenclock

bash -n cli/install.sh || die "install.sh 语法错误"
bash -n cli/tokenclock || die "tokenclock 语法错误"

# 回读校验
read_tag="$(grep -oE 'RELEASE_TAG="\$\{TOKENCLOCK_RELEASE_TAG:-v[0-9.]+' cli/install.sh | grep -oE 'v[0-9.]+')"
read_normal="$(grep -oE 'normal\) echo "[a-f0-9]{64}"' cli/install.sh | grep -oE '[a-f0-9]{64}')"
read_glass="$(grep -oE 'glass\)  echo "[a-f0-9]{64}"' cli/install.sh | grep -oE '[a-f0-9]{64}')"
read_cli="$(grep -oE 'CLI_VERSION="[0-9.]+"' cli/tokenclock | grep -oE '[0-9.]+')"
[ "$read_tag" = "$VERSION" ] || die "回读 RELEASE_TAG 不符: $read_tag"
[ "$read_normal" = "$NEW_NORMAL" ] || die "回读 normal SHA 不符"
[ "$read_glass" = "$NEW_GLASS" ] || die "回读 glass SHA 不符"
[ "v$read_cli" = "$VERSION" ] || die "回读 CLI_VERSION 不符: $read_cli"
ok "install.sh + tokenclock 已更新并通过语法/回读校验"

gc add cli/install.sh cli/tokenclock
gc commit --quiet -m "chore(installer): ${VERSION} —— 同步变体 SHA（normal=${NEW_NORMAL:0:8}… glass=${NEW_GLASS:0:8}…）

由 scripts/release.sh 生成。" || die "main commit 失败"
ok "$BR_GLASS 已 commit"

# ─────────────────────────── 同步到 normal 分支（字节一致）───────────────────────────
step "同步到 $BR_NORMAL"
gc checkout "$BR_NORMAL" --quiet
gc checkout "$BR_GLASS" -- cli/install.sh cli/tokenclock || die "从 main 拷贝 install.sh/tokenclock 失败"
gc commit --quiet -m "chore(installer): ${VERSION} —— 与 main 分支同步（变体 SHA）

由 scripts/release.sh 生成。" || { warn "normal 无变化（跳过 commit）"; }
ok "$BR_NORMAL 已同步"
[ -z "$(gc status --porcelain)" ] || die "normal 工作树仍有未提交内容:\n$(gc status --porcelain)"

# ─────────────────────────── push 两分支 ───────────────────────────
step "push $BR_GLASS + $BR_NORMAL"
push_one() {
  local b="$1" i
  for i in 1 2 3 4 5 6; do
    if gc push origin "$b" 2>&1; then ok "push $b 成功（第 $i 次尝试）"; return 0; fi
    warn "push $b 第 $i 次失败，退避 $((i*2))s…"
    sleep $((i*2))
  done
  die "push $b 6 次均失败"
}
push_one "$BR_GLASS"
push_one "$BR_NORMAL"

# ─────────────────────────── tag ───────────────────────────
step "打 tag $VERSION"
gc checkout "$BR_GLASS" --quiet
if gc rev-parse "$VERSION" >/dev/null 2>&1; then
  warn "tag $VERSION 已存在，跳过创建"
else
  gc tag -a "$VERSION" -m "Release ${VERSION}" || die "打 tag 失败"
  gc push origin "$VERSION" 2>&1 || die "push tag 失败"
  ok "tag $VERSION 已推送"
fi

# ─────────────────────────── Gitea release ───────────────────────────
step "Gitea release"
api() { curl -fsSL --retry 6 --retry-delay 2 --retry-all-errors -H "Authorization: token $TOKEN" "$@"; }
api_post() { curl -fsSL --retry 3 --retry-delay 2 -X POST -H "Authorization: token $TOKEN" "$@"; }

# 先 GET：404 创建，已存在则取 id（可能 draft）
RELEASE_ID=""
existing="$(api -o /tmp/tc-rel.json -w '%{http_code}' "$API/releases/tags/$VERSION" 2>/dev/null || true)"
if [ "$existing" = "404" ] || [ "$existing" = "" ]; then
  info "release 不存在，创建（target_commitish=${BR_GLASS}）"
  api_post "$API/releases" \
    -H 'Content-Type: application/json' \
    -d "{\"tag_name\":\"$VERSION\",\"target_commitish\":\"$BR_GLASS\",\"name\":\"$VERSION\",\"body\":\"TokenClock $VERSION\",\"draft\":false,\"prerelease\":false}" \
    -o /tmp/tc-rel-create.json 2>&1 || die "创建 release 失败"
  RELEASE_ID="$(python3 -c 'import json;print(json.load(open("/tmp/tc-rel-create.json"))["id"])' 2>/dev/null)"
else
  RELEASE_ID="$(python3 -c 'import json;print(json.load(open("/tmp/tc-rel.json"))["id"])' 2>/dev/null)"
  info "release 已存在 id=${RELEASE_ID}，确保 draft=false + 更新 body"
  api -X PATCH "$API/releases/$RELEASE_ID" \
    -H 'Content-Type: application/json' \
    -d "{\"body\":\"TokenClock $VERSION\",\"draft\":false}" -o /dev/null 2>&1 || warn "PATCH release 失败（可忽略）"
fi
[ -n "$RELEASE_ID" ] || die "未拿到 release id（检查 /tmp/tc-rel*.json）"
ok "release id=$RELEASE_ID"

# ─────────────────────────── 上传资产 ───────────────────────────
upload_asset() {
  local name="$1" file="$2" aid
  # 先查同名资产是否已存在（重传场景），有则删
  api "$API/releases/$RELEASE_ID/assets" -o /tmp/tc-assets.json 2>/dev/null || true
  aid="$(python3 -c "
import json,sys
try:
    for a in json.load(open('/tmp/tc-assets.json')):
        if a['name']=='$name': print(a['id'])
except: pass
" 2>/dev/null)"
  if [ -n "$aid" ]; then
    warn "$name 已存在（asset id=${aid}），删除后重传"
    api -X DELETE "$API/releases/$RELEASE_ID/assets/$aid" -o /dev/null 2>&1 || warn "删除旧 $name 失败"
  fi
  api_post "$API/releases/$RELEASE_ID/assets?name=$name" \
    -H 'Content-Type: application/gzip' --data-binary "@$file" -o /tmp/tc-up.json 2>&1 || die "上传 $name 失败"
  local uuid; uuid="$(python3 -c 'import json;print(json.load(open("/tmp/tc-up.json"))["uuid"])' 2>/dev/null)"
  ok "$name 已上传（uuid=${uuid:0:8}…）"
  echo "$uuid"
}

# 列出当前资产 uuid（用于校验下载）
asset_uuid() {
  local name="$1"
  api "$API/releases/$RELEASE_ID/assets" -o /tmp/tc-assets2.json 2>/dev/null || true
  python3 -c "
import json
for a in json.load(open('/tmp/tc-assets2.json')):
    if a['name']=='$name': print(a['uuid'])
" 2>/dev/null
}

UUID_NORMAL=""; UUID_GLASS=""
# 新建 release 必须把所有已构建资产都传上去 —— 不能因 SHA 未变就跳过
# （否则只改一变体时，新 release 会缺失另一变体的 tarball，installer 下载会 404）。
# 仅 --only 跳过的那个变体才沿用既有 release 资产。
if [ "$DO_NORMAL" = 1 ]; then
  UUID_NORMAL="$(upload_asset TokenClock-normal-universal.tar.gz /tmp/tc-release-normal.tar.gz)"
else
  info "normal 本次未构建（--only glass），沿用既有 release 资产"
fi
if [ "$DO_GLASS" = 1 ]; then
  UUID_GLASS="$(upload_asset TokenClock-glass-universal.tar.gz /tmp/tc-release-glass.tar.gz)"
else
  info "glass 本次未构建（--only normal），沿用既有 release 资产"
fi

# ─────────────────────────── 校验下载 SHA ───────────────────────────
step "下载校验"
verify() {
  local name="$1" want="$2" uuid got
  [ -n "$want" ] || return 0
  uuid="$(asset_uuid "$name")"
  [ -n "$uuid" ] || die "$name 找不到 uuid，无法校验"
  for i in 1 2 3 4 5 6; do
    if curl -fsSL --max-time 120 -H "Authorization: token $TOKEN" \
        "https://${GITEA_HOST}/attachments/$uuid" -o /tmp/tc-verify.tar.gz 2>/dev/null; then break; fi
    warn "$name 下载第 $i 次失败，退避…"; sleep $((i*2))
  done
  got="$(shasum -a 256 /tmp/tc-verify.tar.gz | cut -d' ' -f1)"
  if [ "$got" = "$want" ]; then ok "$name SHA 匹配 pin ✓"; else die "$name SHA 不符！want=$want got=$got"; fi
}
verify TokenClock-normal-universal.tar.gz "$NEW_NORMAL"
verify TokenClock-glass-universal.tar.gz  "$NEW_GLASS"

# ─────────────────────────── 收尾 ───────────────────────────
gc checkout "$ORIG_BRANCH" --quiet 2>/dev/null || warn "恢复 $ORIG_BRANCH 失败（手动 checkout）"

step "${C_GREEN}✓ 发版完成${C_RESET}"
say "  tag        : $VERSION"
say "  release id : $RELEASE_ID"
say "  normal SHA : ${NEW_NORMAL:0:16}…${NORMAL_CHANGED:+  ${C_YELLOW}(新)${C_RESET}}"
say "  glass SHA  : ${NEW_GLASS:0:16}…${GLASS_CHANGED:+  ${C_YELLOW}(新)${C_RESET}}"
say "  one-liner  : curl -fsSL \"${API}/raw/cli/install.sh?ref=${BR_GLASS}\" | bash"
