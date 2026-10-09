#!/usr/bin/env bash
# =====================================================================
# tonight.sh — Effiq Pilot 003 pod runner (hands-only entry point)
#
# 操作员唯一入口：每晚（或每次开机）执行一次：
#     bash tonight.sh
#
# 行为：
#   1. 克隆或更新公开仓库 effiq/pilot003（脚本与配置的唯一来源）。
#   2. 读取仓库内 STAGE 文件，决定本阶段运行哪个 stage 脚本。
#   3. 运行该 stage；stage 脚本自行管理断点续跑与 COMPLETE 记账。
#   4. 若 stage 成功收尾（exit 0 或 2，2 = 科学结论 FAIL 但流程完整），
#      将运行产物（runs/ 目录）提交并推送回公开仓库。
#      推送前做 token/密钥泄漏扫描，命中即拒绝推送。
#
# 私有件纪律（宪法三层披露制，Pilot 003 起实施）：
#   - ~/pilot-env/arms-recipes.json（闸门层完整配方）永不进仓库；
#     stage 脚本只把配方 sha256 写进公开日志。
#   - ~/pilot-env/openrouter.key、GitHub PAT 永不进仓库、永不发给 AI。
#   - $CKPT_ROOT/recipes-local.jsonl（配方全文本地副本）永不被推送。
#
# 环境要求（pod）：
#   - GPU pod（L40S 48GB 级），PyTorch/vLLM 镜像，llmcompressor 已装
#   - ~/pilot-env/github.token  (repo 推送用 PAT, chmod 600)
#   - ~/pilot-env/openrouter.key (OpenRouter API key, chmod 600)
#   - ~/pilot-env/arms-recipes.json (私有配方文件, chmod 600)
#   - 环境变量可选：EFFIQ_HOME（默认 $HOME/effiq）
#
# 本脚本是公开件：按"必然泄露"标准书写，不含任何秘密。
# =====================================================================
set -euo pipefail

REPO_URL="https://github.com/effiq/pilot003.git"
EFFIQ_HOME="${EFFIQ_HOME:-$HOME/effiq}"
REPO_DIR="$EFFIQ_HOME/pilot003"
ENV_DIR="$HOME/pilot-env"
TOKEN_FILE="$ENV_DIR/github.token"
STAGE_FILE="$REPO_DIR/STAGE"

say() { echo "[tonight $(date -u +%H:%M:%S)] $*"; }
die() { echo "FATAL: $*" >&2; exit 1; }

# ---------- 0. 私有件在位检查（不读内容，只查存在与权限） ----------
[ -f "$TOKEN_FILE" ] || die "missing $TOKEN_FILE (GitHub PAT, chmod 600)"
[ -f "$ENV_DIR/openrouter.key" ] || die "missing $ENV_DIR/openrouter.key"
[ -f "$ENV_DIR/arms-recipes.json" ] || die "missing $ENV_DIR/arms-recipes.json (私有配方文件，未就位不能开工)"
for f in "$TOKEN_FILE" "$ENV_DIR/openrouter.key" "$ENV_DIR/arms-recipes.json"; do
  perm=$(stat -c '%a' "$f")
  [ "$perm" = "600" ] || die "$f permission is $perm, must be 600: chmod 600 $f"
done

# ---------- 1. 克隆或更新仓库 ----------
mkdir -p "$EFFIQ_HOME"
if [ ! -d "$REPO_DIR/.git" ]; then
  say "cloning $REPO_URL"
  git clone "$REPO_URL" "$REPO_DIR"
else
  say "pulling latest"
  git -C "$REPO_DIR" fetch origin
  git -C "$REPO_DIR" reset --hard origin/main
fi

[ -f "$STAGE_FILE" ] || die "STAGE file missing in repo"
STAGE=$(tr -d '[:space:]' < "$STAGE_FILE")
[ -n "$STAGE" ] || die "STAGE file empty"
SCRIPT="$REPO_DIR/stages/$STAGE.sh"
[ -f "$SCRIPT" ] || die "stage script not found: stages/$STAGE.sh"
say "STAGE=$STAGE"

# ---------- 2. 运行 stage ----------
set +e
bash "$SCRIPT"
rc=$?
set -e
say "stage exit code: $rc"

# exit 0 = PASS 收尾；exit 2 = 科学 FAIL 收尾（流程完整，结论为否）；
# 其余 = 中断/错误（断点已记账，下次重跑续上），不推送之外的额外动作。
if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
  say "stage did not complete (rc=$rc); checkpoint saved; re-run tonight.sh to resume"
  exit "$rc"
fi

# ---------- 3. 泄漏扫描（推送前硬闸） ----------
# 扫描对象：仓库内即将提交的文本文件。命中任一模式即拒绝推送。
scan_for_secrets() {
  local hits=0
  # GitHub PAT 形态 / OpenRouter key 形态 / 通用 sk- 长串
  local patterns='ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-or-v1-[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{40,}'
  if git -C "$REPO_DIR" grep -nI -E "$patterns" -- . ':(exclude).git' >/dev/null 2>&1; then
    git -C "$REPO_DIR" grep -nI -E "$patterns" -- . ':(exclude).git' | head -20 >&2 || true
    hits=1
  fi
  # 私有配方文件本体（按文件名与 JSON 特征）混入仓库 = 闸门层泄漏。
  # 注意：stages/*.sh 是公开件，本就含修饰器类名（SmoothQuantModifier 等），
  # 冻结参数值只在 ~/pilot-env/arms-recipes.json——所以这里查的是
  # "配方数据文件"而非类名：文件名出现、或 JSON 里带 frozen 参数指纹。
  if git -C "$REPO_DIR" ls-files | grep -E '(^|/)arms-recipes\.json$|recipes-local\.jsonl$' >/dev/null 2>&1; then
    echo "LEAK SCAN: private recipe file tracked in repo:" >&2
    git -C "$REPO_DIR" ls-files | grep -E '(^|/)arms-recipes\.json$|recipes-local\.jsonl$' >&2 || true
    hits=1
  fi
  # ("composed_from" 是公开字段——recipes_executed.jsonl 合法携带，不能当指纹)
  if git -C "$REPO_DIR" grep -nI -E '"smoothing_strength"|"scheme_overrides"' -- . ':(exclude).git' ':(exclude)stages/' ':(exclude)tonight.sh' >/dev/null 2>&1; then
    echo "LEAK SCAN: private recipe parameter fingerprints found outside stages/:" >&2
    git -C "$REPO_DIR" grep -nI -E '"smoothing_strength"|"scheme_overrides"' -- . ':(exclude).git' ':(exclude)stages/' ':(exclude)tonight.sh' | head -20 >&2 || true
    hits=1
  fi
  return "$hits"
}

# ---------- 4. 提交并推送 ----------
cd "$REPO_DIR"
git add -A
if git diff --cached --quiet; then
  say "nothing new to commit"
else
  if ! scan_for_secrets; then
    die "LEAK SCAN FAILED — refusing to push. Inspect hits above, clean, re-run."
  fi
  msg="pilot003 $STAGE run artifacts $(date -u +%Y-%m-%dT%H:%M:%SZ) rc=$rc"
  git -c user.name="effiq-pod" -c user.email="pod@effiq.invalid" commit -m "$msg"
  token=$(tr -d '[:space:]' < "$TOKEN_FILE")
  # 用一次性 remote URL 推送，不把 token 写进 git config
  push_url="https://x-access-token:${token}@github.com/effiq/pilot003.git"
  git push "$push_url" HEAD:main
  unset token push_url
  say "pushed: $msg"
fi

say "done (stage rc=$rc)"
exit 0
