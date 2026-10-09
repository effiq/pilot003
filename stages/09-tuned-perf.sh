#!/usr/bin/env bash
# =============================================================================
# Pilot 003 — STAGE 09: TUNED-PERFORMANCE GATE (performance half of the verdict)
#
# Pre-registered in PREREG-ADDENDUM-02. Repairing quality is not allowed to
# spend the speedup: the stage-08 winning configuration must keep a paired
# speedup whose 95% CI lower bound is >= 1.50x over BF16 under the SAME
# replayed production trace as Pilot 002 (stage-01 plans, stage-02 operating
# point, both reused by hash). The Protocol-Lock-compatible 1.20x result is
# reported alongside for continuity.
#
# Frozen rules:
#   - Requires stage 08 COMPLETE (winner + recipe custody chain archived).
#   - 6 formal runs replay slice pairs 1..6; within-run block-crossover
#     (odd runs A then C, even runs C then A); per-request rows identical
#     schema to Pilot 002 stage 03.
#   - No straddle extension is pre-registered for Pilot 003: the paired
#     bootstrap at n=6 decides. Declared, not improvised.
#   - Secondary gate (carried over): pooled P95 TPOT and P95 TTFT of arm C
#     must each not exceed arm A's by more than 5%.
#   - ANTI-P-HACKING: during measurement this stage prints DESCRIPTIVE
#     MEANS ONLY. The verdict phase runs only after all 6 RUN_COMPLETE
#     markers exist, and recomputes everything from raw JSONL.
#   - PILOT 003 VERDICT = stage-08 quality gate AND this performance gate.
#
# Fallback disclosure (carried): the Pilot 002 operating point is the
# lightest grid configuration (r=1/256, C=4); the shortfall disclosure
# follows the data into this verdict as well.
#
# Verify entry: bash stages/09-tuned-perf.sh --verify <run_dir>
#   Recomputes the verdict from raw archives and byte-compares (declared
#   normalization: archive paths, scripts_rev).
#
# Test hooks (sandbox only): STAGE09_OUT_DIR, STAGE09_SRC07_DIR,
#   STAGE09_SRC08_DIR, STAGE09_SKIP_SERVER, STAGE09_SKIP_PREFLIGHT,
#   STAGE09_MOCK_BUILD, STAGE09_CHOSEN_JSON, STAGE09_PLANS_DIR,
#   STAGE09_MANIFEST_JSON, PORT, RUNS, MAX_SECONDS, RECIPES_FILE, CKPT_ROOT
# =============================================================================
set -euo pipefail

MODEL="Qwen/Qwen2.5-14B-Instruct"
MODEL_REV="cf98f3b3bbb457ad9e2bb7baf9a0125b6b88caa8"   # L1 pinned
VLLM_PINNED="0.31.0"
GPU_EXPECT="L40S"
MAX_MODEL_LEN=32768
MAX_TOKENS_CAP=1024            # frozen L2 cap (Pilot 002 craft)
N_RUNS=6                       # frozen; no extension pre-registered for Pilot 003
THRESH=1.50                    # frozen perf gate (ADDENDUM-02): CI lower bound >= 1.50x
THRESH_PROTOCOL=1.20           # Protocol Lock continuity reference (reported)
BOOT_SEED=20262002             # same declared bootstrap seed as Pilot 002 stage 04
BOOT_N=100000
P95_TOL=1.05                   # secondary gate, carried over
SLO_TTFT_S=5.0                 # descriptive per-row SLO flag only
SLO_TPOT_MS=100.0
REQ_TIMEOUT_S=900
CLIENT_CONC="${CLIENT_CONC:-2048}"
FILLER_SEED=20261010           # same stream as stage-01 keep_u (frozen)
RUN_SEED_BASE=20264000         # Pilot 003 run seeds (distinct from 002's 20263000)
MAX_SECONDS="${MAX_SECONDS:-28800}"   # ~8 h rail (build + 12 blocks), resumable
PORT="${PORT:-8000}"           # test hook only
RUNS="${RUNS:-1 2 3 4 5 6}"    # test hook only

EFFIQ_HOME="${EFFIQ_HOME:-$HOME/effiq}"
LOGS_DIR="${LOGS_DIR:-$EFFIQ_HOME/pilot-logs}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$EFFIQ_HOME/pilot003}"
TRACE_DIR="${TRACE_DIR:-$EFFIQ_HOME/trace}"
PLANS_DIR="${STAGE09_PLANS_DIR:-$TRACE_DIR/plans}"
RECIPES_FILE="${RECIPES_FILE:-$HOME/pilot-env/arms-recipes.json}"
CKPT_ROOT="${CKPT_ROOT:-$HOME/effiq/p003-ckpt}"
STAGE_NAME="09-tuned-perf"
DATE_STR="$(date -u +%Y-%m-%d)"
T0=$(date +%s)

say()  { printf '\n\033[1;36m[stage09] %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[stage09][WARN] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[stage09][ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

check_time_rail() {
  local elapsed=$(( $(date +%s) - T0 ))
  [ "$elapsed" -gt "$MAX_SECONDS" ] && \
    die "time rail tripped (${elapsed}s) — completed blocks carry .done markers; re-run the nightly command to resume."
  return 0
}

# ---------------- frozen anchors: chosen.json + stage-01 manifest + stage-08 winner ----------------
CHOSEN_JSON="${STAGE09_CHOSEN_JSON:-}"
if [ -z "$CHOSEN_JSON" ]; then
  for d in $(ls -dt "$LOGS_DIR"/*/02-calibration/run_* 2>/dev/null); do
    [ -f "$d/chosen.json" ] && CHOSEN_JSON="$d/chosen.json" && break
  done
fi
[ -n "$CHOSEN_JSON" ] && [ -f "$CHOSEN_JSON" ] \
  || die "Pilot 002 stage-02 chosen.json not found — the operating point is frozen there"

read D_CHOSEN C_CHOSEN FALLBACK <<<"$(python3 -c "
import json; d = json.load(open('$CHOSEN_JSON'))
print(d['D'], d['C'], str(d.get('fallback', False)).lower())")"
WINDOW_S=$(( 3600 / C_CHOSEN ))
if [ "$FALLBACK" = "true" ]; then
  DISCLOSURE="no grid configuration met the SLO; lightest configuration used, shortfall disclosed per protocol"
else
  DISCLOSURE=""
fi

S01_DIR="$(ls -dt "$LOGS_DIR"/*/01-trace-pipeline/run_* 2>/dev/null | head -1 || true)"
[ -n "$S01_DIR" ] && [ -f "$S01_DIR/plans_manifest.json" ] \
  || die "Pilot 002 stage-01 plans_manifest.json not found — re-run 002 stage 01 first (byte-reproducible)"

SRC08_DIR="${STAGE09_SRC08_DIR:-}"
if [ -z "$SRC08_DIR" ]; then
  for d in $(ls -dt "$LOGS_DIR"/*/08-red-dot-confirm/run_* 2>/dev/null); do
    [ -f "$d/COMPLETE" ] && SRC08_DIR="$d" && break
  done
fi
[ -n "$SRC08_DIR" ] || die "no COMPLETE stage-08 run found — the perf gate needs the confirmed candidate"
[ -f "$SRC08_DIR/winner.json" ] || die "stage-08 archive lacks winner.json"
WINNER_ARM=$(python3 -c "import json; print(json.load(open('$SRC08_DIR/winner.json'))['arm_id'])")
SRC07_DIR="${STAGE09_SRC07_DIR:-$(ls -dt "$LOGS_DIR"/*/07-lever-screening/run_* 2>/dev/null | head -1 || true)}"
[ -n "$SRC07_DIR" ] && [ -f "$SRC07_DIR/calibration_texts.jsonl" ] \
  || die "stage-07 calibration archive not found (needed for an identical rebuild)"

# ---------------- verdict phase (sealed until all runs complete; recomputes from raw) ----------------
run_verdict() {
  SRC_DIR="$RUN_DIR" CHOSEN_JSON="$CHOSEN_JSON" OUT_DIR="$RUN_DIR" \
  SRC08_DIR="$SRC08_DIR" THRESH="$THRESH" THRESH_PROTOCOL="$THRESH_PROTOCOL" \
  BOOT_SEED="$BOOT_SEED" BOOT_N="$BOOT_N" P95_TOL="$P95_TOL" N_RUNS="$N_RUNS" \
  GIT_REV="$SCRIPTS_REV" python3 - <<'PY'
import glob, hashlib, json, math, os, statistics, sys

SRC = os.environ["SRC_DIR"]; OUT = os.environ["OUT_DIR"]
THRESH = float(os.environ["THRESH"]); THRESH_P = float(os.environ["THRESH_PROTOCOL"])
BSEED = int(os.environ["BOOT_SEED"]); BN = int(os.environ["BOOT_N"])
P95TOL = float(os.environ["P95_TOL"]); N_RUNS = int(os.environ["N_RUNS"])
GREV = os.environ["GIT_REV"]

def sha(p): return hashlib.sha256(open(p, "rb").read()).hexdigest()

runs = {}
integrity = []
for rd in sorted(glob.glob(os.path.join(SRC, "formal_run_*")), key=lambda p: int(p.rsplit("_", 1)[1])):
    i = int(rd.rsplit("_", 1)[1])
    arms = {}
    pair = None
    for arm in ("A", "C"):
        fp = os.path.join(rd, f"arm{arm}.jsonl"); mp = os.path.join(rd, f"arm{arm}.done")
        if not (os.path.exists(fp) and os.path.exists(mp)):
            sys.exit(f"FATAL: run {i} arm {arm} missing jsonl or .done marker — archive incomplete")
        marker = json.load(open(mp))
        integrity.append((f"run {i} arm {arm}", marker.get("raw_sha256", "") == sha(fp), sha(fp)[:16] + "…"))
        rows = {}
        for line in open(fp):
            r = json.loads(line)
            if "status" not in r:
                pair = pair or r.get("pair_id"); continue
            if r["status"] == "ok": rows[r["request_id"]] = r
        arms[arm] = rows
    runs[i] = {"A": arms["A"], "C": arms["C"], "pair": pair}
bad = [n for n, ok, _ in integrity if not ok]
if bad: sys.exit(f"FATAL: raw archive hash mismatch vs block markers: {bad}")
if len(runs) < N_RUNS: sys.exit(f"FATAL: only {len(runs)} complete runs — need {N_RUNS} (no extension pre-registered)")

run_vals, pair_counts = [], []
for i in sorted(runs):
    A, C = runs[i]["A"], runs[i]["C"]
    common = sorted(set(A) & set(C))
    lrs = [math.log((C[r]["completion_tokens"] / C[r]["e2e_s"]) /
                    (A[r]["completion_tokens"] / A[r]["e2e_s"])) for r in common]
    run_vals.append(statistics.mean(lrs)); pair_counts.append(len(common))

import numpy as np
vals = np.array(run_vals); point = float(vals.mean())
rng = np.random.default_rng(BSEED)
means = rng.choice(vals, size=(BN, len(vals)), replace=True).mean(axis=1)
lo, hi = (float(x) for x in np.percentile(means, [2.5, 97.5]))
e_lo, e_hi, e_pt = math.exp(lo), math.exp(hi), math.exp(point)

def p95(v):
    v = sorted(v); k = (len(v) - 1) * 0.95
    f, c = math.floor(k), math.ceil(k)
    return v[f] if f == c else v[f] + (v[c] - v[f]) * (k - f)
pool = {"A": {"ttft": [], "tpot": []}, "C": {"ttft": [], "tpot": []}}
for i in runs:
    for arm in ("A", "C"):
        for r in runs[i][arm].values():
            pool[arm]["ttft"].append(r["ttft_s"]); pool[arm]["tpot"].append(r["tpot_ms"])
p95_tpot = {a: p95(pool[a]["tpot"]) for a in ("A", "C")}
p95_ttft = {a: p95(pool[a]["ttft"]) for a in ("A", "C")}
tpot_ratio = p95_tpot["C"] / p95_tpot["A"]; ttft_ratio = p95_ttft["C"] / p95_ttft["A"]
secondary_ok = tpot_ratio <= P95TOL and ttft_ratio <= P95TOL

primary = "PASS" if lo >= math.log(THRESH) else "FAIL"
perf = "PASS" if (primary == "PASS" and secondary_ok) else "FAIL"
qgate = "UNKNOWN"
qpath = os.path.join(os.environ["SRC08_DIR"], "verdict_c.json")
if os.path.exists(qpath):
    qgate = json.load(open(qpath)).get("quality_gate", "UNKNOWN")
pilot003 = "PASS" if (qgate == "PASS" and perf == "PASS") else "FAIL"

chosen = json.load(open(os.environ["CHOSEN_JSON"]))
L = []
L.append("STAGE 09 VERDICT — PILOT 003 TUNED-PERFORMANCE GATE")
L.append(f"computed from raw archives: {SRC}")
L.append(f"scripts_rev={GREV}  bootstrap seed={BSEED}  resamples={BN}")
L.append(f"gate: paired-bootstrap CI lower bound >= {THRESH}x (Protocol-Lock continuity reference {THRESH_P}x reported)")
L.append("no straddle extension is pre-registered for Pilot 003 — the n=6 bootstrap decides")
if chosen.get("fallback"):
    L.append(f"disclosure (carried): operating point r=1/{chosen['D']}, C={chosen['C']}, shortfall disclosed per protocol")
L.append("")
L.append("[input integrity] per-block raw JSONL sha256 vs markers:")
for name, ok, short in integrity:
    L.append(f"  {name}: {'OK' if ok else 'MISMATCH'} ({short})")
L.append("")
L.append(f"[runs] n={len(runs)} formal runs; paired requests per run: {pair_counts}")
L.append("  run-level mean log-ratios (C/A): " + ", ".join(f"run {i}: {v:+.4f}" for i, v in zip(sorted(runs), run_vals)))
L.append(f"  point estimate: exp(mean) = {e_pt:.4f}x")
L.append(f"  paired bootstrap 95% CI: exp([{lo:+.4f}, {hi:+.4f}]) = [{e_lo:.4f}, {e_hi:.4f}]x")
L.append(f"  rule: PASS iff CI lower bound >= {THRESH}x  ->  primary = {primary}")
L.append(f"  [continuity] vs Protocol-Lock threshold {THRESH_P}x: {'PASS' if lo >= math.log(THRESH_P) else 'FAIL'}")
L.append("")
L.append("[secondary] pooled tail-latency non-inferiority (tolerance 5%)")
L.append(f"  P95 TPOT: A={p95_tpot['A']:.2f}ms C={p95_tpot['C']:.2f}ms ratio={tpot_ratio:.4f}  {'OK' if tpot_ratio <= P95TOL else 'BREACH'}")
L.append(f"  P95 TTFT: A={p95_ttft['A']:.3f}s C={p95_ttft['C']:.3f}s ratio={ttft_ratio:.4f}  {'OK' if ttft_ratio <= P95TOL else 'BREACH'}")
L.append("")
L.append(f"PERFORMANCE GATE: {perf}")
L.append(f"QUALITY GATE (stage 08, archived): {qgate}")
L.append("")
L.append(f"PILOT 003 VERDICT: {pilot003}")
L.append("  (PASS requires BOTH gates; a FAIL here publishes in full per ADDENDUM-02)")
L.append("")
L.append("Reproduce: bash stages/09-tuned-perf.sh --verify <run_dir>")
txt = "\n".join(L) + "\n"
open(os.path.join(OUT, "verdict_t.txt"), "w").write(txt)
json.dump(dict(stage="09-tuned-perf", pilot="003", scripts_rev=GREV,
               n_runs=len(runs), pair_counts=pair_counts,
               run_mean_log_ratios={str(i): v for i, v in zip(sorted(runs), run_vals)},
               point_estimate_ratio=e_pt, ci95_ratio=[e_lo, e_hi],
               threshold=THRESH, threshold_protocol=THRESH_P, primary=primary,
               secondary=dict(p95_tpot_ms=p95_tpot, p95_ttft_s=p95_ttft,
                              tpot_ratio=tpot_ratio, ttft_ratio=ttft_ratio, ok=secondary_ok),
               perf_gate=perf, quality_gate=qgate, pilot003_verdict=pilot003,
               input_sha256={f"run{i}_arm{a}": sha(os.path.join(SRC, f"formal_run_{i}", f"arm{a}.jsonl"))
                             for i in sorted(runs) for a in ("A", "C")}),
          open(os.path.join(OUT, "verdict_t.json"), "w"), indent=2, sort_keys=True)
print(txt)
raise SystemExit(0 if pilot003 == "PASS" else 2)
PY
}

# ============================================================
# --verify mode: recompute the verdict from raw archives and byte-compare
# Declared normalization: archive paths, scripts_rev.
# ============================================================
if [ "${1:-}" = "--verify" ]; then
  VD="${2:-}"
  if [ -z "$VD" ]; then VD="$(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null | head -1 || true)"; fi
  [ -n "$VD" ] && [ -f "$VD/verdict_t.txt" ] || die "--verify: no verdict archive found (usage: --verify [run_dir])"
  say "--verify: recomputing from $VD raw archives"
  SRC08_DIR_V="$(ls -dt "$LOGS_DIR"/*/08-red-dot-confirm/run_* 2>/dev/null | head -1 || true)"
  TMPD="$(mktemp -d)"
  for i in 1 2 3 4 5 6; do
    mkdir -p "$TMPD/formal_run_$i"
    cp "$VD/formal_run_$i"/armA.jsonl "$VD/formal_run_$i"/armA.done \
       "$VD/formal_run_$i"/armC.jsonl "$VD/formal_run_$i"/armC.done "$TMPD/formal_run_$i/"
  done
  RUN_DIR="$TMPD" SRC08_DIR="${SRC08_DIR_V:-$VD}" SCRIPTS_REV="verify" run_verdict > /dev/null || true
  python3 - "$VD" "$TMPD" <<'PY'
import json, re, sys
a, b = sys.argv[1], sys.argv[2]
def norm(t):
    t = re.sub(r"computed from raw archives: \S+", "computed from raw archives: NORMALIZED", t)
    t = re.sub(r"scripts_rev=\S+", "scripts_rev=NORMALIZED", t)
    return t
ta, tb = norm(open(a + "/verdict_t.txt").read()), norm(open(b + "/verdict_t.txt").read())
if ta != tb:
    import difflib
    print("\n".join(list(difflib.unified_diff(ta.splitlines(), tb.splitlines(), lineterm=""))[:20]))
    print("VERIFY: MISMATCH — investigate before trusting the archive", file=sys.stderr); sys.exit(1)
ja = json.load(open(a + "/verdict_t.json")); jb = json.load(open(b + "/verdict_t.json"))
for j in (ja, jb): j.pop("scripts_rev", None)
if ja != jb:
    print("VERIFY: MISMATCH (json)", file=sys.stderr); sys.exit(1)
print("VERIFY: verdict_t.txt / verdict_t.json identical (numbers byte-exact; declared provenance normalized)")
print("VERIFY: ALL CHECKS PASSED")
PY
  RC=$?
  rm -rf "$TMPD"
  exit $RC
fi

# ---------------- run dir: resume-or-create ----------------
LATEST="$(ls -dt "$LOGS_DIR"/*/"$STAGE_NAME"/run_* 2>/dev/null | head -1 || true)"
if [ -z "${STAGE09_OUT_DIR:-}" ] && [ -n "$LATEST" ] && [ -f "$LATEST/COMPLETE" ]; then
  say "this stage is already COMPLETE — verdict preserved at:"
  echo "  $LATEST/verdict_t.txt"
  echo "  (to recompute from the raw archives: bash stages/09-tuned-perf.sh --verify)"
  exit 0
fi
if [ -n "${STAGE09_OUT_DIR:-}" ]; then
  RUN_DIR="$STAGE09_OUT_DIR"; mkdir -p "$RUN_DIR"
elif [ -n "$LATEST" ]; then
  RUN_DIR="$LATEST"; say "resuming incomplete run dir: $RUN_DIR"
else
  BASE="$LOGS_DIR/$DATE_STR/$STAGE_NAME"; mkdir -p "$BASE"
  N=1; while [ -e "$BASE/run_$N" ]; do N=$((N+1)); done
  RUN_DIR="$BASE/run_$N"; mkdir -p "$RUN_DIR"
fi

# ---------------- preflight asserts ----------------
say "preflight asserts"
if [ "${STAGE09_SKIP_PREFLIGHT:-0}" != "1" ]; then
  nvidia-smi --query-gpu=name --format=csv,noheader | grep -q "$GPU_EXPECT" \
    || die "GPU is not $GPU_EXPECT — hardware boundary is locked (L3)"
  python3 -c "import vllm, sys; v=vllm.__version__; sys.exit(0 if v=='$VLLM_PINNED' else 1)" \
    || die "vLLM is not $VLLM_PINNED — engine version is pinned (L1)"
  FREE_GB=$(df --output=avail -BG "$HOME" | tail -1 | tr -dc '0-9')
  [ "${FREE_GB:-0}" -ge 50 ] || die "disk headroom < 50GB (base weights + one tuned checkpoint)"
fi
python3 -c "import httpx" 2>/dev/null || die "httpx not importable (expected present with vLLM)"
ulimit -n 65536 2>/dev/null || warn "could not raise fd limit (continuing with $(ulimit -n))"
SCRIPTS_REV="$(git -C "$SCRIPTS_DIR" rev-parse --short=8 HEAD 2>/dev/null || echo nogit)"
[ -f "$RECIPES_FILE" ] || die "private recipes file missing: $RECIPES_FILE (pod-side custody)"

# ---------------- anchor check: 6 formal plans vs stage-01 manifest ----------------
say "anchor check: 6 formal plans vs Pilot 002 stage-01 manifest"
S01_DIR="$S01_DIR" PLANS_DIR="$PLANS_DIR" python3 - <<'PY'
import hashlib, json, os, sys
man = json.load(open(os.path.join(os.environ["S01_DIR"], "plans_manifest.json")))
plans = man["plans"] if "plans" in man else man
bad = []
for i in range(1, 7):
    pid = f"pair_{i}"
    entry = plans.get(pid) or {}
    path = os.path.join(os.environ["PLANS_DIR"], f"{pid}.jsonl")
    if not os.path.exists(path):
        bad.append(f"{pid}: missing {path} — re-run Pilot 002 stage 01 (byte-reproducible)"); continue
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    want = entry.get("merged_sha256")
    if not (want and h.hexdigest() == want):
        bad.append(f"{pid}: sha256 mismatch vs manifest")
    print(f"  [{pid}] sha256={h.hexdigest()[:16]}… {'OK' if not bad or pid not in bad[-1] else 'MISMATCH'}")
if bad:
    sys.exit("\n".join(bad))
PY
[ $? -eq 0 ] || die "plan anchor check failed"

# ---------------- candidate checkpoint (identical rebuild from the frozen recipe) ----------------
say "candidate checkpoint for arm C (winner: $WINNER_ARM)"
CKPT_DIR="$CKPT_ROOT/${WINNER_ARM}-perf"
CKPT_LOG="$RUN_DIR/checkpoint_perf.json"
if [ -f "$CKPT_LOG" ] && [ -d "$CKPT_DIR" ]; then
  echo "checkpoint present: $(python3 -c "import json; print(json.load(open('$CKPT_LOG'))['checkpoint_sha256'][:16])")… — resume"
else
  [ -f "$CKPT_LOG" ] && warn "marker exists but checkpoint dir wiped — rebuilding from the identical recipe"
  rm -f "$CKPT_LOG"
  if [ "${STAGE09_MOCK_BUILD:-0}" = "1" ]; then
    mkdir -p "$CKPT_DIR"; echo '{"mock": true}' > "$CKPT_DIR/config.json"
    python3 -c "
import json
json.dump(dict(arm_id='$WINNER_ARM', checkpoint_dir='$CKPT_DIR', checkpoint_sha256='mock', mock=True),
          open('$CKPT_LOG', 'w'), indent=2)"
    echo "TEST HOOK: mock checkpoint at $CKPT_DIR"
  else
  WINNER_JSON="$SRC08_DIR/winner.json" RECIPES_FILE="$RECIPES_FILE" SRC07_DIR="$SRC07_DIR" \
  CKPT_DIR="$CKPT_DIR" CALIB_JSONL="$SRC07_DIR/calibration_texts.jsonl" \
  MODEL="$MODEL" MODEL_REV="$MODEL_REV" CKPT_LOG="$CKPT_LOG" python3 - <<'PY'
import hashlib, json, os, statistics, sys, time
w = json.load(open(os.environ["WINNER_JSON"]))
arm, want_sha = w["arm_id"], w.get("recipe_sha256")
recs = json.load(open(os.environ["RECIPES_FILE"]))["recipes"]
def canon(r): return hashlib.sha256(json.dumps(r, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
if arm in recs:
    r = recs[arm]
else:
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
if want_sha and canon(r) != want_sha:
    sys.exit("FATAL: resolved recipe sha256 != screening record — custody chain broken, owner decision required")
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
if "smoothing" in r:
    from llmcompressor.modifiers.smoothquant import SmoothQuantModifier
    mods.append(SmoothQuantModifier(smoothing_strength=r["smoothing"]["strength"]))
q = r["quantization"]
mods.append(QuantizationModifier(targets=q["targets"], scheme=q["scheme"], ignore=q["ignore"]))
t0 = time.time()
oneshot(model=os.environ["MODEL"], revision=os.environ["MODEL_REV"],
        dataset=[{"text": t} for t in calib], recipe=mods, output_dir=os.environ["CKPT_DIR"],
        num_calibration_samples=r["calibration"]["n_samples"],
        max_seq_length=r["calibration"]["max_seq_len"])
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
csha = tree_sha(os.environ["CKPT_DIR"])
json.dump(dict(arm_id=arm, recipe_sha256=canon(r), llmcompressor_version=ver,
               checkpoint_dir=os.environ["CKPT_DIR"], checkpoint_sha256=csha,
               build_seconds=round(time.time() - t0, 1),
               ts_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())),
          open(os.environ["CKPT_LOG"], "w"), indent=2, sort_keys=True)
print(f"perf checkpoint built: sha256={csha[:16]}…")
PY
  fi
fi

# ---------------- vLLM server lifecycle (per arm block) ----------------
start_server() {   # $1 = arm (A|C)
  local arm="$1"
  local slog="$RUN_DIR/server_run${CUR_RUN}_arm${arm}.log"
  say "run ${CUR_RUN}: starting Arm ${arm} server ($([ "$arm" = C ] && echo 'tuned candidate' || echo 'BF16 defaults'); prefix caching OFF)"
  if [ "$arm" = "C" ]; then
    nohup python -m vllm.entrypoints.openai.api_server \
      --model "$CKPT_DIR" --quantization compressed-tensors \
      --no-enable-prefix-caching --max-model-len "$MAX_MODEL_LEN" \
      --port "$PORT" > "$slog" 2>&1 &
  else
    nohup python -m vllm.entrypoints.openai.api_server \
      --model "$MODEL" --revision "$MODEL_REV" \
      --no-enable-prefix-caching --max-model-len "$MAX_MODEL_LEN" \
      --port "$PORT" > "$slog" 2>&1 &
  fi
  echo $! > "$RUN_DIR/server.pid"
  local waited=0
  until curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do
    sleep 10; waited=$((waited+10))
    if [ "$waited" -ge 2400 ]; then die "server failed to become healthy in 2400s — see $slog"; fi
    if ! kill -0 "$(cat "$RUN_DIR/server.pid")" 2>/dev/null; then die "server process died — see $slog"; fi
  done
  say "run ${CUR_RUN}: Arm ${arm} server healthy after ${waited}s"
  if [ "$arm" = "C" ]; then
    echo "server_argv: vllm serve $CKPT_DIR --quantization compressed-tensors --no-enable-prefix-caching --max-model-len $MAX_MODEL_LEN --port $PORT" \
      > "$RUN_DIR/formal_run_${CUR_RUN}/server_argv_arm${arm}.txt"
  else
    echo "server_argv: vllm serve $MODEL --revision $MODEL_REV --no-enable-prefix-caching --max-model-len $MAX_MODEL_LEN --port $PORT" \
      > "$RUN_DIR/formal_run_${CUR_RUN}/server_argv_arm${arm}.txt"
  fi
}
stop_server() {
  [ -f "$RUN_DIR/server.pid" ] && kill "$(cat "$RUN_DIR/server.pid")" 2>/dev/null || true
  sleep 5
  pkill -f "vllm.entrypoints.openai.api_server" 2>/dev/null || true
}

# ---------------- per-block replay client (identical craft to Pilot 002 stage 03) ----------------
run_block() {   # $1 = run_idx, $2 = arm, $3 = pair_id
RUN_IDX="$1" ARM="$2" PAIR_ID="$3" \
RUN_DIR="$RUN_DIR" PLANS_DIR="$PLANS_DIR" PORT="$PORT" MODEL="$MODEL" CKPT_DIR="$CKPT_DIR" \
D_CHOSEN="$D_CHOSEN" C_CHOSEN="$C_CHOSEN" WINDOW_S="$WINDOW_S" \
FALLBACK="$FALLBACK" DISCLOSURE="$DISCLOSURE" \
SLO_TTFT_S="$SLO_TTFT_S" SLO_TPOT_MS="$SLO_TPOT_MS" \
REQ_TIMEOUT_S="$REQ_TIMEOUT_S" CLIENT_CONC="$CLIENT_CONC" \
MAX_TOKENS_CAP="$MAX_TOKENS_CAP" MAX_MODEL_LEN="$MAX_MODEL_LEN" \
FILLER_SEED="$FILLER_SEED" RUN_SEED_BASE="$RUN_SEED_BASE" \
SCRIPTS_REV="$SCRIPTS_REV" \
python3 - <<'PY'
import asyncio, hashlib, json, os, random, sys, time
import httpx

RUN_DIR   = os.environ["RUN_DIR"]
RUN_IDX   = int(os.environ["RUN_IDX"])
ARM       = os.environ["ARM"]
PAIR_ID   = os.environ["PAIR_ID"]
PLAN      = os.path.join(os.environ["PLANS_DIR"], f"{PAIR_ID}.jsonl")
PORT      = os.environ["PORT"]
D0, C0    = int(os.environ["D_CHOSEN"]), int(os.environ["C_CHOSEN"])
R         = 1.0 / D0
WINDOW    = float(os.environ["WINDOW_S"])
FB        = os.environ["FALLBACK"] == "true"
DISC      = os.environ["DISCLOSURE"]
TTFT_SLO  = float(os.environ["SLO_TTFT_S"])
TPOT_SLO  = float(os.environ["SLO_TPOT_MS"])
REQ_TO    = float(os.environ["REQ_TIMEOUT_S"])
CONC      = int(os.environ["CLIENT_CONC"])
CAP       = int(os.environ["MAX_TOKENS_CAP"])
MML       = int(os.environ["MAX_MODEL_LEN"])
FSEED     = int(os.environ["FILLER_SEED"])
RUN_SEED  = int(os.environ["RUN_SEED_BASE"]) + RUN_IDX
SREV      = os.environ["SCRIPTS_REV"]
URL       = f"http://127.0.0.1:{PORT}/v1/completions"
SRV_MODEL = os.environ["CKPT_DIR"] if ARM == "C" else os.environ["MODEL"]

RD      = os.path.join(RUN_DIR, f"formal_run_{RUN_IDX}")
RAW     = os.path.join(RD, f"arm{ARM}.jsonl")
DONE_F  = os.path.join(RD, f"arm{ARM}.done")
FAIL_F  = os.path.join(RD, f"arm{ARM}.failed")

rows = [json.loads(l) for l in open(PLAN)]
rows.sort(key=lambda r: (r["arrival_offset_s"], r["service"], r["request_id"]))
sched = [(row["arrival_offset_s"] / C0, row) for row in rows if row["keep_u"] < R]
n_sched = len(sched)
max_ctx = max(r["context_tokens"] for _, r in sched) if sched else 8192
print(f"[run {RUN_IDX} arm {ARM}] {PAIR_ID}: merged {len(rows):,} rows → thinned "
      f"{n_sched:,} offered over {WINDOW:.0f}s (≈{n_sched / WINDOW:.2f} req/s), "
      f"max ctx {max_ctx:,}", flush=True)

_rng = random.Random(FSEED)
_base = [_rng.randrange(1000, 50000) for _ in range(8192)]
G = (_base * (max_ctx // 8192 + 2))[: max_ctx + 8192]
def filler_ids(n, rid):
    off = int.from_bytes(hashlib.sha256(f"{FSEED}|{rid}".encode()).digest()[:4], "big") % 8192
    return G[off:off + n]

sent = done = errs = 0
fatal = []
t0 = time.monotonic()

async def replay(client, raw_f):
    global sent, done, errs
    sem = asyncio.Semaphore(CONC)

    async def fire(at, row):
        global sent, done, errs
        rid  = row["request_id"]
        ctx, gen = row["context_tokens"], row["generated_tokens"]
        rec = {"request_id": rid, "pair_id": PAIR_ID, "service": row["service"],
               "arrival_offset_s": row["arrival_offset_s"],
               "prompt_tokens": ctx, "max_tokens_target": min(gen, CAP, MML - ctx - 1),
               "arm": ARM, "run_idx": RUN_IDX, "run_seed": RUN_SEED,
               "scripts_rev": SREV, "D": D0, "C": C0}
        if rec["max_tokens_target"] <= 0:
            rec.update(status="skipped_overlength", completion_tokens=0,
                       ttft_s=None, tpot_ms=None, e2e_s=None,
                       wall_send_ts=None, wall_first_ts=None, wall_end_ts=None,
                       output_text_sha256=None, send_lag_ms=None, slo_ok=False,
                       retries=0)
            raw_f.write(json.dumps(rec) + "\n"); raw_f.flush()
            done += 1
            return
        async with sem:
            if fatal:
                return
            sent += 1
            payload = {"model": SRV_MODEL, "prompt": filler_ids(ctx, rid),
                       "max_tokens": rec["max_tokens_target"], "ignore_eos": True,
                       "temperature": 0, "stream": True,
                       "stream_options": {"include_usage": True}}
            t_send_m = time.monotonic(); wall_send = time.time()
            t_first_m = t_last_m = None; wall_first = None
            comp_tokens = 0
            texth = hashlib.sha256()
            status = "ok"; retries = 0
            try:
                attempt = 0
                while True:
                    try:
                        async with client.stream("POST", URL, json=payload) as resp:
                            if resp.status_code >= 500:
                                status = f"http_{resp.status_code}"
                                fatal.append(status)
                                break
                            if resp.status_code != 200:
                                status = f"http_{resp.status_code}"
                                break
                            async for line in resp.aiter_lines():
                                if not line.startswith("data:"):
                                    continue
                                data = line[5:].strip()
                                if data == "[DONE]":
                                    break
                                now_m = time.monotonic()
                                try:
                                    obj = json.loads(data)
                                except Exception:
                                    continue
                                if t_first_m is None:
                                    t_first_m = now_m; wall_first = time.time()
                                t_last_m = now_m
                                for ch in obj.get("choices", []):
                                    t = ch.get("text")
                                    if t:
                                        texth.update(t.encode())
                                u = obj.get("usage")
                                if u:
                                    comp_tokens = u.get("completion_tokens", comp_tokens)
                        break
                    except httpx.ConnectError:
                        attempt += 1
                        if attempt > 3:
                            status = "error:ConnectError"; break
                        retries = attempt
                        await asyncio.sleep(0.5 * attempt)
            except asyncio.CancelledError:
                rec.update(status="cancelled", completion_tokens=comp_tokens,
                           ttft_s=None, tpot_ms=None, e2e_s=None,
                           wall_send_ts=round(wall_send, 3), wall_first_ts=None,
                           wall_end_ts=round(time.time(), 3),
                           output_text_sha256=None,
                           send_lag_ms=round((t_send_m - t0) * 1000.0, 1),
                           slo_ok=False, retries=retries)
                raw_f.write(json.dumps(rec) + "\n"); raw_f.flush()
                done += 1
                raise
            except Exception as e:
                status = "error:" + type(e).__name__
            t_end_m = time.monotonic(); wall_end = time.time()
            if comp_tokens == 0 and status == "ok":
                status = "error:no_tokens"
            ttft = (t_first_m - t_send_m) if t_first_m is not None else None
            if t_first_m is not None and comp_tokens > 1:
                tpot_ms = (t_last_m - t_first_m) / (comp_tokens - 1) * 1000.0
            elif t_first_m is not None:
                tpot_ms = (t_end_m - t_first_m) * 1000.0
            else:
                tpot_ms = None
            e2e = t_end_m - t_send_m
            ok = (status == "ok" and ttft is not None and ttft <= TTFT_SLO
                  and tpot_ms is not None and tpot_ms <= TPOT_SLO)
            rec.update(status=status, completion_tokens=comp_tokens,
                       ttft_s=round(ttft, 4) if ttft is not None else None,
                       tpot_ms=round(tpot_ms, 3) if tpot_ms is not None else None,
                       e2e_s=round(e2e, 4),
                       wall_send_ts=round(wall_send, 3),
                       wall_first_ts=round(wall_first, 3) if wall_first else None,
                       wall_end_ts=round(wall_end, 3),
                       output_text_sha256=(texth.hexdigest() if status == "ok" else None),
                       send_lag_ms=round((t_send_m - t0) * 1000.0, 1),
                       slo_ok=ok, retries=retries)
            raw_f.write(json.dumps(rec) + "\n"); raw_f.flush()
            done += 1
            if status != "ok":
                errs += 1

    async def sender():
        for at, row in sched:
            if fatal:
                break
            delay = at - (time.monotonic() - t0)
            if delay > 0:
                await asyncio.sleep(delay)
            asyncio.create_task(fire(at, row))

    async def progress():
        while done < n_sched and not fatal:
            await asyncio.sleep(30)
            print(f"  [run {RUN_IDX} arm {ARM}] t={time.monotonic()-t0:.0f}s "
                  f"sent={sent} done={done}/{n_sched} errors={errs}", flush=True)

    sd = asyncio.create_task(sender())
    pg = asyncio.create_task(progress())
    await sd
    pending = {t for t in asyncio.all_tasks()
               if t is not asyncio.current_task() and t not in (sd, pg)}
    deadline = time.monotonic() + REQ_TO + 120.0
    while pending:
        if fatal or time.monotonic() > deadline:
            for t in pending:
                t.cancel()
        _, pending = await asyncio.wait(
            pending, timeout=5.0, return_when=asyncio.FIRST_COMPLETED)
    pg.cancel()

async def main():
    limits = httpx.Limits(max_connections=CONC,
                          max_keepalive_connections=min(CONC, 256))
    timeout = httpx.Timeout(REQ_TO, connect=30.0)
    hdr = {"type": "header", "pair_id": PAIR_ID, "arm": ARM, "run_idx": RUN_IDX,
           "run_seed": RUN_SEED, "scripts_rev": SREV, "D": D0, "C": C0,
           "r": f"1/{D0}", "window_s": WINDOW, "fallback": FB,
           "disclosure": DISC if FB else "",
           "slo_reference": {"ttft_s": TTFT_SLO, "tpot_ms": TPOT_SLO},
           "started_wall": round(time.time(), 3)}
    async with httpx.AsyncClient(limits=limits, timeout=timeout) as client:
        with open(RAW, "w") as raw_f:
            raw_f.write(json.dumps(hdr) + "\n")
            await replay(client, raw_f)
    if fatal:
        marker = {"arm": ARM, "status": "failed-server-error", "reason": fatal[0],
                  "rows": done, "note": "run voided (server-side error); re-run the "
                                        "nightly command after the cause is fixed — "
                                        "the block replays against identical load"}
        json.dump(marker, open(FAIL_F, "w"), indent=2)
        print(f"[run {RUN_IDX} arm {ARM}] VOIDED — server-side error {fatal[0]}", flush=True)
        sys.exit(45)
    ok_rows = errs_n = 0
    tps_sum = ttft_sum = tpot_sum = e2e_sum = 0.0
    comp_sum = 0
    with open(RAW) as f:
        for ln in f:
            r = json.loads(ln)
            if "status" not in r:
                continue
            if r["status"] == "ok":
                ok_rows += 1
                tps_sum  += r["completion_tokens"] / r["e2e_s"]
                ttft_sum += r["ttft_s"]; e2e_sum += r["e2e_s"]
                comp_sum += r["completion_tokens"]
                if r["tpot_ms"] is not None:
                    tpot_sum += r["tpot_ms"]
            elif r["status"] != "skipped_overlength":
                errs_n += 1
    raw_sha = hashlib.sha256(open(RAW, "rb").read()).hexdigest()
    marker = {"arm": ARM, "status": "ok", "rows": done,
              "ok": ok_rows, "errors": errs_n,
              "mean_tps": round(tps_sum / max(ok_rows, 1), 6),
              "mean_ttft_s": round(ttft_sum / max(ok_rows, 1), 6),
              "mean_tpot_ms": round(tpot_sum / max(ok_rows, 1), 6),
              "mean_e2e_s": round(e2e_sum / max(ok_rows, 1), 6),
              "completion_tokens_total": comp_sum,
              "scheduled": n_sched, "window_s": WINDOW,
              "raw_sha256": raw_sha, "raw_file": os.path.basename(RAW)}
    json.dump(marker, open(DONE_F, "w"), indent=2)
    print(f"[run {RUN_IDX} arm {ARM}] block ok: rows={done} ok={ok_rows} "
          f"errors={errs_n} mean_tps={marker['mean_tps']:.2f} raw_sha={raw_sha[:16]}…",
          flush=True)

asyncio.run(main())
PY
}

# ---------------- run summary (descriptive means only — verdict stays sealed) ----------------
summarize_run() {   # $1 = run_idx
RUN_IDX="$1" RUN_DIR="$RUN_DIR" RUN_SEED_BASE="$RUN_SEED_BASE" \
D_CHOSEN="$D_CHOSEN" C_CHOSEN="$C_CHOSEN" WINDOW_S="$WINDOW_S" \
FALLBACK="$FALLBACK" DISCLOSURE="$DISCLOSURE" SCRIPTS_REV="$SCRIPTS_REV" \
python3 - <<'PY'
import json, os
RUN_IDX = int(os.environ["RUN_IDX"])
RD = os.path.join(os.environ["RUN_DIR"], f"formal_run_{RUN_IDX}")
def rows(arm):
    out = []
    for ln in open(os.path.join(RD, f"arm{arm}.jsonl")):
        r = json.loads(ln)
        if "status" in r:
            out.append(r)
    return out
def mean(xs): return sum(xs) / len(xs) if xs else 0.0
ra, rc = rows("A"), rows("C")
order = ["A", "C"] if RUN_IDX % 2 == 1 else ["C", "A"]
summ = {"run_idx": RUN_IDX, "pair_id": ra[0]["pair_id"] if ra else rc[0]["pair_id"],
        "run_seed": int(os.environ["RUN_SEED_BASE"]) + RUN_IDX,
        "arm_order": order, "D": int(os.environ["D_CHOSEN"]),
        "C": int(os.environ["C_CHOSEN"]), "window_s": float(os.environ["WINDOW_S"]),
        "fallback": os.environ["FALLBACK"] == "true",
        "disclosure": os.environ["DISCLOSURE"],
        "scripts_rev": os.environ["SCRIPTS_REV"], "note": "descriptive means only; "
        "the paired-bootstrap CI (seed 20262002) and the P95 gate are computed "
        "exclusively by the sealed verdict phase of this stage"}
per_arm = {}
for arm, rr in (("A", ra), ("C", rc)):
    ok = [r for r in rr if r["status"] == "ok"]
    per_arm[arm] = {
        "rows": len(rr), "ok": len(ok),
        "errors": sum(1 for r in rr if r["status"] not in ("ok", "skipped_overlength")),
        "skipped_overlength": sum(1 for r in rr if r["status"] == "skipped_overlength"),
        "mean_tps": round(mean([r["completion_tokens"] / r["e2e_s"] for r in ok]), 6),
        "mean_ttft_s": round(mean([r["ttft_s"] for r in ok]), 6),
        "mean_tpot_ms": round(mean([r["tpot_ms"] for r in ok if r["tpot_ms"] is not None]), 6),
        "mean_e2e_s": round(mean([r["e2e_s"] for r in ok]), 6),
    }
summ["per_arm"] = per_arm
oka = {r["request_id"]: r for r in ra if r["status"] == "ok"}
okc = {r["request_id"]: r for r in rc if r["status"] == "ok"}
both = [(okc[k], oka[k]) for k in oka.keys() & okc.keys()]
ratios = [(c["completion_tokens"] / c["e2e_s"]) / (a["completion_tokens"] / a["e2e_s"]) for c, a in both]
summ["paired_ok_requests"] = len(both)
summ["paired_mean_ratio_C_over_A"] = round(mean(ratios), 6)
json.dump(summ, open(os.path.join(RD, "run_summary.json"), "w"), indent=2)
print(f"[run {RUN_IDX}] summary: paired_ok={len(both)} "
      f"mean_tps A={per_arm['A']['mean_tps']:.2f} C={per_arm['C']['mean_tps']:.2f} "
      f"descriptive paired mean ratio C/A={summ['paired_mean_ratio_C_over_A']:.4f} "
      f"(descriptive only — CI sealed)", flush=True)
PY
}

# ---------------- main driver: 6 runs × 2 arm blocks, block-crossover ----------------
say "starting tuned-performance measurement: 6 runs, block-crossover, operating point r=1/${D_CHOSEN} C=${C_CHOSEN}"
[ "$FALLBACK" = "true" ] && say "disclosure (carried into every summary): $DISCLOSURE"

if [ "${STAGE09_SKIP_SERVER:-0}" != "1" ]; then
  trap stop_server EXIT
else
  warn "STAGE09_SKIP_SERVER=1 — using external server on port $PORT (test mode)"
fi

for CUR_RUN in $RUNS; do
  [ "$CUR_RUN" -le "$N_RUNS" ] || die "run index $CUR_RUN > $N_RUNS — no extension is pre-registered for Pilot 003"
  check_time_rail
  RD="$RUN_DIR/formal_run_$CUR_RUN"
  mkdir -p "$RD"
  PAIR_ID="pair_$CUR_RUN"
  [ -f "$PLANS_DIR/$PAIR_ID.jsonl" ] || die "plan missing: $PLANS_DIR/$PAIR_ID.jsonl — re-run Pilot 002 stage 01 (byte-reproducible)"
  if [ $(( CUR_RUN % 2 )) -eq 1 ]; then ARMS="A C"; else ARMS="C A"; fi
  say "run $CUR_RUN / $N_RUNS — $PAIR_ID, arm order: $ARMS"
  for ARM in $ARMS; do
    if [ -f "$RD/arm${ARM}.done" ]; then
      echo "  [run $CUR_RUN arm $ARM] already done (resume)"; continue
    fi
    if [ -f "$RD/arm${ARM}.failed" ]; then
      warn "run $CUR_RUN arm $ARM: previous attempt voided by server-side error — replaying identical load"
      rm -f "$RD/arm${ARM}.failed" "$RD/arm${ARM}.jsonl"
    fi
    check_time_rail
    if [ "${STAGE09_SKIP_SERVER:-0}" != "1" ]; then
      start_server "$ARM"
    fi
    set +e
    run_block "$CUR_RUN" "$ARM" "$PAIR_ID"
    RC=$?
    set -e
    if [ "$RC" -eq 45 ]; then
      [ "${STAGE09_SKIP_SERVER:-0}" != "1" ] && stop_server || true
      die "run $CUR_RUN arm $ARM voided by server-side error — incident recorded in $RD/arm${ARM}.failed + server log; enters the deviation log. Re-run the nightly command after the cause is fixed."
    fi
    [ "$RC" -eq 0 ] || die "block client failed (rc=$RC) — see stage.log"
    if [ "${STAGE09_SKIP_SERVER:-0}" != "1" ]; then
      if ! kill -0 "$(cat "$RUN_DIR/server.pid")" 2>/dev/null; then
        warn "run $CUR_RUN arm $ARM: server process exited during/after block — see server_run${CUR_RUN}_arm${ARM}.log"
      fi
      stop_server
    fi
  done
  if [ -f "$RD/armA.done" ] && [ -f "$RD/armC.done" ]; then
    summarize_run "$CUR_RUN"
    echo "ok" > "$RD/RUN_COMPLETE"
  fi
done

# ---------------- sealed verdict phase (runs only after all 6 runs complete) ----------------
MISSING=""
for i in $RUNS; do
  [ -f "$RUN_DIR/formal_run_$i/RUN_COMPLETE" ] || MISSING="$MISSING $i"
done
[ -z "$MISSING" ] || die "incomplete runs:$MISSING — re-run the nightly command to resume"

say "all 6 runs complete — computing the sealed verdict from raw archives"
set +e
run_verdict
RC_V=$?
set -e

if [ "$RC_V" -eq 0 ] || [ "$RC_V" -eq 2 ]; then
  date -u > "$RUN_DIR/COMPLETE"
  V=$(python3 -c "import json; print(json.load(open('$RUN_DIR/verdict_t.json'))['pilot003_verdict'])")
  say "stage 09 COMPLETE — PILOT 003 VERDICT: $V (see verdict_t.txt)"
  echo "  verify: bash stages/09-tuned-perf.sh --verify $RUN_DIR"
  if [ "${STAGE09_MOCK_BUILD:-0}" != "1" ]; then
    rm -rf "$CKPT_DIR" 2>/dev/null && echo "  candidate checkpoint deleted (hash anchor in checkpoint_perf.json)" || true
  fi
  exit 0
else
  echo "STAGE 09: verdict computation failed (rc=$RC_V) — no COMPLETE marker"
  exit 1
fi
