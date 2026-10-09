#!/usr/bin/env bash
# =============================================================================
# Pilot 003 — STAGE 07: LEVER SCREENING (red-dot repair, phase 1 of 2)
#
# Pre-registered in PREREG-ADDENDUM-02 (frozen before execution). Question:
# does the deployment-level lever space contain a configuration that brings
# the stage-05 clarity breach (delta -0.127 vs tolerance 0.1, sealed in
# Pilot 002) back within tolerance — measured on a SCREENING SET that is
# disjoint from the frozen 150-item set?
#
# Two-phase anti-p-hacking design (frozen):
#   - This stage is the CHEAP phase. Screening conclusions are indicative.
#   - The winning arm gets ONE confirmation attempt on the frozen 150-item
#     set in stage 08. No second shot without a new addendum.
#
# Structure (frozen):
#   - Screening set: 40 items, same generator family as the Pilot 001
#     frozen set, seed 20261013, asserted DISJOINT from the frozen 150
#     (sha256 of every prompt; zero overlap required).
#   - Reference arm R: BF16 defaults on the screening set.
#   - Wave 1: 6 arms (a1 control = exact stage-05 arm-B config, a2..a5
#     single levers, a6 all-lever combination) — see arms-manifest.json.
#   - Wave 2: <= 2 arms composed by a deterministic rule from the wave-1
#     single-lever ranking: a7 = merge(top1, top2), a8 = merge(top1, top3).
#   - Screening judge: ONE external judge, cheapest-first candidate order
#     (declared below). Screening numbers are indicative; the confirm
#     stage uses the full panel.
#   - Winner selection (frozen): argmax clarity delta among non-control
#     arms; tie-break: overall delta, then fewer levers, then arm_id.
#   - Proceed rule (frozen): PROCEED iff winner clarity delta >= -0.05
#     (half-tolerance transfer margin, declared); otherwise
#     SCREENING-EXHAUSTED — a legitimate, publishable FAIL outcome.
#
# Recipe custody (three-layer disclosure policy): full lever recipes live
# ONLY in ~/pilot-env/arms-recipes.json on the pod (never committed). The
# public manifest carries sha256 per recipe; the run archive records the
# sha256 of every recipe actually executed. Time-delayed disclosure: the
# hash chain proves that a future public disclosure is identical to what
# ran today.
#
# Checkpoint custody: derived checkpoints are built on pod, hashed
# (full-tree sha256), used for generation, then DELETED (disk budget).
# The hash is the anchor; stage 08 rebuilds from the identical frozen
# recipe and discloses both hashes if a rebuild differs.
#
# Anchors (L1, unchanged): Qwen2.5-14B-Instruct @ cf98f3b3…, vLLM 0.31.0,
# one L40S, prefix caching OFF, temperature 0, natural stopping.
#
# Budget guards: MAX_SECONDS wall-clock rail; BUDGET_USD judge spend cap.
#
# Verify entry: bash stages/07-lever-screening.sh --verify [run_dir]
# Recomputes the screening verdict from the archived logs only.
#
# Test hooks (sandbox only, never set in production):
#   STAGE07_OUT_DIR, STAGE07_SKIP_SERVER, STAGE07_MOCK_BUILD, PORT,
#   OR_BASE_URL, KEY_FILE, MAX_SECONDS, BUDGET_USD, STAGE07_FROZEN_JSONL,
#   STAGE07_SCREEN_JSONL, RECIPES_FILE
# =============================================================================
set -euo pipefail

EFFIQ_HOME="${EFFIQ_HOME:-$HOME/effiq}"
LOGS_DIR="${LOGS_DIR:-$EFFIQ_HOME/pilot-logs}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$EFFIQ_HOME/pilot003}"
DATE_STR="$(date -u +%Y-%m-%d)"
STAGE_NAME="07-lever-screening"

MODEL="Qwen/Qwen2.5-14B-Instruct"
MODEL_REV="cf98f3b3bbb457ad9e2bb7baf9a0125b6b88caa8"   # L1 pinned
VLLM_PINNED="0.31.0"                                   # L1 pinned
GPU_EXPECT="L40S"
MAX_MODEL_LEN=32768
FROZEN_SHA="728b2f8354701a301467afaf52d643d12a679af5c41542bb1701634e4235cf7d"  # frozen 150 (disjointness check)
MANIFEST_SHA="5f1a1972e0ba628ebb5f4df29bc017c64ed1b6eb5e6fdaddb409f44c24eb9387"  # arms-manifest.json
SCREEN_SEED=20261013                                   # frozen (ADDENDUM-02)
N_SCREEN=40                                            # frozen
BLIND_SEED_SCR=20261014                                # frozen
CALIB_SEED=20261015                                    # frozen (calibration texts)
TOL=0.1                                                # frozen tolerance
PROCEED_MARGIN=0.05                                    # frozen: winner clarity delta >= -PROCEED_MARGIN
GEN_CONC=8                                             # serving concurrency (same as stage 05)
BOOT_SEED=20261012                                     # descriptive only, declared
BOOT_N=100000
MAX_SECONDS="${MAX_SECONDS:-25200}"                    # ~7 h rail
BUDGET_USD="${BUDGET_USD:-8}"                          # judge spend cap
KEY_FILE="${KEY_FILE:-$HOME/pilot-env/openrouter-key}"
RECIPES_FILE="${RECIPES_FILE:-$HOME/pilot-env/arms-recipes.json}"
CKPT_ROOT="${CKPT_ROOT:-$HOME/effiq/p003-ckpt}"        # build-and-delete workspace
PORT="${PORT:-8000}"                                   # env override is a test hook only

# Screening judge candidates (frozen order; cheapest first; Amendment-01
# probe mechanics: reasoning excluded, empty content = unreachable).
SCREEN_JUDGE_CANDIDATES=(
    "deepseek/deepseek-chat-v3.1|0.25|0.95"
    "deepseek/deepseek-v3.1-terminus|0.27|1.00"
    "z-ai/glm-4.6|0.43|1.75"
)
FALLBACK_PRICE_IN=1.00
FALLBACK_PRICE_OUT=3.00

note() { printf '\n=== %s ===\n' "$*"; }
die()  { printf '\n\033[1;31m[stage07][ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

set_paths() {
  RUN_DIR="$1"
  SCREEN_JSONL="$RUN_DIR/screening_set.jsonl"
  CALIB_JSONL="$RUN_DIR/calibration_texts.jsonl"
  GEN_R_JSONL="$RUN_DIR/gen_R.jsonl"
  JUDGE_RAW_JSONL="$RUN_DIR/judge_raw_screen.jsonl"
  RECIPE_LOG="$RUN_DIR/recipes_executed.jsonl"      # public: hashes + lever class labels ONLY
  CKPT_LOG="$RUN_DIR/checkpoints.jsonl"             # public: checkpoint hashes ONLY
  LOCAL_RECIPE_LOG="$CKPT_ROOT/recipes-local.jsonl" # pod-local, NEVER pushed: full recipe bodies
  VERDICT_TXT="$RUN_DIR/verdict_s.txt"
  WINNER_JSON="$RUN_DIR/winner.json"
}

# ---------- screening verdict (recomputable from the archive alone) ----------
run_verdict() {
  RUN_DIR="$RUN_DIR" SCREEN_JSONL="$SCREEN_JSONL" JUDGE_RAW_JSONL="$JUDGE_RAW_JSONL" \
  RECIPE_LOG="$RECIPE_LOG" VERDICT_TXT="$VERDICT_TXT" WINNER_JSON="$WINNER_JSON" \
  N_SCREEN="$N_SCREEN" TOL="$TOL" PROCEED_MARGIN="$PROCEED_MARGIN" \
  BLIND_SEED_SCR="$BLIND_SEED_SCR" BOOT_SEED="$BOOT_SEED" BOOT_N="$BOOT_N" \
  MANIF="${MANIFEST:-}" GIT_REV="$GIT_REV" GEN_CONC="$GEN_CONC" python3 - <<'PY'
import hashlib, json, os, statistics

RUN_DIR = os.environ["RUN_DIR"]
SCREEN  = os.environ["SCREEN_JSONL"]
JRAW    = os.environ["JUDGE_RAW_JSONL"]
RLOG    = os.environ["RECIPE_LOG"]
VERDICTF= os.environ["VERDICT_TXT"]
WINNERF = os.environ["WINNER_JSON"]
N_SCREEN= int(os.environ["N_SCREEN"])
TOL     = float(os.environ["TOL"])
MARGIN  = float(os.environ["PROCEED_MARGIN"])
BLSEED  = os.environ["BLIND_SEED_SCR"]
BSEED   = int(os.environ["BOOT_SEED"])
MANIF   = os.environ.get("MANIF", "")
BN      = int(os.environ["BOOT_N"])
AXES    = ["correctness", "instruction_following", "clarity"]

def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.exists(p) else "MISSING"
def blind(arm, rid):
    return hashlib.sha256(f"{BLSEED}|{arm}|{rid}".encode()).digest()[0] & 1 == 1

lines = ["STAGE 07 VERDICT — LEVER SCREENING (PILOT 003, phase 1 of 2: indicative)",
         f"tolerance={TOL}; proceed rule: winner clarity delta >= -{MARGIN} (declared transfer margin)",
         "screening conclusions are INDICATIVE — the winner gets ONE confirmation attempt in stage 08",
         f"generation: serving mode, temperature=0, concurrency {os.environ['GEN_CONC']}, natural stopping",
         f"blind: per (arm,item) sha256 bit, seed={BLSEED}; reference arm R = BF16 defaults", ""]
for name, p in [("screening_set.jsonl", SCREEN), ("gen_R.jsonl", os.path.join(RUN_DIR, "gen_R.jsonl")),
                ("judge_raw_screen.jsonl", JRAW)]:
    lines.append(f"  {name}: sha256={sha(p)}")
lines.append(f"scripts_rev={os.environ['GIT_REV']}")

screen = [json.loads(l) for l in open(SCREEN) if l.strip()]
rows = [json.loads(l) for l in open(JRAW) if l.strip()] if os.path.exists(JRAW) else []
arms = sorted({r["arm_id"] for r in rows},
              key=lambda a: min(i for i, r in enumerate(rows) if r["arm_id"] == a))
jmodels = sorted({r["judge_model"] for r in rows})
lines += ["", f"screening judge(s): {', '.join(jmodels) if jmodels else '(none)'}",
          f"arms with judged rows: {', '.join(arms) if arms else '(none)'}",
          f"judged rows: {len(rows)} / {N_SCREEN} per arm"]

per_arm = {}
for a in arms:
    rs = [r for r in rows if r["arm_id"] == a]
    if len(rs) < N_SCREEN:
        continue
    deltas_cl, deltas_all = [], []
    for r in rs:
        sR = r["scores_r1"] if r["ref_is_response_1"] else r["scores_r2"]
        sA = r["scores_r2"] if r["ref_is_response_1"] else r["scores_r1"]
        deltas_cl.append(sA["clarity"] - sR["clarity"])
        deltas_all.append(statistics.mean(sA[x] - sR[x] for x in AXES))
    per_arm[a] = dict(n=len(rs), clarity=statistics.mean(deltas_cl), overall=statistics.mean(deltas_all))

lines += ["", "[per-arm screening deltas vs BF16 reference (40 items, 10-pt scale)]",
          f"  {'arm':22s} {'clarity':>8s} {'overall':>8s}"]
for a in sorted(per_arm):
    lines.append(f"  {a:22s} {per_arm[a]['clarity']:+8.3f} {per_arm[a]['overall']:+8.3f}")

non_control = sorted(a for a in per_arm if a != "a1-control")
if not non_control:
    lines += ["", "REFUSED: no fully-judged non-control arm — screening incomplete; re-run to resume."]
    open(VERDICTF, "w").write("\n".join(lines) + "\n")
    print("\n".join(lines)); raise SystemExit(1)

import numpy as np
# descriptive CI for the winner only, declared seed
rank = sorted(non_control, key=lambda a: (-per_arm[a]["clarity"], -per_arm[a]["overall"], a))
winner = rank[0]
wcl = per_arm[winner]["clarity"]

# lever count for the record (from executed recipes log if present)
nlev = None
if os.path.exists(RLOG):
    for l in open(RLOG):
        r = json.loads(l)
        if r.get("arm_id") == winner:
            nlev = len(r.get("levers", [])); break

wd = []
for r in rows:
    if r["arm_id"] != winner: continue
    sR = r["scores_r1"] if r["ref_is_response_1"] else r["scores_r2"]
    sA = r["scores_r2"] if r["ref_is_response_1"] else r["scores_r1"]
    wd.append(sA["clarity"] - sR["clarity"])
if wd:
    rng = np.random.default_rng(BSEED)
    means = rng.choice(np.array(wd), size=(BN, len(wd)), replace=True).mean(axis=1)
    lo, hi = np.percentile(means, [2.5, 97.5])
else:
    lo = hi = float("nan")

ctrl = per_arm.get("a1-control")
lines += ["",
    f"[control] a1-control (= exact stage-05 arm-B config) clarity delta on screening set: "
    f"{ctrl['clarity']:+.3f}" if ctrl else "[control] a1-control not fully judged",
    "",
    f"[selection] winner = {winner} (clarity {wcl:+.3f}, overall {per_arm[winner]['overall']:+.3f}"
    + (f", levers={nlev}" if nlev is not None else "") + ")",
    f"[descriptive] winner clarity 95% bootstrap CI: [{lo:+.3f}, {hi:+.3f}] (seed={BSEED}, n={len(wd)})",
    ""]
outcome = "PROCEED" if wcl >= -MARGIN else "SCREENING-EXHAUSTED"
if outcome == "PROCEED":
    lines += [f"OUTCOME: PROCEED — {winner} advances to the single-shot confirmation (stage 08).",
              "discipline: stage 08 is the ONLY confirmation attempt; a miss is a published FAIL."]
else:
    lines += [f"OUTCOME: SCREENING-EXHAUSTED — no arm reached the declared margin (-{MARGIN}).",
              "This is a legitimate, publishable FAIL: the screened lever space is insufficient",
              "on this model x workload. All arm data above is the evidence."]
lines += ["", "This file is reproducible from the archived logs alone: bash stages/07-lever-screening.sh --verify <run_dir>"]
open(VERDICTF, "w").write("\n".join(lines) + "\n")

if outcome == "PROCEED":
    # recipe hash custody: wave-1 winners resolve from the FROZEN manifest
    # (independent of build-order bookkeeping); wave-2 winners from the
    # public executed-recipes log written by compose_wave2.
    wsha = None
    if os.path.exists(MANIF):
        for a in json.load(open(MANIF))["arms"]:
            if a.get("arm_id") == winner:
                s = a.get("recipe_sha256", "")
                if s and not s.startswith("composed-at-runtime"):
                    wsha = s
                break
    if wsha is None and os.path.exists(RLOG):
        for l in open(RLOG):
            r = json.loads(l)
            if r.get("arm_id") == winner:
                wsha = r.get("recipe_sha256"); break
    if wsha is None:
        print(f"FATAL: cannot resolve recipe_sha256 for winner {winner} — custody chain incomplete")
        raise SystemExit(1)
    json.dump(dict(arm_id=winner, screening_clarity_delta=wcl,
                   screening_overall_delta=per_arm[winner]["overall"],
                   levers=nlev, recipe_sha256=wsha, scripts_rev=os.environ["GIT_REV"]),
              open(WINNERF, "w"), indent=2, sort_keys=True)
    print(f"winner.json written: {winner} (recipe_sha256={str(wsha)[:16]}…)")
print("\n".join(lines))
raise SystemExit(0 if outcome == "PROCEED" else 2)
PY
}

# ---------- frozen manifest resolution (needed by BOTH --verify and main flow;
# winner.json resolves wave-1 recipe hashes from the frozen manifest) ----------
MANIFEST="$SCRIPTS_DIR/arms-manifest.json"
[ -f "$MANIFEST" ] || MANIFEST="$(dirname "$(readlink -f "$0")")/../arms-manifest.json"
[ -f "$MANIFEST" ] || die "arms-manifest.json not found (expected at repo root)"
ACTUAL_MSHA=$(sha256sum "$MANIFEST" | cut -d' ' -f1)
[ "$ACTUAL_MSHA" = "$MANIFEST_SHA" ] || die "arms-manifest.json hash mismatch: $ACTUAL_MSHA != $MANIFEST_SHA — manifest is frozen by ADDENDUM-02"

# ---------- --verify ----------
# Recompute the screening verdict from the archived logs and byte-compare.
# Declared normalization (machine-local provenance only): scripts_rev=...
if [ "${1:-}" = "--verify" ]; then
  D="${2:-}"
  if [ -z "$D" ]; then D="$(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null | head -1 || true)"; fi
  [ -n "$D" ] && [ -f "$D/verdict_s.txt" ] || { echo "VERIFY: usage: --verify <run_dir> (no screening verdict archive found)"; exit 1; }
  note "verify: recomputing screening verdict from archived logs in $D (no network, no GPU)"
  GIT_REV="verify"
  TMPD="$(mktemp -d)"
  cp "$D"/screening_set.jsonl "$D"/gen_R.jsonl "$D"/judge_raw_screen.jsonl "$TMPD/" 2>/dev/null || true
  [ -f "$D/recipes_executed.jsonl" ] && cp "$D/recipes_executed.jsonl" "$TMPD/" || true
  set_paths "$TMPD"
  set +e
  run_verdict > /dev/null
  set -e
  python3 - "$D" "$TMPD" <<'PY'
import re, sys
a, b = sys.argv[1], sys.argv[2]
def norm(t): return re.sub(r"scripts_rev=\S+", "scripts_rev=NORMALIZED", t)
ta, tb = norm(open(a + "/verdict_s.txt").read()), norm(open(b + "/verdict_s.txt").read())
if ta != tb:
    import difflib
    print("\n".join(list(difflib.unified_diff(ta.splitlines(), tb.splitlines(), lineterm=""))[:20]))
    print("VERIFY: MISMATCH — investigate before trusting the archive", file=sys.stderr); sys.exit(1)
print("VERIFY: verdict_s.txt byte-identical (declared provenance normalized)")
print("VERIFY: ALL CHECKS PASSED")
PY
  RC=$?
  rm -rf "$TMPD"
  exit $RC
fi

# ---------- run bookkeeping: resume-or-create; COMPLETE re-entry guard ----------
note "0. run bookkeeping"
GIT_REV=$(git -C "$SCRIPTS_DIR" rev-parse --short=8 HEAD 2>/dev/null || echo nogit)
if [ -n "${STAGE07_OUT_DIR:-}" ]; then
  RUN_DIR="$STAGE07_OUT_DIR"; mkdir -p "$RUN_DIR"
else
  LATEST="$(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null | head -1 || true)"
  if [ -n "$LATEST" ] && [ -f "$LATEST/COMPLETE" ]; then
    echo "STAGE 07 already COMPLETE: $LATEST"
    echo "verdict: $LATEST/verdict_s.txt  (to recompute: bash stages/07-lever-screening.sh --verify)"
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

# ---------- preflight ----------
note "1. time / host / GPU / engine anchors (L1)"
date -u
hostname || true
echo "scripts_rev=$GIT_REV"
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1 || true
if [ "${STAGE07_SKIP_SERVER:-0}" != "1" ]; then
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

# manifest + recipes custody check (three-layer disclosure: hashes public, bodies private)
# (manifest path + hash already asserted above, before the --verify branch)
echo "arms-manifest.json: sha256 verified ($MANIFEST_SHA)"
[ -f "$RECIPES_FILE" ] || die "private recipes file missing: $RECIPES_FILE — place it on the pod (chmod 600) before running; it is never committed"
PERMS=$(stat -c %a "$RECIPES_FILE" 2>/dev/null || echo "?")
[ "$PERMS" = "600" ] || echo "WARNING: $RECIPES_FILE permissions are $PERMS (expected 600)"

[ -f "$KEY_FILE" ] || die "judge key not found at $KEY_FILE (same pod-side pattern as Pilot 002)"
python3 -c "import httpx" 2>/dev/null || pip install -q httpx
echo "banner: PILOT 003 STAGE 07 — LEVER SCREENING (indicative phase; single-shot confirm is stage 08)"
START_TS=$(date +%s)

# ---------- phase 2: screening set (built deterministically, asserted disjoint) ----------
note "2. screening set (seed $SCREEN_SEED, $N_SCREEN items, disjoint from frozen 150)"

# locate the frozen 150 for the disjointness assertion (never judged here)
FROZEN_SRC="${STAGE07_FROZEN_JSONL:-}"
if [ -z "$FROZEN_SRC" ]; then
  FROZEN_SRC="$(ls -t "$LOGS_DIR"/*/05-quality-gate/run_*/frozen_set.jsonl "$LOGS_DIR"/*/06-quality-gate/run_*/frozen_set.jsonl 2>/dev/null | head -1 || true)"
fi
[ -n "$FROZEN_SRC" ] || die "frozen 150 not found in the logs archive (needed for the disjointness assertion)"
ACTUAL_FSHA=$(sha256sum "$FROZEN_SRC" | cut -d' ' -f1)
if [ "${STAGE07_SKIP_FROZEN_SHA:-0}" = "1" ]; then
  echo "TEST HOOK: STAGE07_SKIP_FROZEN_SHA=1 — sealed frozen-hash assert skipped (sandbox only; actual=$ACTUAL_FSHA)"
else
  [ "$ACTUAL_FSHA" = "$FROZEN_SHA" ] || die "frozen set hash mismatch: $ACTUAL_FSHA != $FROZEN_SHA"
fi

SCREEN_JSONL="$SCREEN_JSONL" SCREEN_SEED="$SCREEN_SEED" N_SCREEN="$N_SCREEN" \
FROZEN_SRC="$FROZEN_SRC" MODEL="$MODEL" python3 - <<'PY'
import hashlib, json, os, random, sys

SCREEN = os.environ["SCREEN_JSONL"]
SEED = int(os.environ["SCREEN_SEED"])
N = int(os.environ["N_SCREEN"])

def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest()

frozen_prompts = {hashlib.sha256(json.loads(l)["prompt"].encode()).hexdigest()
                  for l in open(os.environ["FROZEN_SRC"]) if l.strip()}

existing = []
if os.path.exists(SCREEN):
    existing = [json.loads(l) for l in open(SCREEN) if l.strip()]

if len(existing) == N:
    print(f"screening set already present: {len(existing)} items — resume, no rebuild")
else:
    # Generator body identical in construction to the Pilot 001 frozen-set
    # generator (forms, pools, tier targeting); different seed and item ids.
    rng = random.Random(SEED)
    DOC_POOL = [
        "The {t} report describes quarter-over-quarter changes in {m}, noting that {a} rose by {n}% while {b} fell by {k}%.",
        "In section {s}, the authors argue that {m} depends primarily on {a}, citing measurements collected over {n} months.",
        "Field observations in region {s} indicate that {a} interacts with {b} when {m} exceeds {n} units.",
        "The committee reviewed {n} submissions on {m} and flagged {k} of them for inconsistencies in {a}.",
        "Historical records show that between year {n} and year {k}, {m} shifted from {a}-dominated to {b}-dominated regimes.",
        "Operators observed that raising {a} by {n}% reduced {b} latency by {k}%, but only when {m} remained below threshold {s}.",
        "Appendix {s} lists {n} edge cases where {m} diverges from the nominal model; each involves {a} exceeding {b}.",
        "The whitepaper compares {a} and {b} under {m} constraints, concluding that hybrid schemes outperform either alone by {n}%.",
    ]
    CODE_POOL = [
        "def process_{f}(items, limit={n}):\n    total = 0\n    for it in items:\n        if it.value > limit:\n            total += it.value\n    return total",
        "class {F}Store:\n    def __init__(self, capacity={n}):\n        self.capacity = capacity\n        self.data = {{}}\n    def put(self, key, value):\n        if len(self.data) >= self.capacity:\n            self.data.pop(next(iter(self.data)))\n        self.data[key] = value",
        "def fetch_{f}(session, url, retries={k}):\n    for attempt in range(retries):\n        try:\n            return session.get(url, timeout={n})\n        except Exception:\n            time.sleep(2 ** attempt)\n    return None",
        "async def stream_{f}(queue):\n    while True:\n        item = await queue.get()\n        if item is None:\n            break\n        await handle_{f}(item, batch_size={n})",
    ]
    ART_POOL = [
        "Analysts noted on day {n} that the {t} market reacted strongly to the announcement, with {a} outperforming {b} by {k} points.",
        "The city council released a {n}-page plan covering {a}, {b}, and phased timelines stretching to year {k}.",
        "Researchers at institute {s} published results showing {a} improving {m} outcomes by {n}% in a cohort of {k} participants.",
        "Critics of the proposal argue that {m} targets are unachievable without restructuring {a}; supporters point to pilot {s} as counterevidence.",
        "In an interview, the lead engineer said the team spent {n} weeks isolating a regression caused by {a} interacting with {b}.",
        "The editorial compares coverage of {m} across {n} outlets and finds framing differences concentrated on {a} versus {b}.",
    ]
    VARS = dict(
        t=["annual", "interim", "technical", "policy", "field", "audit"],
        m=["throughput", "efficiency", "compliance", "reliability", "demand", "stability"],
        a=["alpha", "beta", "gamma", "delta", "sigma", "kappa"],
        b=["omega", "rho", "tau", "zeta", "eta", "iota"],
        s=["7", "12", "C", "D4", "north", "west"],
        f=["orders", "metrics", "events", "records", "images", "signals"],
    )
    def fill(t):
        return t.format(**{k: rng.choice(v) if isinstance(v, list) else v for k, v in VARS.items()},
                        n=rng.randint(3, 97), k=rng.randint(2, 48),
                        F=rng.choice(["Order", "Metric", "Event", "Record"]))
    def build_prompt(form, target_tokens, tok):
        if form == "doc_qa":
            header = "You are given several documents. Answer the question at the end using only the documents.\n\n"
            i = 0; body = ""
            while True:
                body += f"[Doc {i+1}]\n" + " ".join(fill(rng.choice(DOC_POOL)) for _ in range(6)) + "\n\n"
                prompt = (header + body +
                          "Question: Based on the documents, how does alpha relate to throughput when efficiency exceeds its threshold?\nAnswer:")
                if len(tok.encode(prompt)) >= target_tokens: return prompt
                i += 1
        if form == "code_completion":
            header = "Below is a repository snapshot. Complete the last function so it fits the codebase style.\n\n"
            i = 0; body = ""
            while True:
                body += f"# file: module_{i}.py\n" + fill(rng.choice(CODE_POOL)) + "\n\n"
                prompt = (header + body +
                          "# file: main.py\ndef compute_pipeline(records):\n    # complete this function\n")
                if len(tok.encode(prompt)) >= target_tokens: return prompt
                i += 1
        header = "Read the following article and write a concise summary (3-5 sentences).\n\n"
        body = ""
        while True:
            body += " ".join(fill(rng.choice(ART_POOL)) for _ in range(8)) + "\n\n"
            prompt = header + body + "Summary:"
            if len(tok.encode(prompt)) >= target_tokens: return prompt

    # 40 items: doc_qa 5/5/4, code 5/4/4, summarization 4/4/5 across tiers
    PLAN = ([("doc_qa", 4096)] * 5 + [("doc_qa", 8192)] * 5 + [("doc_qa", 16384)] * 4 +
            [("code_completion", 4096)] * 5 + [("code_completion", 8192)] * 4 + [("code_completion", 16384)] * 4 +
            [("summarization", 4096)] * 4 + [("summarization", 8192)] * 4 + [("summarization", 16384)] * 5)
    assert len(PLAN) == N, f"plan size {len(PLAN)} != {N}"

    from transformers import AutoTokenizer
    tok = AutoTokenizer.from_pretrained(os.environ["MODEL"])
    with open(SCREEN, "w") as fp:
        for idx, (form, tier) in enumerate(PLAN):
            prompt = build_prompt(form, tier, tok)
            mt = rng.randint(200, 800)
            rec = dict(request_id=f"sc-{idx:03d}", form=form, tier_target=tier,
                       rep=0, max_tokens=mt, prompt=prompt)
            fp.write(json.dumps(rec, sort_keys=True) + "\n"); fp.flush()
    print(f"screening set built: {N} items, seed={SEED}")

# disjointness assertion (hard gate, declared in ADDENDUM-02)
overlap = 0
for l in open(SCREEN):
    p = json.loads(l)["prompt"]
    if hashlib.sha256(p.encode()).hexdigest() in frozen_prompts:
        overlap += 1
if overlap:
    print(f"FATAL: screening set overlaps the frozen 150 on {overlap} prompts — refusing to proceed")
    sys.exit(1)
print(f"disjointness assertion: 0/{N} prompts collide with the frozen 150 — OK")
print(f"screening_set_sha256={sha(SCREEN)}")
PY

# ---------- phase 3: calibration texts (domain-matched, disjoint, declared) ----------
note "3. calibration texts (seed $CALIB_SEED, 256 samples, same synthetic family — declared)"
CALIB_JSONL="$CALIB_JSONL" CALIB_SEED="$CALIB_SEED" SCREEN_JSONL="$SCREEN_JSONL" \
FROZEN_SRC="$FROZEN_SRC" python3 - <<'PY'
import hashlib, json, os, random, sys
CALIB = os.environ["CALIB_JSONL"]
SEED = int(os.environ["CALIB_SEED"])
seen = set()
for p in (os.environ["SCREEN_JSONL"], os.environ["FROZEN_SRC"]):
    for l in open(p):
        if l.strip(): seen.add(hashlib.sha256(json.loads(l)["prompt"].encode()).hexdigest())
if os.path.exists(CALIB) and sum(1 for _ in open(CALIB)) == 256:
    print("calibration texts already present — resume")
else:
    rng = random.Random(SEED)
    CAL_POOL = [
        "The {t} note on {m} records that {a} moved by {n}% while {b} held near {k} units.",
        "Reviewers found {n} inconsistencies in section {s}, mostly where {a} met {b}.",
        "Under {m} constraints, {a} outperformed {b} by {n}% across {k} trials.",
        "The {t} summary links {m} to {a}, with {b} lagging by {k} points in region {s}.",
    ]
    VARS = dict(t=["annual", "interim", "technical", "policy", "field", "audit"],
                m=["throughput", "efficiency", "compliance", "reliability", "demand", "stability"],
                a=["alpha", "beta", "gamma", "delta", "sigma", "kappa"],
                b=["omega", "rho", "tau", "zeta", "eta", "iota"],
                s=["7", "12", "C", "D4", "north", "west"])
    def fill(t):
        return t.format(**{k: rng.choice(v) for k, v in VARS.items()},
                        n=rng.randint(3, 97), k=rng.randint(2, 48))
    with open(CALIB, "w") as fp:
        for i in range(256):
            text = " ".join(fill(rng.choice(CAL_POOL)) for _ in range(12))
            h = hashlib.sha256(text.encode()).hexdigest()
            if h in seen:
                print(f"FATAL: calibration text collides with eval prompts at sample {i}")
                sys.exit(1)
            fp.write(json.dumps(dict(idx=i, text=text, sha256=h), sort_keys=True) + "\n")
    print("calibration texts built: 256 samples (disjoint asserted at build)")
print(f"calibration_texts_sha256={hashlib.sha256(open(CALIB,'rb').read()).hexdigest()}")
PY

# ---------- recipe machinery: verify custody, build checkpoints ----------
# Prints the recipe for ARM_ID to stdout as canonical JSON (used by the builder).
get_recipe() {   # $1 = arm_id
  RECIPES_FILE="$RECIPES_FILE" MANIFEST_SHA="$MANIFEST_SHA" ARM_ID="$1" python3 - <<'PY'
import hashlib, json, os, sys
doc = json.load(open(os.environ["RECIPES_FILE"]))
arm = os.environ["ARM_ID"]
recs = doc["recipes"]
if arm in recs:
    r = recs[arm]
else:
    # wave-2 slot: recipe is composed at runtime and kept in the POD-LOCAL
    # recipe log (never pushed); reading it back keeps resume deterministic
    r = None
    rlog = os.environ.get("LOCAL_RECIPE_LOG", "")
    if rlog and os.path.exists(rlog):
        for l in open(rlog):      # append-only log: the LAST match is the current composition
            e = json.loads(l)
            if e.get("arm_id") == arm:
                r = e.get("recipe")
    if r is None:
        sys.exit(f"recipe for {arm} not found in the pod-local log (wave-2 recipes are composed after wave-1 judging)")
sha = hashlib.sha256(json.dumps(r, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
print(json.dumps(dict(arm_id=arm, recipe=r, recipe_sha256=sha)))
PY
}

# build_checkpoint ARM_ID → echoes ckpt dir; no-op for base-model arms
build_checkpoint() {   # $1 = arm_id
  local arm="$1"
  local rjson; rjson="$(LOCAL_RECIPE_LOG="$LOCAL_RECIPE_LOG" get_recipe "$arm")" || die "cannot resolve recipe for $arm"
  local uses_base; uses_base="$(printf '%s' "$rjson" | python3 -c "import json,sys; print(json.load(sys.stdin)['recipe']['uses_base_model'])")"
  if [ "$uses_base" = "True" ]; then echo ""; return 0; fi
  local cdir="$CKPT_ROOT/$arm"
  if [ -f "$CKPT_LOG" ] && grep -q "\"arm_id\": \"$arm\"" "$CKPT_LOG" 2>/dev/null && [ -d "$cdir" ]; then
    echo "$cdir"; return 0
  fi
  if [ "${STAGE07_MOCK_BUILD:-0}" = "1" ]; then
    mkdir -p "$cdir"; echo '{"mock": true}' > "$cdir/config.json"
    echo "TEST HOOK: mock checkpoint for $arm at $cdir" >&2; echo "$cdir"; return 0
  fi
  FREE_GB=$(df --output=avail -BG "$HOME" | tail -1 | tr -dc '0-9')
  [ "${FREE_GB:-0}" -ge 50 ] || die "disk headroom < 50GB for checkpoint build (14B fp8 ckpt ≈ 16GB on top of base weights)"
  note "building checkpoint for $arm (llmcompressor oneshot; builder version is provenance — the measured artifact is the checkpoint hash)"
  RJSON="$rjson" CKPT_DIR="$cdir" CALIB_JSONL="$CALIB_JSONL" MODEL="$MODEL" MODEL_REV="$MODEL_REV" \
  RECIPE_LOG="$RECIPE_LOG" CKPT_LOG="$CKPT_LOG" python3 - <<'PY'
import hashlib, json, os, time
spec = json.loads(os.environ["RJSON"])
arm, recipe = spec["arm_id"], spec["recipe"]
cdir = os.environ["CKPT_DIR"]
calib = [json.loads(l)["text"] for l in open(os.environ["CALIB_JSONL"])]
try:
    import llmcompressor
    from llmcompressor import oneshot
    from llmcompressor.modifiers.quantization import QuantizationModifier
    ver = llmcompressor.__version__
except ImportError:
    raise SystemExit("llmcompressor not installed — install it on the pod (pip install llmcompressor); builder version is recorded as provenance")
mods = []
if "smoothing" in recipe:
    from llmcompressor.modifiers.smoothquant import SmoothQuantModifier
    s = recipe["smoothing"]
    mods.append(SmoothQuantModifier(smoothing_strength=s["strength"]))
q = recipe["quantization"]
mods.append(QuantizationModifier(targets=q["targets"], scheme=q["scheme"], ignore=q["ignore"]))
t0 = time.time()
oneshot(model=os.environ["MODEL"], revision=os.environ["MODEL_REV"],
        dataset=[{"text": t} for t in calib], recipe=mods,
        output_dir=cdir,
        num_calibration_samples=recipe["calibration"]["n_samples"],
        max_seq_length=recipe["calibration"]["max_seq_len"])
def tree_sha(root):
    h = hashlib.sha256()
    for dp, _, fns in sorted(os.walk(root)):
        for fn in sorted(fns):
            p = os.path.join(dp, fn)
            rel = os.path.relpath(p, root)
            h.update(rel.encode())
            with open(p, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 22), b""):
                    h.update(chunk)
    return h.hexdigest()
csha = tree_sha(cdir)
# custody split (three-layer disclosure): the public archive records hashes
# and lever class labels ONLY; the full recipe body stays pod-local.
public = dict(arm_id=arm, levers=recipe.get("levers", []),
              recipe_sha256=spec["recipe_sha256"], llmcompressor_version=ver,
              checkpoint_sha256=csha, build_seconds=round(time.time() - t0, 1),
              ts_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
for path in (os.environ["RECIPE_LOG"], os.environ["CKPT_LOG"]):
    with open(path, "a") as f:
        f.write(json.dumps(public, sort_keys=True) + "\n")
os.makedirs(os.path.dirname(os.environ["LOCAL_RECIPE_LOG"]), exist_ok=True)
with open(os.environ["LOCAL_RECIPE_LOG"], "a") as f:
    f.write(json.dumps(dict(public, recipe=recipe), sort_keys=True) + "\n")
print(f"checkpoint built: {arm} sha256={csha[:16]}… llmcompressor={ver} ({public['build_seconds']}s)")
PY
  echo "$cdir"
}

# ---------- server lifecycle (same craft as stage 05) ----------
start_server() {   # $1 = arm label, $2 = model path, $3 = extra args
  local arm="$1" mpath="$2" extra="$3"
  local slog="$RUN_DIR/server_${arm}.log"
  echo "starting server for $arm ($mpath $extra; prefix caching OFF)"
  # shellcheck disable=SC2086
  nohup python -m vllm.entrypoints.openai.api_server \
    --model "$mpath" $([ "$mpath" = "$MODEL" ] && echo --revision "$MODEL_REV") \
    --no-enable-prefix-caching --max-model-len "$MAX_MODEL_LEN" \
    $extra --port "$PORT" > "$slog" 2>&1 &
  echo $! > "$RUN_DIR/server.pid"
  local waited=0
  until curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do
    sleep 10; waited=$((waited+10))
    if [ "$waited" -ge 2400 ]; then die "server failed to become healthy in 2400s — see $slog"; fi
    if ! kill -0 "$(cat "$RUN_DIR/server.pid")" 2>/dev/null; then die "server process died — see $slog"; fi
  done
  echo "server for $arm healthy after ${waited}s"
  echo "server_argv: vllm serve $mpath $([ "$mpath" = "$MODEL" ] && echo --revision $MODEL_REV) --no-enable-prefix-caching --max-model-len $MAX_MODEL_LEN $extra --port $PORT" \
    | sed 's/  */ /g' > "$RUN_DIR/server_argv_${arm}.txt"
}
stop_server() {
  [ -f "$RUN_DIR/server.pid" ] && kill "$(cat "$RUN_DIR/server.pid")" 2>/dev/null || true
  sleep 5
  pkill -f "vllm.entrypoints.openai.api_server" 2>/dev/null || true
}

# ---------- generation (serving mode, natural stopping; same craft as stage 05) ----------
generate_arm() {   # $1 = arm label, $2 = model path, $3 = extra args, $4 = out jsonl
  local arm="$1" mpath="$2" extra="$3" gen_jsonl="$4"
  note "generation: $arm (screening set, concurrency $GEN_CONC)"
  if [ "$({ [ -f "$gen_jsonl" ] && wc -l < "$gen_jsonl"; } 2>/dev/null || echo 0)" -ge "$N_SCREEN" ]; then
    echo "  $arm: already generated ($N_SCREEN rows) — resume skip"; return 0
  fi
  if [ "${STAGE07_SKIP_SERVER:-0}" != "1" ]; then
    start_server "$arm" "$mpath" "$extra"
    trap stop_server EXIT
  else
    echo "STAGE07_SKIP_SERVER=1 — using external server on port $PORT (test mode)"
  fi
  SCREEN_JSONL="$SCREEN_JSONL" GEN_JSONL="$gen_jsonl" ARM="$arm" \
  MODEL="$mpath" PORT="$PORT" GEN_CONC="$GEN_CONC" \
  MAX_SECONDS="$MAX_SECONDS" START_TS="$START_TS" GIT_REV="$GIT_REV" python3 - <<'PY'
import asyncio, datetime, hashlib, json, os, time
import httpx

MODEL  = os.environ["MODEL"]; SCREEN = os.environ["SCREEN_JSONL"]
GEN    = os.environ["GEN_JSONL"]; ARM = os.environ["ARM"]
PORT   = os.environ["PORT"]; CONC = int(os.environ["GEN_CONC"])
MAX_SEC= int(os.environ["MAX_SECONDS"]); T0 = int(os.environ["START_TS"])
REQ_TO = 900.0

items = [json.loads(l) for l in open(SCREEN) if l.strip()]
done = set()
if os.path.exists(GEN):
    for l in open(GEN):
        if l.strip(): done.add(json.loads(l)["request_id"])
todo = [r for r in items if r["request_id"] not in done]
print(f"{ARM}: {len(done)} already generated, {len(todo)} to go", flush=True)
if not todo:
    raise SystemExit(0)

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
                        print(f"  {ARM}: {len(done)+n_done}/{len(items)} "
                              f"(last: {rec['request_id']}, {row['output_tokens']} tok, {wall:.1f}s)", flush=True)
        await asyncio.gather(*(one(rec) for rec in todo))

asyncio.run(main())
print(f"{ARM} generation phase done", flush=True)
PY
  [ "${STAGE07_SKIP_SERVER:-0}" != "1" ] && stop_server || true
}

# ---------- blind judging on the screening set (single screening judge) ----------
judge_arms() {   # $@ = arm labels to judge (R is the reference, never judged)
  local arms="$*"
  SCREEN_JSONL="$SCREEN_JSONL" GEN_R_JSONL="$GEN_R_JSONL" RUN_DIR="$RUN_DIR" \
  JUDGE_RAW_JSONL="$JUDGE_RAW_JSONL" BLIND_SEED_SCR="$BLIND_SEED_SCR" \
  KEY_FILE="$KEY_FILE" BUDGET_USD="$BUDGET_USD" MAX_SECONDS="$MAX_SECONDS" START_TS="$START_TS" \
  OR_BASE_URL="${OR_BASE_URL:-https://openrouter.ai/api/v1}" GIT_REV="$GIT_REV" \
  ARMS="$arms" N_SCREEN="$N_SCREEN" \
  SCREEN_JUDGE_CANDIDATES_STR="$(printf '%s\n' "${SCREEN_JUDGE_CANDIDATES[@]}")" \
  FALLBACK_PRICE_IN="$FALLBACK_PRICE_IN" FALLBACK_PRICE_OUT="$FALLBACK_PRICE_OUT" python3 - <<'PY'
import hashlib, json, os, time, datetime
import urllib.request, urllib.error

SCREEN  = os.environ["SCREEN_JSONL"]
GENR    = os.environ["GEN_R_JSONL"]
RUN_DIR = os.environ["RUN_DIR"]
JRAW    = os.environ["JUDGE_RAW_JSONL"]
BLSEED  = os.environ["BLIND_SEED_SCR"]
KEYF    = os.environ["KEY_FILE"]
BUDGET  = float(os.environ["BUDGET_USD"])
MAX_SEC = int(os.environ["MAX_SECONDS"])
T0      = int(os.environ["START_TS"])
ORBASE  = os.environ["OR_BASE_URL"].rstrip("/")
ARMS    = os.environ["ARMS"].split()
AXES    = ["correctness", "instruction_following", "clarity"]

CANDIDATES = []
for line in os.environ["SCREEN_JUDGE_CANDIDATES_STR"].splitlines():
    if line.strip():
        m, ci, co = line.split("|")
        CANDIDATES.append((m, float(ci), float(co)))
FALLBACK_PRICE = (float(os.environ["FALLBACK_PRICE_IN"]), float(os.environ["FALLBACK_PRICE_OUT"]))

KEY = open(KEYF).read().strip()
if not KEY.startswith("sk-or-") and "openrouter.ai" in ORBASE:
    print("REFUSED: key file does not look like an OpenRouter key"); raise SystemExit(1)

def call_api(model, messages, max_tokens, timeout=120):
    # Amendment-01 mechanics (Pilot 002): reasoning excluded; null content = error
    body = json.dumps(dict(model=model, messages=messages, temperature=0,
                           max_tokens=max_tokens,
                           reasoning={"exclude": True})).encode()
    req = urllib.request.Request(
        f"{ORBASE}/chat/completions", data=body,
        headers={"Authorization": f"Bearer {KEY}",
                 "Content-Type": "application/json",
                 "HTTP-Referer": "https://github.com/effiq/pilot003",
                 "X-Title": "effiq-pilot003-lever-screening"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())

# screening judge: probe cheapest-first; the selection is persisted and sticky
JFILE = os.path.join(RUN_DIR, "screening_judge.txt")
judge_model, pin, pout = None, None, None
for cand, cin, cout in CANDIDATES:
    try:
        resp = call_api(cand, [dict(role="user", content="Reply with the single word: ok")], max_tokens=4, timeout=60)
        _txt = resp["choices"][0]["message"]["content"]
        if not _txt or not str(_txt).strip():
            raise ValueError("empty probe content")
        judge_model, pin, pout = cand, cin, cout
        print(f"screening judge reachable: {cand}")
        break
    except Exception as e:
        print(f"screening judge candidate {cand}: unavailable ({type(e).__name__}: {e})")
if judge_model is None:
    print("REFUSED: no screening judge reachable — check key balance/region; nothing judged.")
    raise SystemExit(1)
if os.path.exists(JFILE):
    prev = open(JFILE).read().strip()
    if prev != judge_model:
        print(f"REFUSED: previously selected screening judge {prev} is not the reachable one now ({judge_model}) — owner decision required")
        raise SystemExit(1)
else:
    open(JFILE, "w").write(judge_model + "\n")
    print(f"screening judge selected and pinned: {judge_model}")

screen = [json.loads(l) for l in open(SCREEN) if l.strip()]
gR = {json.loads(l)["request_id"]: json.loads(l) for l in open(GENR) if l.strip()}
gens = {}
for a in ARMS:
    p = os.path.join(RUN_DIR, f"gen_{a}.jsonl")
    gens[a] = {json.loads(l)["request_id"]: json.loads(l) for l in open(p) if l.strip()} if os.path.exists(p) else {}

judged = set()
if os.path.exists(JRAW):
    for l in open(JRAW):
        if l.strip():
            r = json.loads(l); judged.add((r["request_id"], r["arm_id"]))

def est_cost(ptoks, ctoks):
    return (ptoks * pin + ctoks * pout) / 1e6
spent = 0.0
if os.path.exists(JRAW):
    spent = sum(est_cost(json.loads(l).get("prompt_tokens", 0), json.loads(l).get("completion_tokens", 0))
                for l in open(JRAW) if l.strip())
print(f"judge resume: {len(judged)} rows already judged, est. spent ${spent:.3f} (guard ${BUDGET:.0f})")

def blind(arm, rid):
    return hashlib.sha256(f"{BLSEED}|{arm}|{rid}".encode()).digest()[0] & 1 == 1

# Byte-identical to the stage-05 judge prompt (Pilot 002 craft, unchanged).
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
    for a in ARMS:
        for rec in screen:
            rid = rec["request_id"]
            if (rid, a) in judged or rid not in gR or rid not in gens[a]:
                continue
            if time.time() - T0 > MAX_SEC:
                print("TIME GUARD: judging aborted; partial log preserved — re-run to resume"); break
            if spent > BUDGET:
                print(f"BUDGET GUARD: est. spend ${spent:.2f} exceeds ${BUDGET:.0f}; aborting (owner decision required)"); break
            ref_first = blind(a, rid)
            r1, r2 = ((gR[rid]["output_text"], gens[a][rid]["output_text"]) if ref_first
                      else (gens[a][rid]["output_text"], gR[rid]["output_text"]))
            msgs = [dict(role="system", content=SYSTEM),
                    dict(role="user", content=TEMPLATE.format(prompt=rec["prompt"], r1=r1, r2=r2))]
            ok = False
            for attempt, pause in enumerate((5, 15, 30)):
                try:
                    resp = call_api(judge_model, msgs, max_tokens=1024)
                    content = resp["choices"][0]["message"]["content"]
                    if content is None:
                        raise ValueError("null content; raw=" + json.dumps(resp)[:200])
                    scores = parse_scores(content)
                    u = resp.get("usage", {})
                    row = dict(request_id=rid, arm_id=a, judge_model=judge_model,
                               ref_is_response_1=ref_first,
                               scores_r1=scores["response_1"], scores_r2=scores["response_2"],
                               prompt_tokens=u.get("prompt_tokens", 0),
                               completion_tokens=u.get("completion_tokens", 0),
                               raw_content=content, scripts_rev=os.environ["GIT_REV"],
                               ts_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
                    fj.write(json.dumps(row, sort_keys=True) + "\n"); fj.flush()
                    spent += est_cost(row["prompt_tokens"], row["completion_tokens"])
                    n_new += 1; ok = True
                    if n_new % 20 == 0 or n_new == 1:
                        print(f"  judged {rid} arm {a}, est. spent ${spent:.3f}")
                    break
                except Exception as e:
                    print(f"  judge error on {rid} arm {a} (attempt {attempt+1}): {type(e).__name__}: {e}")
                    time.sleep(pause)
            if not ok:
                n_fail += 1
                print(f"  {rid} arm {a}: all retries failed — left for next resume")
print(f"judge phase done: new={n_new} failed={n_fail} est_spent=${spent:.3f}")
PY
}

# ---------- helper: arm serve parameters from the manifest ----------
arm_serve_params() {   # $1 = arm_id → prints "<uses_base> <serve_extra>"
  MANIFEST="$MANIFEST" ARM_ID="$1" python3 - <<'PY'
import json, os
man = json.load(open(os.environ["MANIFEST"]))
for a in man["arms"]:
    if a["arm_id"] == os.environ["ARM_ID"]:
        print(("BASE" if a["uses_base_model"] else "CKPT"), a["serve_extra"]); break
else:
    raise SystemExit(f"arm {os.environ['ARM_ID']} not in manifest")
PY
}

# run_arm ARM_ID: build (if needed) → serve → generate → delete checkpoint
run_arm() {   # $1 = arm_id
  local arm="$1"
  local gen_jsonl="$RUN_DIR/gen_${arm}.jsonl"
  if [ "$({ [ -f "$gen_jsonl" ] && wc -l < "$gen_jsonl"; } 2>/dev/null || echo 0)" -ge "$N_SCREEN" ]; then
    echo "arm $arm: generation already complete — skip"; return 0
  fi
  read -r kind extra <<<"$(arm_serve_params "$arm")"
  if [ "$kind" = "BASE" ]; then
    generate_arm "$arm" "$MODEL" "$extra" "$gen_jsonl"
  else
    local cdir
    cdir="$(build_checkpoint "$arm")" || die "checkpoint build failed for $arm"
    [ -n "$cdir" ] || die "empty checkpoint dir for $arm"
    generate_arm "$arm" "$cdir" "$extra" "$gen_jsonl"
    if [ "${STAGE07_MOCK_BUILD:-0}" != "1" ]; then
      rm -rf "$cdir" && echo "arm $arm: checkpoint deleted after generation (hash anchor in checkpoints.jsonl)"
    fi
  fi
}

# ---------- wave-2 composition (deterministic rule, frozen) ----------
compose_wave2() {
  JUDGE_RAW_JSONL="$JUDGE_RAW_JSONL" RECIPE_LOG="$RECIPE_LOG" RECIPES_FILE="$RECIPES_FILE" \
  LOCAL_RECIPE_LOG="$LOCAL_RECIPE_LOG" N_SCREEN="$N_SCREEN" python3 - <<'PY'
import hashlib, json, os, statistics, sys
JRAW = os.environ["JUDGE_RAW_JSONL"]; N = int(os.environ["N_SCREEN"])
rows = [json.loads(l) for l in open(JRAW) if l.strip()]
AXES = ["correctness", "instruction_following", "clarity"]
singles = ["a2-smooth", "a3-calib-static", "a4-exempt-attn", "a5-exempt-down"]
per = {}
for a in singles:
    rs = [r for r in rows if r["arm_id"] == a]
    if len(rs) < N:
        sys.exit(f"wave-1 judging incomplete for {a} ({len(rs)}/{N}) — judge first")
    cl, ov = [], []
    for r in rs:
        sR = r["scores_r1"] if r["ref_is_response_1"] else r["scores_r2"]
        sA = r["scores_r2"] if r["ref_is_response_1"] else r["scores_r1"]
        cl.append(sA["clarity"] - sR["clarity"])
        ov.append(statistics.mean(sA[x] - sR[x] for x in AXES))
    per[a] = (statistics.mean(cl), statistics.mean(ov))
rank = sorted(singles, key=lambda a: (-per[a][0], -per[a][1], a))
top1, top2, top3 = rank[0], rank[1], rank[2]
print(f"wave-1 single-lever ranking (clarity): " + " > ".join(f"{a}({per[a][0]:+.3f})" for a in rank))

recs = json.load(open(os.environ["RECIPES_FILE"]))["recipes"]
def merge(a, b, arm_id):
    ra, rb = recs[a], recs[b]
    qa, qb = ra["quantization"], rb["quantization"]
    scheme = "FP8" if "FP8" in (qa["scheme"], qb["scheme"]) else qa["scheme"]
    over = qa.get("scheme_overrides") or qb.get("scheme_overrides")
    ignore = list(dict.fromkeys(qa["ignore"] + qb["ignore"]))
    r = dict(arm_id=arm_id, builder="llmcompressor-oneshot",
             levers=sorted(set(ra.get("levers", []) + rb.get("levers", []))),
             quantization=dict(targets="Linear", scheme=scheme, ignore=ignore),
             calibration=ra["calibration"],
             serve_extra="--quantization compressed-tensors", uses_base_model=False)
    if over: r["quantization"]["scheme_overrides"] = over
    sm = ra.get("smoothing") or rb.get("smoothing")
    if sm: r["smoothing"] = sm
    return r

existing = set()
if os.path.exists(os.environ["RECIPE_LOG"]):
    for l in open(os.environ["RECIPE_LOG"]):
        existing.add(json.loads(l).get("arm_id"))
os.makedirs(os.path.dirname(os.environ["LOCAL_RECIPE_LOG"]), exist_ok=True)
for arm_id, pair in (("a7-w2", (top1, top2)), ("a8-w2", (top1, top3))):
    if arm_id in existing:
        print(f"{arm_id}: composed recipe already archived — resume skip"); continue
    r = merge(pair[0], pair[1], arm_id)
    sha = hashlib.sha256(json.dumps(r, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    # custody split: hashes + labels to the public archive; full body pod-local only
    with open(os.environ["RECIPE_LOG"], "a") as f:
        f.write(json.dumps(dict(arm_id=arm_id, composed_from=list(pair), levers=r["levers"],
                                recipe_sha256=sha), sort_keys=True) + "\n")
    with open(os.environ["LOCAL_RECIPE_LOG"], "a") as f:
        f.write(json.dumps(dict(arm_id=arm_id, composed_from=list(pair), levers=r["levers"],
                                recipe=r, recipe_sha256=sha), sort_keys=True) + "\n")
    print(f"{arm_id}: composed from {pair[0]} + {pair[1]} → recipe_sha256={sha[:16]}…")
PY
}

# ---------- orchestration ----------
note "4. reference arm R (BF16 defaults) on the screening set"
generate_arm "R" "$MODEL" "" "$GEN_R_JSONL"

note "5. wave 1: 6 arms (control + 5 single levers + all-combo)"
for arm in a1-control a2-smooth a3-calib-static a4-exempt-attn a5-exempt-down a6-all; do
  [ $(( $(date +%s) - START_TS )) -lt "$MAX_SECONDS" ] || die "time rail tripped — re-run to resume"
  run_arm "$arm"
done

note "6. judging wave 1 (screening judge)"
judge_arms a1-control a2-smooth a3-calib-static a4-exempt-attn a5-exempt-down a6-all

note "7. wave 2: deterministic composition from wave-1 ranking"
compose_wave2
for arm in a7-w2 a8-w2; do
  [ $(( $(date +%s) - START_TS )) -lt "$MAX_SECONDS" ] || die "time rail tripped — re-run to resume"
  run_arm "$arm"
done

note "8. judging wave 2"
judge_arms a7-w2 a8-w2

# ---------- verdict + completeness gate ----------
note "9. screening verdict (recomputed from archived logs)"
set +e
run_verdict
RC_V=$?
set -e

if [ "$RC_V" -eq 0 ] || [ "$RC_V" -eq 2 ]; then
  date -u > "$RUN_DIR/COMPLETE"
  if [ "$RC_V" -eq 0 ]; then
    echo "STAGE 07 LEVER SCREENING: COMPLETE — outcome PROCEED (winner in winner.json; next: stage 08 single-shot confirm)"
  else
    echo "STAGE 07 LEVER SCREENING: COMPLETE — outcome SCREENING-EXHAUSTED (publishable FAIL; see verdict_s.txt)"
  fi
  exit 0
else
  echo "STAGE 07 LEVER SCREENING: INCOMPLETE (no COMPLETE marker — re-run the same command to resume)"
  exit 1
fi
