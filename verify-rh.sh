#!/bin/bash
# verify-rh.sh: replicate the Lean build of Levent Alpöge's RH/GRH project on macOS
# and report which axioms the five headline theorems depend on.
#
# Usage:  ./verify-rh.sh [all|preflight|fetch|unpack|cache|build|axioms|verdict|manifest|status|tidy]
#         JOBS=12 ./verify-rh.sh build
#
# Idempotent: every stage skips work already done, and `build` resumes.
# The proof source is never modified.
#
# Layout (everything lives under this folder):
#   parts/          downloaded archive parts      (delete once unpacked)
#   lean/           the unpacked project; lean/.lake holds Mathlib and all build output
#   mathlib-cache/  Mathlib's downloaded cache    (delete once `cache` has run)
#   record/         everything worth publishing: environment.txt, SHA256SUMS,
#                   source-scan.txt, cache/run logs, build-summary.log.gz,
#                   progress.tsv, AxiomCheck.lean, axioms.txt, olean-sha256.txt.gz
#                   (the full build.log stays local)
#   sandbox/        the two sandbox profiles this script generates
#
# Safety: building runs compile-time code from the archive. The cache stage runs
# with writes confined to this folder; the build and axiom stages also run with
# no network and no read access to credential folders.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd -P)"
PARTS="$ROOT/parts"
SRC="$ROOT/lean"
LOGS="$ROOT/record"
SANDBOX="$ROOT/sandbox"

URL_BASE="https://alpo.ge/lean.tar.gz.part"
N_PARTS=14
ARCHIVE_SHA256="9631b4f020199e580ba86178cb56c6e9b09f690c2369a80dc4334aa93f49c7fc"
TOOLCHAIN="leanprover/lean4:v4.33.1"
MATHLIB_REV="0df444a360eaa60ab8c11dca51a86af692955474"
THEOREMS=(riemannHypothesis riemannZeta_eq_zero_re LFunction_ne_zero_of_half_lt_re
          LFunction_eq_zero_re LFunction_eq_zero_re_of_isPrimitive)
ALLOWED_AXIOMS="propext Classical.choice Quot.sound"

JOBS="${JOBS:-12}"          # concurrent build jobs (this Mac: 12 Performance + 6 Super cores)
QOS="${QOS-}"               # optional QoS clamp, e.g. QOS=utility; about halves throughput here
MIN_FREE_GB="${MIN_FREE_GB:-150}"
MIN_VNODES="${MIN_VNODES:-600000}"   # each Lean job maps up to ~175,000 .olean files at the end

export PATH="$HOME/.elan/bin:$PATH"
export MATHLIB_CACHE_DIR="$ROOT/mathlib-cache"

say()  { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*"; }
die()  { say "ERROR: $*" >&2; exit 1; }
part_ids() { local i; for ((i = 1; i <= N_PARTS; i++)); do printf '%02d\n' "$i"; done; }
part_files() { local i; for i in $(part_ids); do printf '%s\n' "$PARTS/lean.tar.gz.part$i"; done; }

preflight() {
  local t free
  for t in curl shasum tar caffeinate sandbox-exec taskpolicy elan lake lean; do
    command -v "$t" >/dev/null || die "missing tool: $t"
  done
  elan toolchain list | grep -q "^${TOOLCHAIN}\b" || die "toolchain $TOOLCHAIN is not installed (elan toolchain install $TOOLCHAIN)"
  free=$(df -g "$ROOT" | awk 'NR==2 {print $4}')
  (( free >= MIN_FREE_GB )) || die "only ${free} GB free, want ${MIN_FREE_GB} GB"
  local vn; vn=$(sysctl -n kern.maxvnodes)
  (( vn >= MIN_VNODES )) || die "kern.maxvnodes is $vn; the last modules need about $MIN_VNODES (sudo sysctl kern.maxvnodes=$MIN_VNODES, resets at reboot)"
  pmset -g batt | grep -q "AC Power" || say "WARNING: on battery; plug in before a multi-day build"
  say "preflight ok: ${free} GB free, toolchain $TOOLCHAIN, jobs=$JOBS, qos=${QOS:-none}"
}

fetch() {
  mkdir -p "$PARTS" "$LOGS"
  if [[ -f "$PARTS/.sha256-ok" || -f "$SRC/.unpacked-from-$ARCHIVE_SHA256" ]]; then
    say "fetch: archive already verified"; return
  fi
  say "fetch: downloading $N_PARTS parts (4 at a time)"
  # A part is complete only when its .done marker exists; partial files are refetched.
  part_ids | xargs -P 4 -I{} sh -c '
    f="$0/lean.tar.gz.part{}"
    [ -f "$f.done" ] && exit 0
    curl -fsSL --retry 5 --retry-delay 5 -o "$f.tmp" "$1{}" && mv "$f.tmp" "$f" && touch "$f.done"
  ' "$PARTS" "$URL_BASE" 2>>"$LOGS/fetch.log" || die "download failed, see record/fetch.log"
  say "fetch: hashing the joined archive"
  local got
  got=$(part_files | tr '\n' '\0' | xargs -0 cat | shasum -a 256 | awk '{print $1}')
  [[ "$got" == "$ARCHIVE_SHA256" ]] || die "SHA-256 mismatch: got $got, want $ARCHIVE_SHA256"
  touch "$PARTS/.sha256-ok"
  say "fetch: SHA-256 matches the pinned value"
}

unpack() {
  if [[ -f "$SRC/.unpacked-from-$ARCHIVE_SHA256" ]]; then say "unpack: already done"; return; fi
  [[ -f "$PARTS/.sha256-ok" ]] || die "unpack: run fetch first"
  [[ ! -e "$SRC" ]] || die "unpack: $SRC exists but is incomplete; remove it and rerun"
  say "unpack: checking that every entry sits under lean/"
  local tops
  tops=$(part_files | tr '\n' '\0' | xargs -0 cat | tar -tzf - | awk -F/ '{print $1}' | sort -u)
  [[ "$tops" == "lean" ]] || die "unpack: unexpected top-level entries: $tops"
  say "unpack: extracting"
  mkdir -p "$LOGS"
  part_files | tr '\n' '\0' | xargs -0 cat | tar -xzf - -C "$ROOT"
  local tc
  tc=$(tr -d '[:space:]' < "$SRC/lean-toolchain")
  [[ "$tc" == "$TOOLCHAIN" ]] || die "unpack: lean-toolchain is '$tc', want '$TOOLCHAIN'"
  grep -q "$MATHLIB_REV" "$SRC/lake-manifest.json" || die "unpack: Mathlib pin $MATHLIB_REV not in lake-manifest.json"
  find "$SRC" -name '*.lean' -not -path '*/.lake/*' | wc -l | tr -d ' ' > "$LOGS/module-count"
  touch "$SRC/.unpacked-from-$ARCHIVE_SHA256"
  say "unpack: $(cat "$LOGS/module-count") .lean files; toolchain and Mathlib pin match"
}

write_sandbox_profiles() {
  mkdir -p "$SANDBOX"
  local common
  common=$(cat <<EOF
(version 1)
(allow default)
(deny file-write*)
(allow file-write*
  (subpath "$ROOT")
  (subpath "/private/tmp")
  (subpath "/private/var/folders")
  (subpath "/dev"))
EOF
)
  printf '%s\n' "$common" > "$SANDBOX/cache.sb"
  cat > "$SANDBOX/build.sb" <<EOF
$common
(deny network*)
(deny file-read*
  (subpath "$HOME/.ssh")
  (subpath "$HOME/.aws")
  (subpath "$HOME/.gnupg")
  (subpath "$HOME/.config")
  (subpath "$HOME/.claude")
  (subpath "$HOME/Library/Keychains")
  (subpath "$HOME/Library/Application Support")
  (subpath "$HOME/Library/Mail")
  (subpath "$HOME/Library/Messages")
  (subpath "$HOME/Library/Safari")
  (subpath "$HOME/Documents")
  (subpath "$HOME/Desktop")
  (subpath "$HOME/Downloads")
  (subpath "$HOME/code"))
EOF
}

need_unpacked() { [[ -f "$SRC/.unpacked-from-$ARCHIVE_SHA256" ]] || die "run unpack first"; }

cache() {
  need_unpacked; write_sandbox_profiles; mkdir -p "$LOGS" "$MATHLIB_CACHE_DIR"
  if [[ -f "$SRC/.lake/.mathlib-cache-ok" ]]; then say "cache: already done"; return; fi
  say "cache: fetching Mathlib and its prebuilt files (log: record/cache.log)"
  ( cd "$SRC" && sandbox-exec -f "$SANDBOX/cache.sb" lake exe cache get ) >> "$LOGS/cache.log" 2>&1 \
    || die "cache: failed, see record/cache.log"
  local rev
  rev=$(git -C "$SRC/.lake/packages/mathlib" rev-parse HEAD)
  [[ "$rev" == "$MATHLIB_REV" ]] || die "cache: Mathlib is at $rev, want $MATHLIB_REV"
  touch "$SRC/.lake/.mathlib-cache-ok"
  say "cache: Mathlib at the pinned commit, prebuilt files unpacked"
}

build() {
  need_unpacked; write_sandbox_profiles; mkdir -p "$LOGS"
  [[ -f "$SRC/.lake/.mathlib-cache-ok" ]] || die "run cache first"
  local clamp=() rc=0 tidier
  [[ -n "$QOS" ]] && clamp=(taskpolicy -c "$QOS")
  echo "=== build started $(date -u +%FT%TZ) jobs=$JOBS qos=${QOS:-none} ===" >> "$LOGS/build.log"
  say "build: lake build Main with $JOBS jobs (log: record/build.log)"
  # Lake leaves a ~6.4 MB setup file per module (~1.1 TB in all); remove finished ones as we go.
  ( while sleep 120; do tidy > /dev/null; done ) & tidier=$!
  ( cd "$SRC" && LEAN_NUM_THREADS="$JOBS" caffeinate -ims ${clamp[@]+"${clamp[@]}"} \
      /usr/bin/time -l sandbox-exec -f "$SANDBOX/build.sb" lake build Main ) >> "$LOGS/build.log" 2>&1 || rc=$?
  kill "$tidier" 2>/dev/null || true
  echo "=== build exited rc=$rc $(date -u +%FT%TZ) ===" >> "$LOGS/build.log"
  (( rc == 0 )) || die "build: lake exited $rc, see record/build.log"
  touch "$SRC/.lake/.build-ok"
  say "build: finished"
}

axioms() {
  need_unpacked; write_sandbox_profiles
  [[ -f "$SRC/.lake/.build-ok" ]] || die "run build first"
  { echo "import Main"; local t; for t in "${THEOREMS[@]}"; do echo "#print axioms $t"; done; } > "$LOGS/AxiomCheck.lean"
  say "axioms: running #print axioms on ${#THEOREMS[@]} theorems"
  ( cd "$SRC" && sandbox-exec -f "$SANDBOX/build.sb" lake env lean "$LOGS/AxiomCheck.lean" ) > "$LOGS/axioms.txt" 2>&1 \
    || die "axioms: lean failed, see record/axioms.txt"
  cat "$LOGS/axioms.txt"
}

verdict() {
  [[ -f "$LOGS/axioms.txt" ]] || die "run axioms first"
  local flat t list a bad=0
  flat=$(tr '\n' ' ' < "$LOGS/axioms.txt")
  for t in "${THEOREMS[@]}"; do
    if grep -q "'$t' does not depend on any axioms" <<<"$flat"; then continue; fi
    list=$(grep -o "'$t' depends on axioms: \[[^]]*\]" <<<"$flat" | sed -e 's/.*\[//' -e 's/\]//' -e 's/,/ /g') || true
    if [[ -z "$list" ]]; then say "verdict: no axiom report for $t"; bad=1; continue; fi
    for a in $list; do
      [[ " $ALLOWED_AXIOMS " == *" $a "* ]] || { say "verdict: $t uses non-standard axiom $a"; bad=1; }
    done
  done
  if (( bad == 0 )); then
    say "VERDICT: PASS. All ${#THEOREMS[@]} theorems depend only on: $ALLOWED_AXIOMS"
  else
    say "VERDICT: FAIL. See record/axioms.txt"; return 1
  fi
}

# Progress by counting compiled modules. Slow files are not spread evenly,
# so the ETA is a rough guide, not a promise.
status() {
  need_unpacked; mkdir -p "$LOGS"
  local total done now kb prev_t prev_n rate
  total=$(cat "$LOGS/module-count")
  done=0; kb=0
  if [[ -d "$SRC/.lake/build" ]]; then
    done=$(find "$SRC/.lake/build" -name '*.olean' | wc -l | tr -d ' ')
    kb=$(du -sk "$SRC/.lake/build" | awk '{print $1}')
  fi
  now=$(date +%s)
  if [[ -f "$LOGS/progress.tsv" ]]; then read -r prev_t prev_n _ < <(tail -1 "$LOGS/progress.tsv"); fi
  [[ "${prev_t:-}" =~ ^[0-9]+$ ]] || prev_t=""
  [[ -f "$LOGS/progress.tsv" ]] || printf 'epoch\tmodules_done\tbuild_kb\tload_1m\n' > "$LOGS/progress.tsv"
  printf '%s\t%s\t%s\t%s\n' "$now" "$done" "$kb" "$(sysctl -n vm.loadavg | awk '{print $2}')" >> "$LOGS/progress.tsv"
  printf 'modules  %s / %s  (%.1f%%)\n' "$done" "$total" "$(echo "100*$done/$total" | bc -l)"
  printf 'output   %.1f GB' "$(echo "$kb/1048576" | bc -l)"
  (( done > 0 )) && printf '  (projected %.0f GB at this density)' "$(echo "$kb/1048576*$total/$done" | bc -l)"
  printf '\n'
  if [[ -n "${prev_t:-}" ]] && (( now > prev_t && done > prev_n )); then
    rate=$(echo "($done-$prev_n)*60/($now-$prev_t)" | bc -l)
    printf 'rate     %.1f modules/min since the last sample; about %.1f days left at that rate\n' \
      "$rate" "$(echo "($total-$done)/$rate/1440" | bc -l)"
  fi
  if pgrep -qf "lake build Main"; then echo "build    running"; else echo "build    not running"; fi
}

# Lake writes a setup.json of about 6 MB for every module (the list of all
# imported files), which would add up to over 1 TB. Lean reads it once at
# startup and Lake's trace does not track it, so it is removed once the module's
# trace exists. Checked: `lake build +Module --no-build` still reports the
# module up to date afterwards.
tidy() {
  need_unpacked
  local ir="$SRC/.lake/build/ir" lib="$SRC/.lake/build/lib/lean" n=0 f rel
  [[ -d "$ir" ]] || return 0
  while IFS= read -r -d '' f; do
    rel="${f#"$ir"/}"; rel="${rel%.setup.json}"
    if [[ -f "$lib/$rel.trace" && ! "$f" -nt "$lib/$rel.trace" ]]; then rm -f "$f"; n=$((n + 1)); fi
  done < <(find "$ir" -name '*.setup.json' -print0)
  say "tidy: removed $n setup files of finished modules"
}

# SHA-256 of every compiled project module, for comparison with other builds.
manifest() {
  need_unpacked
  [[ -f "$SRC/.lake/.build-ok" ]] || die "run build first"
  say "manifest: hashing compiled modules"
  ( cd "$SRC/.lake/build/lib" && find . -name '*.olean' -print0 | sort -z | xargs -0 shasum -a 256 ) | gzip -9 > "$LOGS/olean-sha256.txt.gz"
  say "manifest: $(gzip -dc "$LOGS/olean-sha256.txt.gz" | wc -l | tr -d ' ') files hashed"
  # The full build log is mostly linter warnings; keep one line per module, errors and timings.
  grep -E '^(✔|✖|⚠|error|===)|^ +[0-9.]+ +(real|user|sys)' "$LOGS/build.log" | gzip -9 > "$LOGS/build-summary.log.gz"
  say "manifest: wrote record/build-summary.log.gz"
}

# Everything runs inside main so that bash has parsed the whole file before
# starting: the script can then be edited safely while a long build is running.
main() {
  case "${1:-all}" in
    all)       preflight; fetch; unpack; cache; build; tidy; axioms; verdict; manifest ;;
    preflight|fetch|unpack|cache|build|axioms|verdict|manifest|status|tidy) "$1" ;;
    *) die "unknown stage: $1" ;;
  esac
}
main "$@"; exit $?
