#!/usr/bin/env bash
# =============================================================================
# Pilot 003 — STAGE 08: RED-DOT CONFIRM (phase 2 of 2 — the single shot)
#
# Pre-registered in PREREG-ADDENDUM-02 (frozen before execution). The winning
# lever configuration from stage-07 screening gets ONE confirmation attempt
# on the frozen 150-item set against the archived BF16 reference outputs.
#
# Frozen rules:
#   - Anchors reused BY HASH from the sealed Pilot 002 stage-05 archive:
#     frozen_set (728b2f83…), gen_A BF16 reference (16df35cc…), blind_map
#     (684aea8d…). The blind map is REUSED, so every judge sees the same
#     presentation order as the original gate.
#   - Candidate arm C = the stage-07 winner (winner.json, archived). Its
#     recipe is resolved from the pod-local custody chain and its sha256
#     must equal the value recorded at screening time.
#   - Judge prompt byte-identical to stage 05; Amendment-01 mechanics
#     (reasoning excluded; null/empty content = error; max_tokens 1024).
#   - Panel (frozen, ADDENDUM-02 §panel): SIZE 3. The original red-dot
#     judge (deepseek/deepseek-chat-v3-0324) is MANDATORY — a repair that
#     only works after benching the referee is not a repair. If it is
#     unreachable -> REFUSED (owner decision). The other two seats are
#     filled by the first reachable of the declared candidates, which must
#     span >= 2 vendor families (the stage-06 all-DeepSeek caveat is
#     hereby retired by construction).
#   - Quality gate (frozen): per judge, overall delta (C - BF16) >= -0.1
#     AND every axis delta >= -0.1. QUALITY-PASS iff ALL 3 judges pass
#     (worst-judge rule).
#   - Single-shot discipline: this stage runs once. A miss publishes FAIL;
#     a second attempt requires a new pre-registered addendum.
#   - This stage NEVER modifies the sealed Pilot 002 verdicts.
#
# Checkpoint custody: the winner checkpoint is rebuilt from the identical
# frozen recipe. If the rebuild hash differs from the screening build
# (recorded in the stage-07 archive), BOTH hashes are disclosed in the
# verdict (declared deviation; screening numbers are indicative anyway).
#
# Verify entry: bash stages/08-red-dot-confirm.sh --verify <run_dir>
#
# Test hooks (sandbox only): STAGE08_OUT_DIR, STAGE08_SRC05_DIR,
#   STAGE08_SRC07_DIR, STAGE08_SKIP_SERVER, STAGE08_MOCK_BUILD, PORT,
#   OR_BASE_URL, KEY_FILE, MAX_SECONDS, BUDGET_USD, RECIPES_FILE, CKPT_ROOT
# =============================================================================
set -euo pipefail

EFFIQ_HOME="${EFFIQ_HOME:-$HOME/effiq}"
LOGS_DIR="${LOGS_DIR:-$EFFIQ_HOME/pilot-logs}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$EFFIQ_HOME/pilot003}"
DATE_STR="$(date -u +%Y-%m-%d)"
STAGE_NAME="08-red-dot-confirm"

MODEL="Qwen/Qwen2.5-14B-Instruct"
MODEL_REV="cf98f3b3bbb457ad9e2bb7baf9a0125b6b88caa8"   # L1 pinned
VLLM_PINNED="0.31.0"                                   # L1 pinned
GPU_EXPECT="L40S"
MAX_MODEL_LEN=32768
FROZEN_SHA="728b2f8354701a301467afaf52d643d12a679af5c41542bb1701634e4235cf7d"
GENA_SHA="16df35ccad32cc60a5785ce87fa96e325487b66ec3000e3fa04e6479b886c8cd"   # BF16 reference outputs (stage-05 arm A)
BLIND_SHA="684aea8dcc33ce4f88d9aa8644007cdb8ace0e4ff331a124b8c62fe1c7e76392"
N_ITEMS=150
TOL=0.1
PANEL_SIZE=3
ORIG_JUDGE="deepseek/deepseek-chat-v3-0324"            # mandatory red-dot referee
PANEL_REST=(
    "z-ai/glm-4.6|0.43|1.75"
    "deepseek/deepseek-v3.1-terminus|0.27|1.00"
    "deepseek/deepseek-chat-v3.1|0.25|0.95"
)
FALLBACK_PRICE_IN=1.00
FALLBACK_PRICE_OUT=3.00
BOOT_SEED=20261012                                     # descriptive CI, declared
BOOT_N=100000
GEN_CONC=8
MAX_SECONDS="${MAX_SECONDS:-21600}"                    # ~6 h rail (build + gen + judge)
BUDGET_USD="${BUDGET_USD:-6}"                          # judge spend cap (450 rows est. < $2)
KEY_FILE="${KEY_FILE:-$HOME/pilot-env/openrouter-key}"
RECIPES_FILE="${RECIPES_FILE:-$HOME/pilot-env/arms-recipes.json}"
CKPT_ROOT="${CKPT_ROOT:-$HOME/effiq/p003-ckpt}"
PORT="${PORT:-8000}"                                   # env override is a test hook only

note() { printf '\n=== %s ===\n' "$*"; }
die()  { printf '\n\033[1;31m[stage08][ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

set_paths() {
  RUN_DIR="$1"
  FROZEN_JSONL="$RUN_DIR/frozen_set.jsonl"
  GENA_JSONL="$RUN_DIR/gen_A.jsonl"
  BLIND_JSONL="$RUN_DIR/blind_map.jsonl"
  GENC_JSONL="$RUN_DIR/gen_C.jsonl"
  JUDGE_RAW_JSONL="$RUN_DIR/judge_raw_c.jsonl"
  VERDICT_TXT="$RUN_DIR/verdict_c.txt"
  VERDICT_JSON="$RUN_DIR/verdict_c.json"
  CKPT_LOG="$RUN_DIR/checkpoint_confirm.json"
}

# ---------- confirm verdict (recomputable from the archive alone) ----------
run_verdict() {
  RUN_DIR="$RUN_DIR" SRC05_DIR="$SRC05_DIR" JUDGE_RAW_JSONL="$JUDGE_RAW_JSONL" \
  VERDICT_TXT="$VERDICT_TXT" VERDICT_JSON="$VERDICT_JSON" CKPT_LOG="$CKPT_LOG" \
  N_ITEMS="$N_ITEMS" TOL="$TOL" BOOT_SEED="$BOOT_SEED" BOOT_N="$BOOT_N" \
  PANEL_SIZE="$PANEL_SIZE" ORIG_JUDGE="$ORIG_JUDGE" WINNER_JSON="$WINNER_JSON" \
  GIT_REV="$GIT_REV" GEN_CONC="$GEN_CONC" python3 - <<'PY'
import hashlib, json, os, statistics

RUN_DIR = os.environ["RUN_DIR"]
JRAW    = os.environ["JUDGE_RAW_JSONL"]
VERDICTF= os.environ["VERDICT_TXT"]
VERDICTJ= os.environ["VERDICT_JSON"]
N_ITEMS = int(os.environ["N_ITEMS"])
TOL     = float(os.environ["TOL"])
BSEED   = int(os.environ["BOOT_SEED"])
BN      = int(os.environ["BOOT_N"])
PSIZE   = int(os.environ["PANEL_SIZE"])
AXES    = ["correctness", "instruction_following", "clarity"]

def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.exists(p) else "MISSING"

winner = json.load(open(os.environ["WINNER_JSON"]))
lines = ["STAGE 08 VERDICT — RED-DOT CONFIRM (PILOT 003, single-shot confirmation)",
         "question: does the stage-07 winning lever configuration bring the sealed stage-05",
         f"clarity breach (-0.127 vs tolerance {TOL}) back within tolerance on the frozen 150,",
         "under a 3-judge panel that INCLUDES the original red-dot judge?",
         "status: Pilot 003 verdict component; does NOT modify any sealed Pilot 002 verdict",
         f"generation: serving mode, temperature=0, concurrency {os.environ['GEN_CONC']}, natural stopping",
         "blind map reused from the sealed stage-05 archive (identical presentation order)", "",
         f"candidate arm: {winner['arm_id']} (recipe_sha256={str(winner.get('recipe_sha256'))[:16]}…)",
         f"source archive (stage 05, sealed): {os.environ['SRC05_DIR']}",
         f"  frozen_set.jsonl: sha256={sha(os.path.join(RUN_DIR,'frozen_set.jsonl'))}",
         f"  gen_A.jsonl (BF16 reference): sha256={sha(os.path.join(RUN_DIR,'gen_A.jsonl'))}",
         f"  blind_map.jsonl: sha256={sha(os.path.join(RUN_DIR,'blind_map.jsonl'))}",
         f"  gen_C.jsonl (tuned): sha256={sha(os.path.join(RUN_DIR,'gen_C.jsonl'))}",
         f"  judge_raw_c.jsonl: sha256={sha(JRAW)}"]
if os.path.exists(os.environ["CKPT_LOG"]):
    ck = json.load(open(os.environ["CKPT_LOG"]))
    lines.append(f"  confirm checkpoint: sha256={ck['checkpoint_sha256'][:16]}… "
                 f"(screening build: {str(ck.get('screening_checkpoint_sha256'))[:16]}…; "
                 f"{'identical' if ck.get('matches_screening') else 'REBUILT — hash differs, declared deviation'})")
lines.append(f"scripts_rev={os.environ['GIT_REV']}")

frozen = {json.loads(l)["request_id"]: json.loads(l) for l in open(os.path.join(RUN_DIR,"frozen_set.jsonl")) if l.strip()}
rows = [json.loads(l) for l in open(JRAW) if l.strip()] if os.path.exists(JRAW) else []
judges = sorted({r["judge_model"] for r in rows}, key=lambda m: min(i for i, r in enumerate(rows) if r["judge_model"] == m))
lines += ["", f"panel judges ({len(judges)}/{PSIZE}): {', '.join(judges) if judges else '(none)'}",
          f"original red-dot judge present: {os.environ['ORIG_JUDGE'] in judges}",
          f"judged rows: {len(rows)} / {PSIZE * N_ITEMS}"]

per_judge = {m: [r for r in rows if r["judge_model"] == m] for m in judges}
if len(judges) < PSIZE or any(len(per_judge[m]) < N_ITEMS for m in judges):
    lines += ["", "REFUSED: confirmation incomplete — verdict sealed by pre-registration.",
              "Re-run the stage to resume; no verdict is computed on partial data."]
    open(VERDICTF, "w").write("\n".join(lines) + "\n")
    print("\n".join(lines)); raise SystemExit(1)

import numpy as np
report = {}
for m in judges:
    rs = per_judge[m]
    per_item = []
    for r in rs:
        sA = r["scores_r1"] if r["a_is_response_1"] else r["scores_r2"]   # A = BF16 reference
        sC = r["scores_r2"] if r["a_is_response_1"] else r["scores_r1"]   # C = tuned candidate
        per_item.append({a: (sA[a], sC[a]) for a in AXES})
    axis_delta = {a: statistics.mean(sc[a][1] for sc in per_item) - statistics.mean(sc[a][0] for sc in per_item) for a in AXES}
    overall = statistics.mean(statistics.mean(sc[a][1] - sc[a][0] for a in AXES) for sc in per_item)
    gate_ok = overall >= -TOL and all(d >= -TOL for d in axis_delta.values())
    cl = np.array([sc["clarity"][1] - sc["clarity"][0] for sc in per_item])
    rng = np.random.default_rng(BSEED)   # same declared seed for every judge
    means = rng.choice(cl, size=(BN, len(cl)), replace=True).mean(axis=1)
    lo, hi = np.percentile(means, [2.5, 97.5])
    report[m] = dict(axis_delta=axis_delta, overall=overall, gate_ok=gate_ok, ci=(float(lo), float(hi)))
    mA = {a: statistics.mean(sc[a][0] for sc in per_item) for a in AXES}
    mC = {a: statistics.mean(sc[a][1] for sc in per_item) for a in AXES}
    tag = " (original red-dot judge)" if m == os.environ["ORIG_JUDGE"] else ""
    lines += ["", f"[judge: {m}{tag}]"]
    for a in AXES:
        lines.append(f"  {a:22s}: A(bf16)={mA[a]:.3f}  C(tuned)={mC[a]:.3f}  delta={axis_delta[a]:+.3f}")
    lines.append(f"  overall pooled delta (C - A): {overall:+.3f}  ->  per-judge gate: {'PASS' if gate_ok else 'FAIL'}")
    lines.append(f"  [descriptive] clarity delta 95% bootstrap CI: [{lo:+.3f}, {hi:+.3f}] (seed={BSEED})")

allpass = all(report[m]["gate_ok"] for m in judges)
worst = min(judges, key=lambda m: report[m]["overall"])
lines += ["", f"quality gate rule: ALL {PSIZE} judges must pass (worst-judge rule); worst overall: {worst} ({report[worst]['overall']:+.3f})",
          "", f"QUALITY GATE: {'PASS' if allpass else 'FAIL'}" + ("" if allpass else " — the single shot missed; this FAIL is published (a second attempt requires a new pre-registered addendum)"),
          "", "next: stage 09 measures the tuned configuration's performance gate (CI lower bound >= 1.50x).",
          "The Pilot 003 verdict = quality gate AND performance gate.",
          "", "This file is reproducible from the archived logs alone: bash stages/08-red-dot-confirm.sh --verify <run_dir>"]
open(VERDICTF, "w").write("\n".join(lines) + "\n")
json.dump(dict(stage="08-red-dot-confirm", pilot="003", candidate=winner["arm_id"],
               panel=judges, quality_gate="PASS" if allpass else "FAIL",
               per_judge={m: dict(axis_delta=report[m]["axis_delta"], overall=report[m]["overall"],
                                  gate_ok=report[m]["gate_ok"], clarity_ci=list(report[m]["ci"])) for m in judges},
               scripts_rev=os.environ["GIT_REV"]),
          open(VERDICTJ, "w"), indent=2, sort_keys=True)
print("\n".join(lines))
raise SystemExit(0 if allpass else 2)
PY
}

# ---------- --verify ----------
# Declared normalization (machine-local provenance): "source archive" path,
# scripts_rev.
if [ "${1:-}" = "--verify" ]; then
  D="${2:-}"
  [ -n "$D" ] && [ -f "$D/verdict_c.txt" ] || { echo "VERIFY: usage: --verify <run_dir> (no confirm verdict archive found)"; exit 1; }
  note "verify: recomputing confirm verdict from archived logs in $D (no network, no GPU)"
  SRC05_DIR="$D"
  WINNER_JSON="$D/winner.json"
  GIT_REV="verify"
  TMPD="$(mktemp -d)"
  cp "$D"/frozen_set.jsonl "$D"/gen_A.jsonl "$D"/blind_map.jsonl "$D"/gen_C.jsonl "$D"/judge_raw_c.jsonl "$TMPD/" 2>/dev/null || true
  [ -f "$D/checkpoint_confirm.json" ] && cp "$D/checkpoint_confirm.json" "$TMPD/" || true
  set_paths "$TMPD"
  set +e
  run_verdict > /dev/null
  RC=$?
  set -e
  [ "$RC" -eq 0 ] || [ "$RC" -eq 2 ] || { rm -rf "$TMPD"; echo "VERIFY: recompute failed"; exit 1; }
  python3 - "$D" "$TMPD" <<'PY'
import json, re, sys
a, b = sys.argv[1], sys.argv[2]
def norm(t):
    t = re.sub(r"source archive \(stage 05, sealed\): \S+", "source archive: NORMALIZED", t)
    t = re.sub(r"scripts_rev=\S+", "scripts_rev=NORMALIZED", t)
    return t
ta, tb = norm(open(a + "/verdict_c.txt").read()), norm(open(b + "/verdict_c.txt").read())
if ta != tb:
    import difflib
    print("\n".join(list(difflib.unified_diff(ta.splitlines(), tb.splitlines(), lineterm=""))[:20]))
    print("VERIFY: MISMATCH — investigate before trusting the archive", file=sys.stderr); sys.exit(1)
ja = json.load(open(a + "/verdict_c.json")); jb = json.load(open(b + "/verdict_c.json"))
for j in (ja, jb): j.pop("scripts_rev", None)
if ja != jb:
    print("VERIFY: MISMATCH (json) — investigate", file=sys.stderr); sys.exit(1)
print("VERIFY: verdict_c.txt / verdict_c.json identical (declared provenance normalized)")
print("VERIFY: ALL CHECKS PASSED")
PY
  RC=$?
  rm -rf "$TMPD"
  exit $RC
fi

# ---------- run bookkeeping ----------
note "0. run bookkeeping"
GIT_REV=$(git -C "$SCRIPTS_DIR" rev-parse --short=8 HEAD 2>/dev/null || echo nogit)
if [ -n "${STAGE08_OUT_DIR:-}" ]; then
  RUN_DIR="$STAGE08_OUT_DIR"; mkdir -p "$RUN_DIR"
else
  LATEST="$(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null | head -1 || true)"
  if [ -n "$LATEST" ] && [ -f "$LATEST/COMPLETE" ]; then
    echo "STAGE 08 already COMPLETE: $LATEST"
    echo "verdict: $LATEST/verdict_c.txt  (to recompute: bash stages/08-red-dot-confirm.sh --verify $LATEST)"
    exit 0
  fi
  RUN_DIR=""
  for cand in $(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null); do
    if [ ! -f "$cand/COMPLETE" ]; then RUN_DIR="$cand"; echo "resuming incomplete run dir: $RUN_DIR"; break; fi
  done
  if [ -z "$RUN_DIR" ]; then
    RUN_DIR="$LOGS_DIR/$DATE_STR/$STAGE_NAME/run_1"
    SUFFIX=2
    while [ -e "$RUN_DIR" ]; do RUN_DIR="$LOGS_DIR/$DATE_STR/$STAGE_NAME/run_1-r${SUFFIX}"; SUFFIX=$((SUFFIX+1)); done
    mkdir -p "$RUN_DIR"
    echo "new run dir: $RUN_DIR"
  fi
fi
set_paths "$RUN_DIR"

# ---------- locate inputs: stage-07 winner + sealed stage-05 archive ----------
note "1. inputs (stage-07 winner + sealed stage-05 anchors)"
SRC07_DIR="${STAGE08_SRC07_DIR:-}"
if [ -z "$SRC07_DIR" ]; then
  for d in $(ls -dt "$LOGS_DIR"/*/07-lever-screening/run_* 2>/dev/null); do
    [ -f "$d/COMPLETE" ] && [ -f "$d/winner.json" ] && SRC07_DIR="$d" && break
  done
fi
[ -n "$SRC07_DIR" ] || die "no COMPLETE stage-07 run with winner.json found — the single shot requires a PROCEED screening outcome"
WINNER_JSON="$RUN_DIR/winner.json"
if [ ! -f "$WINNER_JSON" ]; then cp "$SRC07_DIR/winner.json" "$WINNER_JSON"; fi
WINNER_ARM=$(python3 -c "import json; print(json.load(open('$WINNER_JSON'))['arm_id'])")
echo "candidate arm: $WINNER_ARM (from $SRC07_DIR)"

SRC05_DIR="${STAGE08_SRC05_DIR:-}"
if [ -z "$SRC05_DIR" ]; then
  for d in "$LOGS_DIR"/*/05-quality-gate/run_*; do
    [ -f "$d/COMPLETE" ] && SRC05_DIR="$d"
  done
fi
[ -n "$SRC05_DIR" ] && [ -d "$SRC05_DIR" ] || die "sealed stage-05 archive not found"
if [ "${STAGE08_SKIP_ANCHORS:-0}" = "1" ]; then
  echo "TEST HOOK: STAGE08_SKIP_ANCHORS=1 — sealed stage-05 hash anchors skipped (sandbox only)"
else
python3 - "$SRC05_DIR" "$FROZEN_SHA" "$GENA_SHA" "$BLIND_SHA" <<'PY' || die "stage-05 anchor hash check FAILED — refusing to confirm against unverified inputs"
import hashlib, os, sys
d = sys.argv[1]
expect = {"frozen_set.jsonl": sys.argv[2], "gen_A.jsonl": sys.argv[3], "blind_map.jsonl": sys.argv[4]}
bad = []
for name, want in expect.items():
    p = os.path.join(d, name)
    got = hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.exists(p) else "MISSING"
    if got != want: bad.append(f"{name}: got {got} want {want}")
if bad:
    print("anchor mismatch:"); [print("  " + b) for b in bad]; sys.exit(1)
print("stage-05 anchors verified (frozen_set / gen_A BF16 / blind_map)")
PY
fi
for f in frozen_set.jsonl gen_A.jsonl blind_map.jsonl; do
  [ -f "$RUN_DIR/$f" ] || cp "$SRC05_DIR/$f" "$RUN_DIR/$f"
done
echo "source archive: $SRC05_DIR" > "$RUN_DIR/source_archive.txt"

# ---------- preflight ----------
note "2. time / host / GPU / engine anchors (L1)"
date -u
hostname || true
echo "scripts_rev=$GIT_REV"
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1 || true
if [ "${STAGE08_SKIP_SERVER:-0}" != "1" ]; then
  python3 - <<PY
import sys
try:
    import vllm
    assert vllm.__version__ == "$VLLM_PINNED", f"vLLM {vllm.__version__} != pinned $VLLM_PINNED (L1)"
    print("vllm:", vllm.__version__, "(pinned OK)")
except ImportError:
    sys.exit("No module named 'vllm' — install vllm==$VLLM_PINNED first (L1 pin)")
PY
  GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
  [[ "$GPU_NAME" == *"$GPU_EXPECT"* ]] || die "expected $GPU_EXPECT, found '$GPU_NAME' (hardware boundary, L3)"
  echo "gpu: $GPU_NAME"
fi
[ -f "$RECIPES_FILE" ] || die "private recipes file missing: $RECIPES_FILE (pod-side custody, never committed)"
[ -f "$KEY_FILE" ] || die "judge key not found at $KEY_FILE"
python3 -c "import httpx" 2>/dev/null || pip install -q httpx
START_TS=$(date +%s)

# ---------- phase 3: resolve winner recipe (custody chain; sha must match screening record) ----------
note "3. winner recipe resolution (sha-pinned to the screening record)"
RJSON="$(WINNER_JSON="$WINNER_JSON" RECIPES_FILE="$RECIPES_FILE" SRC07_DIR="$SRC07_DIR" python3 - <<'PY'
import hashlib, json, os, statistics, sys
w = json.load(open(os.environ["WINNER_JSON"]))
arm, want_sha = w["arm_id"], w.get("recipe_sha256")
recs = json.load(open(os.environ["RECIPES_FILE"]))["recipes"]
def canon(r): return hashlib.sha256(json.dumps(r, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
if arm in recs:
    r = recs[arm]
else:
    # wave-2 arm: re-derive deterministically from the archived wave-1 judge log
    src07 = os.environ["SRC07_DIR"]
    rows = [json.loads(l) for l in open(os.path.join(src07, "judge_raw_screen.jsonl")) if l.strip()]
    AXES = ["correctness", "instruction_following", "clarity"]
    singles = ["a2-smooth", "a3-calib-static", "a4-exempt-attn", "a5-exempt-down"]
    per = {}
    for a in singles:
        rs = [x for x in rows if x["arm_id"] == a]
        cl, ov = [], []
        for x in rs:
            sR = x["scores_r1"] if x["ref_is_response_1"] else x["scores_r2"]
            sA = x["scores_r2"] if x["ref_is_response_1"] else x["scores_r1"]
            cl.append(sA["clarity"] - sR["clarity"]); ov.append(statistics.mean(sA[q] - sR[q] for q in AXES))
        per[a] = (statistics.mean(cl), statistics.mean(ov))
    rank = sorted(singles, key=lambda a: (-per[a][0], -per[a][1], a))
    pair = {"a7-w2": (rank[0], rank[1]), "a8-w2": (rank[0], rank[2])}[arm]
    ra, rb = recs[pair[0]], recs[pair[1]]
    qa, qb = ra["quantization"], rb["quantization"]
    scheme = "FP8" if "FP8" in (qa["scheme"], qb["scheme"]) else qa["scheme"]
    over = qa.get("scheme_overrides") or qb.get("scheme_overrides")
    ignore = list(dict.fromkeys(qa["ignore"] + qb["ignore"]))
    r = dict(arm_id=arm, builder="llmcompressor-oneshot",
             levers=sorted(set(ra.get("levers", []) + rb.get("levers", []))),
             quantization=dict(targets="Linear", scheme=scheme, ignore=ignore),
             calibration=ra["calibration"],
             serve_extra="--quantization compressed-tensors", uses_base_model=False)
    if over: r["quantization"]["scheme_overrides"] = over
    sm = ra.get("smoothing") or rb.get("smoothing")
    if sm: r["smoothing"] = sm
got = canon(r)
if want_sha and got != want_sha:
    sys.exit(f"FATAL: resolved recipe sha256 {got} != screening record {want_sha} — custody chain broken, owner decision required")
print(json.dumps(dict(arm_id=arm, recipe=r, recipe_sha256=got)))
PY
)" || die "winner recipe resolution failed"
echo "$RJSON" | python3 -c "import json,sys; s=json.load(sys.stdin); print('recipe resolved:', s['arm_id'], 'sha256=%s…' % s['recipe_sha256'][:16], 'levers=', s['recipe'].get('levers'))"

# ---------- phase 4: build the winner checkpoint (rebuild; hash disclosed vs screening) ----------
note "4. candidate checkpoint (winner: $WINNER_ARM)"
CKPT_DIR="$CKPT_ROOT/${WINNER_ARM}-confirm"
SCREEN_CKPT_SHA="$(python3 -c "
import json, os
p = os.path.join('$SRC07_DIR', 'checkpoints.jsonl')
if os.path.exists(p):
    for l in open(p):
        e = json.loads(l)
        if e.get('arm_id') == '$WINNER_ARM': print(e.get('checkpoint_sha256', '')); break
" 2>/dev/null || true)"
if [ -f "$CKPT_LOG" ] && [ -d "$CKPT_DIR" ]; then
  CKPT_SHA=$(python3 -c "import json; print(json.load(open('$CKPT_LOG'))['checkpoint_sha256'])")
  echo "confirm checkpoint already built: sha256=${CKPT_SHA:0:16}… — resume"
elif [ -f "$CKPT_LOG" ]; then
  # marker exists but the checkpoint dir was wiped (pod restart) — rebuild from
  # the identical recipe and refresh the marker (hash disclosed in the verdict)
  echo "checkpoint dir wiped but marker exists — rebuilding from the identical recipe (hash re-recorded)"
  rm -f "$CKPT_LOG"
  STAGE08_REBUILD=1
  if [ "${STAGE08_MOCK_BUILD:-0}" = "1" ]; then
    mkdir -p "$CKPT_DIR"; echo '{"mock": true}' > "$CKPT_DIR/config.json"
    CKPT_SHA="mock-$(date +%s)"
    python3 -c "
import json
json.dump(dict(arm_id='$WINNER_ARM', checkpoint_dir='$CKPT_DIR', checkpoint_sha256='$CKPT_SHA',
               screening_checkpoint_sha256='${SCREEN_CKPT_SHA:-unknown}',
               matches_screening=('$CKPT_SHA' == '${SCREEN_CKPT_SHA:-}'),
               mock=True), open('$CKPT_LOG', 'w'), indent=2)"
  else
  RJSON="$RJSON" CKPT_DIR="$CKPT_DIR" CALIB_JSONL="$SRC07_DIR/calibration_texts.jsonl" \
  MODEL="$MODEL" MODEL_REV="$MODEL_REV" CKPT_LOG="$CKPT_LOG" \
  SCREEN_CKPT_SHA="${SCREEN_CKPT_SHA:-unknown}" python3 - <<'PY'
import hashlib, json, os, time
spec = json.loads(os.environ["RJSON"])
recipe = spec["recipe"]
cdir = os.environ["CKPT_DIR"]
calib = [json.loads(l)["text"] for l in open(os.environ["CALIB_JSONL"])]
assert len(calib) == 256
try:
    import llmcompressor
    from llmcompressor import oneshot
    from llmcompressor.modifiers.quantization import QuantizationModifier
    ver = llmcompressor.__version__
except ImportError:
    raise SystemExit("llmcompressor not installed — install it on the pod (builder version is provenance)")
mods = []
if "smoothing" in recipe:
    from llmcompressor.modifiers.smoothquant import SmoothQuantModifier
    mods.append(SmoothQuantModifier(smoothing_strength=recipe["smoothing"]["strength"]))
q = recipe["quantization"]
mods.append(QuantizationModifier(targets=q["targets"], scheme=q["scheme"], ignore=q["ignore"]))
t0 = time.time()
oneshot(model=os.environ["MODEL"], revision=os.environ["MODEL_REV"],
        dataset=[{"text": t} for t in calib], recipe=mods, output_dir=cdir,
        num_calibration_samples=recipe["calibration"]["n_samples"],
        max_seq_length=recipe["calibration"]["max_seq_len"])
def tree_sha(root):
    h = hashlib.sha256()
    for dp, _, fns in sorted(os.walk(root)):
        for fn in sorted(fns):
            p = os.path.join(dp, fn)
            h.update(os.path.relpath(p, root).encode())
            with open(p, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 22), b""):
                    h.update(chunk)
    return h.hexdigest()
csha = tree_sha(cdir)
ssha = os.environ["SCREEN_CKPT_SHA"]
json.dump(dict(arm_id=spec["arm_id"], recipe_sha256=spec["recipe_sha256"],
               llmcompressor_version=ver, checkpoint_dir=cdir, checkpoint_sha256=csha,
               screening_checkpoint_sha256=ssha, matches_screening=(csha == ssha),
               rebuilt_after_wipe=True,
               build_seconds=round(time.time() - t0, 1),
               ts_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())),
          open(os.environ["CKPT_LOG"], "w"), indent=2, sort_keys=True)
print(f"confirm checkpoint rebuilt: sha256={csha[:16]}… ({'identical to screening build' if csha == ssha else 'differs from screening build — declared, disclosed'})")
PY
  fi
elif [ "${STAGE08_MOCK_BUILD:-0}" = "1" ]; then
  mkdir -p "$CKPT_DIR"; echo '{"mock": true}' > "$CKPT_DIR/config.json"
  CKPT_SHA="mock-$(date +%s)"
  python3 -c "
import json
json.dump(dict(arm_id='$WINNER_ARM', checkpoint_dir='$CKPT_DIR', checkpoint_sha256='$CKPT_SHA',
               screening_checkpoint_sha256='${SCREEN_CKPT_SHA:-unknown}',
               matches_screening=('$CKPT_SHA' == '${SCREEN_CKPT_SHA:-}'),
               mock=True), open('$CKPT_LOG', 'w'), indent=2)"
  echo "TEST HOOK: mock checkpoint at $CKPT_DIR"
else
  FREE_GB=$(df --output=avail -BG "$HOME" | tail -1 | tr -dc '0-9')
  [ "${FREE_GB:-0}" -ge 50 ] || die "disk headroom < 50GB for checkpoint build"
  RJSON="$RJSON" CKPT_DIR="$CKPT_DIR" CALIB_JSONL="$SRC07_DIR/calibration_texts.jsonl" \
  MODEL="$MODEL" MODEL_REV="$MODEL_REV" CKPT_LOG="$CKPT_LOG" \
  SCREEN_CKPT_SHA="${SCREEN_CKPT_SHA:-unknown}" python3 - <<'PY'
import hashlib, json, os, time
spec = json.loads(os.environ["RJSON"])
recipe = spec["recipe"]
cdir = os.environ["CKPT_DIR"]
calib_p = os.environ["CALIB_JSONL"]
calib = [json.loads(l)["text"] for l in open(calib_p)]
assert len(calib) == 256, f"calibration archive row count {len(calib)} != 256"
try:
    import llmcompressor
    from llmcompressor import oneshot
    from llmcompressor.modifiers.quantization import QuantizationModifier
    ver = llmcompressor.__version__
except ImportError:
    raise SystemExit("llmcompressor not installed — install it on the pod (builder version is provenance)")
mods = []
if "smoothing" in recipe:
    from llmcompressor.modifiers.smoothquant import SmoothQuantModifier
    mods.append(SmoothQuantModifier(smoothing_strength=recipe["smoothing"]["strength"]))
q = recipe["quantization"]
mods.append(QuantizationModifier(targets=q["targets"], scheme=q["scheme"], ignore=q["ignore"]))
t0 = time.time()
oneshot(model=os.environ["MODEL"], revision=os.environ["MODEL_REV"],
        dataset=[{"text": t} for t in calib], recipe=mods, output_dir=cdir,
        num_calibration_samples=recipe["calibration"]["n_samples"],
        max_seq_length=recipe["calibration"]["max_seq_len"])
def tree_sha(root):
    h = hashlib.sha256()
    for dp, _, fns in sorted(os.walk(root)):
        for fn in sorted(fns):
            p = os.path.join(dp, fn)
            h.update(os.path.relpath(p, root).encode())
            with open(p, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 22), b""):
                    h.update(chunk)
    return h.hexdigest()
csha = tree_sha(cdir)
ssha = os.environ["SCREEN_CKPT_SHA"]
json.dump(dict(arm_id=spec["arm_id"], recipe_sha256=spec["recipe_sha256"],
               llmcompressor_version=ver, checkpoint_dir=cdir, checkpoint_sha256=csha,
               screening_checkpoint_sha256=ssha, matches_screening=(csha == ssha),
               build_seconds=round(time.time() - t0, 1),
               ts_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())),
          open(os.environ["CKPT_LOG"], "w"), indent=2, sort_keys=True)
print(f"confirm checkpoint built: sha256={csha[:16]}… (screening build {ssha[:16]}…; {'identical' if csha == ssha else 'DIFFERS — declared deviation, disclosed in verdict'})")
PY
fi
CKPT_SHA=$(python3 -c "import json; print(json.load(open('$CKPT_LOG'))['checkpoint_sha256'])")

# ---------- phase 5: generation, arm C (tuned) on the frozen 150 ----------
start_server_c() {
  local slog="$RUN_DIR/server_C.log"
  echo "starting candidate server ($CKPT_DIR --quantization compressed-tensors; prefix caching OFF)"
  nohup python -m vllm.entrypoints.openai.api_server \
    --model "$CKPT_DIR" --quantization compressed-tensors \
    --no-enable-prefix-caching --max-model-len "$MAX_MODEL_LEN" \
    --port "$PORT" > "$slog" 2>&1 &
  echo $! > "$RUN_DIR/server.pid"
  local waited=0
  until curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do
    sleep 10; waited=$((waited+10))
    if [ "$waited" -ge 2400 ]; then die "server failed to become healthy in 2400s — see $slog"; fi
    if ! kill -0 "$(cat "$RUN_DIR/server.pid")" 2>/dev/null; then die "server process died — see $slog"; fi
  done
  echo "candidate server healthy after ${waited}s"
  echo "server_argv: vllm serve $CKPT_DIR --quantization compressed-tensors --no-enable-prefix-caching --max-model-len $MAX_MODEL_LEN --port $PORT" \
    > "$RUN_DIR/server_argv_C.txt"
}
stop_server() {
  [ -f "$RUN_DIR/server.pid" ] && kill "$(cat "$RUN_DIR/server.pid")" 2>/dev/null || true
  sleep 5
  pkill -f "vllm.entrypoints.openai.api_server" 2>/dev/null || true
}

note "5. generation: arm C (tuned) on the frozen 150 (concurrency $GEN_CONC)"
if [ "$(wc -l < "$GENC_JSONL" 2>/dev/null || echo 0)" -lt "$N_ITEMS" ]; then
  if [ "${STAGE08_SKIP_SERVER:-0}" != "1" ]; then
    start_server_c
    trap stop_server EXIT
  else
    echo "STAGE08_SKIP_SERVER=1 — using external server on port $PORT (test mode)"
  fi
  FROZEN_JSONL="$FROZEN_JSONL" GEN_JSONL="$GENC_JSONL" ARM="C" \
  MODEL="$CKPT_DIR" PORT="$PORT" GEN_CONC="$GEN_CONC" \
  MAX_SECONDS="$MAX_SECONDS" START_TS="$START_TS" GIT_REV="$GIT_REV" python3 - <<'PY'
import asyncio, datetime, hashlib, json, os, time
import httpx
MODEL = os.environ["MODEL"]; FROZEN = os.environ["FROZEN_JSONL"]
GEN = os.environ["GEN_JSONL"]; ARM = os.environ["ARM"]
PORT = os.environ["PORT"]; CONC = int(os.environ["GEN_CONC"])
REQ_TO = 900.0
frozen = [json.loads(l) for l in open(FROZEN) if l.strip()]
done = set()
if os.path.exists(GEN):
    for l in open(GEN):
        if l.strip(): done.add(json.loads(l)["request_id"])
todo = [r for r in frozen if r["request_id"] not in done]
print(f"arm C: {len(done)} already generated, {len(todo)} to go", flush=True)
if todo:
    async def main():
        gate = asyncio.Semaphore(CONC)
        lock = asyncio.Lock()
        n_done = 0
        async with httpx.AsyncClient(base_url=f"http://127.0.0.1:{PORT}",
                                     timeout=httpx.Timeout(REQ_TO, connect=30.0)) as client:
            async def one(rec):
                nonlocal n_done
                async with gate:
                    body = dict(model=MODEL, prompt=rec["prompt"],
                                temperature=0, max_tokens=rec["max_tokens"])
                    t0 = time.time()
                    r = await client.post("/v1/completions", json=body)
                    r.raise_for_status()
                    wall = time.time() - t0
                    resp = r.json()
                    text = resp["choices"][0]["text"]
                    usage = resp.get("usage", {})
                    row = dict(request_id=rec["request_id"], arm=ARM,
                               form=rec["form"], tier_target=rec["tier_target"],
                               max_tokens=rec["max_tokens"],
                               prompt_tokens=usage.get("prompt_tokens", 0),
                               output_tokens=usage.get("completion_tokens", 0),
                               wall_s=round(wall, 3),
                               output_text_sha256=hashlib.sha256(text.encode()).hexdigest(),
                               output_text=text, model=MODEL,
                               scripts_rev=os.environ["GIT_REV"],
                               ts_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
                    async with lock:
                        with open(GEN, "a") as fg:
                            fg.write(json.dumps(row, sort_keys=True) + "\n")
                        n_done += 1
                        if n_done % 10 == 0 or n_done == 1:
                            print(f"  arm C: {len(done)+n_done}/{len(frozen)} ({rec['request_id']}, {row['output_tokens']} tok, {wall:.1f}s)", flush=True)
            await asyncio.gather(*(one(rec) for rec in todo))
    asyncio.run(main())
print("arm C generation phase done", flush=True)
PY
  [ "${STAGE08_SKIP_SERVER:-0}" != "1" ] && stop_server || true
  if [ "${STAGE08_MOCK_BUILD:-0}" != "1" ]; then
    rm -rf "$CKPT_DIR" && echo "candidate checkpoint deleted after generation (hash anchor in checkpoint_confirm.json)"
  fi
else
  echo "arm C generation already complete — resume skip"
fi

# ---------- phase 6: panel judging (3 judges; original red-dot judge mandatory) ----------
note "6. panel judging (panel size $PANEL_SIZE; original judge mandatory; >= 2 vendor families)"
FROZEN_JSONL="$FROZEN_JSONL" GENA_JSONL="$GENA_JSONL" GENC_JSONL="$GENC_JSONL" \
BLIND_JSONL="$BLIND_JSONL" JUDGE_RAW_JSONL="$JUDGE_RAW_JSONL" \
KEY_FILE="$KEY_FILE" BUDGET_USD="$BUDGET_USD" MAX_SECONDS="$MAX_SECONDS" START_TS="$START_TS" \
OR_BASE_URL="${OR_BASE_URL:-https://openrouter.ai/api/v1}" GIT_REV="$GIT_REV" \
N_ITEMS="$N_ITEMS" PANEL_SIZE="$PANEL_SIZE" ORIG_JUDGE="$ORIG_JUDGE" \
PANEL_REST_STR="$(printf '%s\n' "${PANEL_REST[@]}")" \
FALLBACK_PRICE_IN="$FALLBACK_PRICE_IN" FALLBACK_PRICE_OUT="$FALLBACK_PRICE_OUT" python3 - <<'PY'
import json, os, time, datetime
import urllib.request, urllib.error

FROZEN = os.environ["FROZEN_JSONL"]; GENA = os.environ["GENA_JSONL"]
GENC  = os.environ["GENC_JSONL"]; BLINDF = os.environ["BLIND_JSONL"]
JRAW  = os.environ["JUDGE_RAW_JSONL"]; KEYF = os.environ["KEY_FILE"]
BUDGET = float(os.environ["BUDGET_USD"]); MAX_SEC = int(os.environ["MAX_SECONDS"])
T0 = int(os.environ["START_TS"]); ORBASE = os.environ["OR_BASE_URL"].rstrip("/")
N_ITEMS = int(os.environ["N_ITEMS"]); PSIZE = int(os.environ["PANEL_SIZE"])
ORIG = os.environ["ORIG_JUDGE"]
AXES = ["correctness", "instruction_following", "clarity"]

REST = []
for line in os.environ["PANEL_REST_STR"].splitlines():
    if line.strip():
        m, ci, co = line.split("|"); REST.append((m, float(ci), float(co)))
FALLBACK_PRICE = (float(os.environ["FALLBACK_PRICE_IN"]), float(os.environ["FALLBACK_PRICE_OUT"]))

KEY = open(KEYF).read().strip()
if not KEY.startswith("sk-or-") and "openrouter.ai" in ORBASE:
    print("REFUSED: key file does not look like an OpenRouter key"); raise SystemExit(1)

def call_api(model, messages, max_tokens, timeout=120):
    body = json.dumps(dict(model=model, messages=messages, temperature=0,
                           max_tokens=max_tokens,
                           reasoning={"exclude": True})).encode()
    req = urllib.request.Request(
        f"{ORBASE}/chat/completions", data=body,
        headers={"Authorization": f"Bearer {KEY}",
                 "Content-Type": "application/json",
                 "HTTP-Referer": "https://github.com/effiq/pilot003",
                 "X-Title": "effiq-pilot003-red-dot-confirm"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())

def probe(cand):
    resp = call_api(cand, [dict(role="user", content="Reply with the single word: ok")], max_tokens=4, timeout=60)
    t = resp["choices"][0]["message"]["content"]
    if not t or not str(t).strip():
        raise ValueError("empty probe content")

# seat 1: the original red-dot judge — mandatory (a repair that benches the referee is not a repair)
try:
    probe(ORIG)
    print(f"panel seat 1/{PSIZE}: {ORIG} (original red-dot judge, probe ok)")
except Exception as e:
    print(f"REFUSED: original red-dot judge {ORIG} unreachable ({type(e).__name__}: {e}) — owner decision required (pre-registered)")
    raise SystemExit(1)
panel, prices = [ORIG], {ORIG: (0.29, 1.14)}
for cand, cin, cout in REST:
    if len(panel) >= PSIZE: break
    try:
        probe(cand)
        panel.append(cand); prices[cand] = (cin, cout)
        print(f"panel seat {len(panel)}/{PSIZE}: {cand} (probe ok)")
    except Exception as e:
        print(f"panel candidate {cand}: unavailable ({type(e).__name__}: {e})")
if len(panel) < PSIZE:
    print(f"REFUSED: only {len(panel)}/{PSIZE} judges reachable — no partial panel (owner decision required)")
    raise SystemExit(1)
fams = {m.split("/")[0] for m in panel}
if len(fams) < 2:
    print(f"REFUSED: panel families {sorted(fams)} < 2 — family-diversity clause (ADDENDUM-02)")
    raise SystemExit(1)
print(f"panel frozen for this run: {panel} (families: {sorted(fams)})")

frozen = [json.loads(l) for l in open(FROZEN) if l.strip()]
gA = {json.loads(l)["request_id"]: json.loads(l) for l in open(GENA) if l.strip()}
gC = {json.loads(l)["request_id"]: json.loads(l) for l in open(GENC) if l.strip()}
blind = {}
for l in open(BLINDF):
    if l.strip():
        r = json.loads(l); blind[r["request_id"]] = r["a_is_response_1"]

judged = {}
if os.path.exists(JRAW):
    for l in open(JRAW):
        if l.strip():
            r = json.loads(l); judged[(r["request_id"], r["judge_model"])] = r

def est_cost(model, ptoks, ctoks):
    cin, cout = prices.get(model, FALLBACK_PRICE)
    return (ptoks * cin + ctoks * cout) / 1e6
spent = sum(est_cost(r["judge_model"], r.get("prompt_tokens", 0), r.get("completion_tokens", 0)) for r in judged.values())
print(f"judge resume: {len(judged)} rows already judged, est. spent ${spent:.3f} (guard ${BUDGET:.0f})")

# Byte-identical to the stage-05 judge prompt.
SYSTEM = ("You are an impartial, strict evaluator of AI assistant outputs. You compare two "
          "responses to the same user prompt and score each on three axes. Be objective and "
          "consistent across items. Output ONLY valid JSON, no markdown, no commentary.")
TEMPLATE = """[USER PROMPT]
{prompt}

[RESPONSE 1]
{r1}

[RESPONSE 2]
{r2}

Score each response on three axes, integers 0-10:
- correctness: factual/technical correctness relative to what the prompt asks.
- instruction_following: does it do what was asked, completely, without missing parts or extraneous content.
- clarity: coherence, organization, fluency.

Return ONLY this JSON:
{{"response_1": {{"correctness": X, "instruction_following": Y, "clarity": Z}},
 "response_2": {{"correctness": X, "instruction_following": Y, "clarity": Z}}}}"""

def parse_scores(content):
    c = content.strip()
    if c.startswith("```"):
        c = c.strip("`")
        if c.lower().startswith("json"): c = c[4:]
    i, j = c.find("{"), c.rfind("}")
    obj = json.loads(c[i:j+1])
    out = {}
    for k in ("response_1", "response_2"):
        sc = obj[k]
        vals = {a: int(sc[a]) for a in AXES}
        if not all(0 <= v <= 10 for v in vals.values()): raise ValueError("score out of range")
        out[k] = vals
    return out

n_new, n_fail = 0, 0
with open(JRAW, "a") as fj:
    for jm in panel:
        for rec in frozen:
            rid = rec["request_id"]
            if (rid, jm) in judged or rid not in gA or rid not in gC:
                continue
            if time.time() - T0 > MAX_SEC:
                print("TIME GUARD: judging aborted; partial log preserved — re-run to resume"); break
            if spent > BUDGET:
                print(f"BUDGET GUARD: est. spend ${spent:.2f} exceeds ${BUDGET:.0f}; aborting (owner decision required)"); break
            # blind map semantics carried from stage 05: a_is_response_1 -> BF16 (arm A) is response 1
            r1, r2 = ((gA[rid]["output_text"], gC[rid]["output_text"]) if blind[rid]
                      else (gC[rid]["output_text"], gA[rid]["output_text"]))
            msgs = [dict(role="system", content=SYSTEM),
                    dict(role="user", content=TEMPLATE.format(prompt=rec["prompt"], r1=r1, r2=r2))]
            ok = False
            for attempt, pause in enumerate((5, 15, 30)):
                try:
                    resp = call_api(jm, msgs, max_tokens=1024)
                    content = resp["choices"][0]["message"]["content"]
                    if content is None:
                        raise ValueError("null content; raw=" + json.dumps(resp)[:200])
                    scores = parse_scores(content)
                    u = resp.get("usage", {})
                    row = dict(request_id=rid, judge_model=jm,
                               a_is_response_1=blind[rid],
                               scores_r1=scores["response_1"], scores_r2=scores["response_2"],
                               prompt_tokens=u.get("prompt_tokens", 0),
                               completion_tokens=u.get("completion_tokens", 0),
                               raw_content=content, scripts_rev=os.environ["GIT_REV"],
                               ts_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
                    fj.write(json.dumps(row, sort_keys=True) + "\n"); fj.flush()
                    spent += est_cost(jm, row["prompt_tokens"], row["completion_tokens"])
                    n_new += 1; ok = True
                    if n_new % 30 == 0 or n_new == 1:
                        print(f"  judged {rid} by {jm} ({len(judged)+n_new}/{len(frozen)*len(panel)}), est. spent ${spent:.3f}")
                    break
                except Exception as e:
                    print(f"  judge error on {rid} by {jm} (attempt {attempt+1}): {type(e).__name__}: {e}")
                    time.sleep(pause)
            if not ok:
                n_fail += 1
                print(f"  {rid} by {jm}: all retries failed — left for next resume")
print(f"judge phase done: new={n_new} failed={n_fail} total={len(judged)+n_new}/{len(frozen)*len(panel)} est_spent=${spent:.3f}")
PY

# ---------- verdict + completeness gate ----------
note "7. confirm verdict (recomputed from archived logs)"
set +e
run_verdict
RC_V=$?
set -e

NJ=$(wc -l < "$JUDGE_RAW_JSONL" 2>/dev/null || echo 0)
NC=$(wc -l < "$GENC_JSONL" 2>/dev/null || echo 0)
NEXP=$(( N_ITEMS * PANEL_SIZE ))
if [ "$NC" -ge "$N_ITEMS" ] && [ "$NJ" -ge "$NEXP" ] && { [ "$RC_V" -eq 0 ] || [ "$RC_V" -eq 2 ]; }; then
  date -u > "$RUN_DIR/COMPLETE"
  if [ "$RC_V" -eq 0 ]; then
    echo "STAGE 08 RED-DOT CONFIRM: COMPLETE — QUALITY GATE: PASS (next: stage 09 tuned-performance gate)"
  else
    echo "STAGE 08 RED-DOT CONFIRM: COMPLETE — QUALITY GATE: FAIL (single shot missed; publish per ADDENDUM-02)"
  fi
  exit 0
else
  echo "STAGE 08 RED-DOT CONFIRM: INCOMPLETE (genC=$NC/$N_ITEMS judged=$NJ/$NEXP; re-run the same command to resume)"
  exit 1
fi
