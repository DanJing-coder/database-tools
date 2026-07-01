#!/usr/bin/env bash
# ============================================================
# sr_audit_analyzer.sh  —  StarRocks Audit Log Analyzer
# ============================================================
# Compatible with StarRocks 3.x audit log format (3.3, 3.5+)
#
# Background: each query produces TWO log entries — one tagged
# [query] and, if slow, one tagged [slow_query] — sharing the
# same QueryId.  By default only [query] entries are processed
# to avoid double-counting.  Use --slow-only or --all-tags to
# change this behaviour.
#
# Requirements: gawk 4+, sort, head  (standard on Linux/macOS)
# ============================================================
#
# MODULES
#   top    — rank queries by CPU / memory / scan rows / scan bytes / time
#   search — count SQL execution frequency by keyword
#
# USAGE
#   ./sr_audit_analyzer.sh top    -m METRIC  [options]
#   ./sr_audit_analyzer.sh search -k KEYWORD [options]
#
# Run with -h / --help for full option reference.
# ============================================================

set -uo pipefail

SCRIPT="$(basename "$0")"
DEFAULT_LOG="fe.audit.log"
DEFAULT_TOP=20
DEFAULT_STMT_LEN=150

# ── terminal colors (auto-disabled when not a tty) ─────────────────────────
if [[ -t 1 ]]; then
  B='\033[1m' C='\033[0;36m' Y='\033[1;33m' R='\033[0;31m' NC='\033[0m'
else
  B='' C='' Y='' R='' NC=''
fi

die()  { echo -e "${R}ERROR:${NC} $*" >&2; exit 1; }

# ── usage ──────────────────────────────────────────────────────────────────
usage() {
cat <<EOF
${B}StarRocks Audit Log Analyzer${NC}  (SR 3.x — 3.3, 3.5+)

${B}USAGE${NC}
  $SCRIPT top    -m METRIC  [options]
  $SCRIPT search -k KEYWORD [options]

${B}MODULE: top${NC}  — find top-N resource-consuming queries
  ${C}-m METRIC${NC}       Sort by: ${Y}cpu${NC} | ${Y}mem${NC} | ${Y}rows${NC} | ${Y}bytes${NC} | ${Y}time${NC}  (required)
                    cpu   → CpuCostNs
                    mem   → MemCostBytes
                    rows  → ScanRows
                    bytes → ScanBytes
                    time  → execution Time (ms)
  ${C}-f FILE${NC}         Audit log file  (default: $DEFAULT_LOG; use - for stdin)
  ${C}-n N${NC}            Show top-N results  (default: $DEFAULT_TOP)
  ${C}-l LEN${NC}          Truncate Stmt at LEN chars  (default: $DEFAULT_STMT_LEN)
  ${C}-u USER${NC}         Filter by username (e.g. bi_rw)
  ${C}--slow-only${NC}     Only analyze [slow_query] tagged entries
  ${C}--all-tags${NC}      Include all entries; dedup by QueryId

${B}MODULE: search${NC}  — count SQL execution frequency by keyword
  ${C}-k KEYWORD${NC}      Keyword to match inside Stmt  (required, case-insensitive)
  ${C}-f FILE${NC}         Audit log file  (default: $DEFAULT_LOG; use - for stdin)
  ${C}-g hour|minute${NC}  Time bucket granularity  (default: hour)
  ${C}-s STATE${NC}        Filter by query State field (e.g. OK, EOF)
  ${C}--slow-only${NC}     Only count [slow_query] tagged entries
  ${C}--all-tags${NC}      Count all entries; dedup by QueryId

${B}COMMON FLAGS${NC}  (apply to both modules)
  ${C}--filter STR${NC}    Pre-filter: only process lines containing STR (case-insensitive).
                    Matched against the entire log line before any other logic.
                    e.g. --filter delete  --filter "insert overwrite"
  ${C}--from DATETIME${NC} Only process entries at or after this time.
                    Formats: "YYYY-MM-DD" or "YYYY-MM-DD HH:MM:SS"
  ${C}--to DATETIME${NC}   Only process entries at or before this time.
                    Formats: "YYYY-MM-DD" or "YYYY-MM-DD HH:MM:SS"
  ${C}--slow-only${NC}     Only lines tagged [slow_query]
  ${C}--all-tags${NC}      All lines; first occurrence wins per QueryId
  (default)         Only lines tagged [query] — avoids double-counting

${B}EXAMPLES${NC}
  # Top 20 queries by CPU cost
  $SCRIPT top -m cpu

  # Top 10 slowest queries from a specific user
  $SCRIPT top -m time -n 10 -u bi_rw

  # Only look at DELETE statements
  $SCRIPT top -m rows --filter delete

  # Top scans within a specific time window
  $SCRIPT top -m bytes --from "2026-06-29 10:00:00" --to "2026-06-29 12:00:00"

  # How often does this INSERT run each hour?
  $SCRIPT search -k "insert overwrite \`mv_footprint_mp\`" -g hour

  # Per-minute frequency, only during business hours today
  $SCRIPT search -k "fact_agg_enterprise" -g minute --from "2026-06-29 09:00:00" --to "2026-06-29 18:00:00"

  # Pre-filter to DELETE ops, then count by hour
  $SCRIPT search -k "delete" -g hour --filter delete

  # Scan multiple rotated logs via stdin
  cat fe.audit.log* | $SCRIPT top -m cpu -f -
EOF
exit 0
}

# ── argument parsing ───────────────────────────────────────────────────────
[[ $# -eq 0 ]] && usage

MODULE="$1"; shift
[[ "$MODULE" == "-h" || "$MODULE" == "--help" ]] && usage
[[ "$MODULE" == "top" || "$MODULE" == "search" ]] \
  || die "Unknown module '$MODULE'. Valid modules: top | search"

LOG_FILE="$DEFAULT_LOG"
TOP_N="$DEFAULT_TOP"
STMT_LEN="$DEFAULT_STMT_LEN"
METRIC="" KEYWORD="" GRANULARITY="hour"
FILTER_USER="" FILTER_STATE=""
FILTER_FROM="" FILTER_TO="" PREFILTER=""
TAG_MODE="dedup"   # dedup | slow_only | all

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m) [[ -n "${2:-}" ]] || die "-m requires a value"; METRIC="$2";       shift 2 ;;
    -f) [[ -n "${2:-}" ]] || die "-f requires a value"; LOG_FILE="$2";     shift 2 ;;
    -n) [[ -n "${2:-}" ]] || die "-n requires a value"; TOP_N="$2";        shift 2 ;;
    -l) [[ -n "${2:-}" ]] || die "-l requires a value"; STMT_LEN="$2";     shift 2 ;;
    -u) [[ -n "${2:-}" ]] || die "-u requires a value"; FILTER_USER="$2";  shift 2 ;;
    -k) [[ -n "${2:-}" ]] || die "-k requires a value"; KEYWORD="$2";      shift 2 ;;
    -g) [[ -n "${2:-}" ]] || die "-g requires a value"; GRANULARITY="$2";  shift 2 ;;
    -s) [[ -n "${2:-}" ]] || die "-s requires a value"; FILTER_STATE="$2"; shift 2 ;;
    --filter) [[ -n "${2:-}" ]] || die "--filter requires a value"; PREFILTER="$2";     shift 2 ;;
    --from)   [[ -n "${2:-}" ]] || die "--from requires a value";   FILTER_FROM="$2";  shift 2 ;;
    --to)     [[ -n "${2:-}" ]] || die "--to requires a value";     FILTER_TO="$2";    shift 2 ;;
    --slow-only) TAG_MODE="slow_only"; shift ;;
    --all-tags)  TAG_MODE="all";       shift ;;
    -h|--help)   usage ;;
    *) die "Unknown option: '$1'  (run $SCRIPT -h for help)" ;;
  esac
done

# ── validations ─────────────────────────────────────────────────────────────
if [[ "$LOG_FILE" != "-" ]]; then
  [[ -f "$LOG_FILE" ]] || die "Log file not found: $LOG_FILE"
fi
[[ "$MODULE" == "top"    && -z "$METRIC"  ]] && die "top module requires -m METRIC"
[[ "$MODULE" == "search" && -z "$KEYWORD" ]] && die "search module requires -k KEYWORD"
[[ "$GRANULARITY" =~ ^(hour|minute)$ ]]       || die "-g must be 'hour' or 'minute'"
if [[ -n "$METRIC" ]]; then
  [[ "$METRIC" =~ ^(cpu|mem|rows|bytes|time)$ ]] \
    || die "-m must be one of: cpu | mem | rows | bytes | time"
fi

AWK_INPUT="$( [[ "$LOG_FILE" == "-" ]] && echo "/dev/stdin" || echo "$LOG_FILE" )"

# ── shared AWK utility library ─────────────────────────────────────────────
# Loaded as the first argument to every gawk call below.
read -r -d '' AWK_LIB <<'AWKLIB' || true
# ── Field extractors ──────────────────────────────────────────────────────

# Numeric field value (safe: numeric values never contain "|")
function gnum(line, f,    re, a) {
    re = "\\|" f "=([0-9]+)"
    if (match(line, re, a)) return a[1] + 0
    return 0
}

# String field value (safe for fields whose values do not contain "|")
function gstr(line, f,    re, a) {
    re = "\\|" f "=([^|]*)"
    if (match(line, re, a)) return a[1]
    return ""
}

# Stmt field — handles SQL that contains "|" characters.
# Relies on the invariant: the field immediately after Stmt always
# starts with "|<UppercaseLetter...>=" (e.g. |Digest=, |PlanCpuCost=).
# This holds across StarRocks 3.3 and 3.5.
function gstmt(line,    p, rest) {
    p = index(line, "|Stmt=")
    if (!p) return ""
    rest = substr(line, p + 6)
    if (match(rest, /\|[A-Z][A-Za-z]+=/) > 0)
        return substr(rest, 1, RSTART - 1)
    return rest
}

# Datetime prefix: YYYY-MM-DD HH:MM:SS  (always the first 19 characters)
function gdt(line) {
    if (match(line, /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/))
        return substr(line, RSTART, RLENGTH)
    return "N/A"
}

# Log entry tag: "query" or "slow_query" (extensible for future tags)
function gtag(line,    a) {
    if (match(line, /\[([a-z_]+)\]/, a)) return a[1]
    return "query"
}

# ── Formatters ─────────────────────────────────────────────────────────────

function trunc(s, n) {
    if (length(s) <= n) return s
    return substr(s, 1, n) "..."
}

# Bytes → human-readable (B / KB / MB / GB)
function fbytes(b) {
    if (b >= 1073741824) return sprintf("%.2f GB", b / 1073741824)
    if (b >= 1048576)    return sprintf("%.2f MB", b / 1048576)
    if (b >= 1024)       return sprintf("%.2f KB", b / 1024)
    return b " B"
}

# Large integer → human-readable (K / M / B suffix)
function fnum(n) {
    if (n >= 1000000000) return sprintf("%.2fB", n / 1000000000)
    if (n >= 1000000)    return sprintf("%.2fM", n / 1000000)
    if (n >= 1000)       return sprintf("%.2fK", n / 1000)
    return n ""
}

# Milliseconds → human-readable duration
function fms(ms) {
    if (ms >= 3600000) return sprintf("%.1f h",   ms / 3600000)
    if (ms >= 60000)   return sprintf("%.1f min", ms / 60000)
    if (ms >= 1000)    return sprintf("%.2f s",   ms / 1000)
    return ms " ms"
}
AWKLIB

# ══════════════════════════════════════════════════════════════════════════
# MODULE: top
# ══════════════════════════════════════════════════════════════════════════
run_top() {
  local sort_field
  case "$METRIC" in
    cpu)   sort_field="CpuCostNs"    ;;
    mem)   sort_field="MemCostBytes" ;;
    rows)  sort_field="ScanRows"     ;;
    bytes) sort_field="ScanBytes"    ;;
    time)  sort_field="Time"         ;;
  esac

  echo -e "${B}Top ${TOP_N} queries — sorted by: ${C}${METRIC}${NC}${B} (${sort_field})${NC}" >&2
  echo -e "File: ${LOG_FILE}  |  Tag mode: ${TAG_MODE}${FILTER_USER:+  |  User: $FILTER_USER}" >&2
  [[ -n "$PREFILTER"   ]] && echo -e "Pre-filter  : ${PREFILTER}" >&2
  [[ -n "$FILTER_FROM" ]] && echo -e "From        : ${FILTER_FROM}" >&2
  [[ -n "$FILTER_TO"   ]] && echo -e "To          : ${FILTER_TO}" >&2
  echo "" >&2

  # ── Pass 1: parse + emit sortable TSV records ──────────────────────────
  # Output format:
  #   zero-padded-sort-key TAB datetime TAB queryid TAB state TAB
  #   time_ms TAB scan_rows TAB scan_bytes TAB cpu_ns TAB mem_bytes TAB
  #   ret_rows TAB user TAB stmt(truncated)
  gawk -v sf="$sort_field" \
       -v tm="$TAG_MODE" \
       -v fu="$FILTER_USER" \
       -v sl="$STMT_LEN" \
       -v prefilter="$PREFILTER" \
       -v from_dt="$FILTER_FROM" \
       -v to_dt="$FILTER_TO" \
       "$AWK_LIB"'
  {
    # ── Pre-filter: whole-line string match (cheapest, runs first) ──
    if (prefilter != "" && !index(tolower($0), tolower(prefilter))) next

    # ── Time range filter ──
    dt = gdt($0)
    if (from_dt != "" && dt < from_dt) next
    if (to_dt   != "" && dt > to_dt)   next

    tag = gtag($0)

    # Tag-mode filtering
    if (tm == "slow_only" && tag != "slow_query") next
    if (tm == "dedup"     && tag != "query")      next
    # tm == "all": accept everything, dedup by QueryId below

    qid = gstr($0, "QueryId")
    if (!qid) next

    # Dedup for "all" mode: first occurrence (by file order) wins
    if (tm == "all" && seen[qid]++) next

    # Optional user filter
    user = gstr($0, "User")
    if (fu != "" && user != fu) next

    # Extract remaining fields (dt already set above)
    state  = gstr($0, "State")
    t_ms   = gnum($0, "Time")
    scan_b = gnum($0, "ScanBytes")
    scan_r = gnum($0, "ScanRows")
    ret_r  = gnum($0, "ReturnRows")
    cpu_ns = gnum($0, "CpuCostNs")
    mem_b  = gnum($0, "MemCostBytes")
    stmt   = trunc(gstmt($0), sl)

    # Sort key — zero-padded for safe lexicographic + numeric sort
    if      (sf == "CpuCostNs")    sk = cpu_ns
    else if (sf == "MemCostBytes") sk = mem_b
    else if (sf == "ScanRows")     sk = scan_r
    else if (sf == "ScanBytes")    sk = scan_b
    else                           sk = t_ms

    printf "%020d\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\n",
      sk, dt, qid, state,
      t_ms, scan_r, scan_b, cpu_ns, mem_b, ret_r,
      user, stmt
  }
  ' "$AWK_INPUT" \
  | sort -t$'\t' -k1 -rn \
  | head -n "$TOP_N" \
  | gawk -F'\t' '
  # Inline formatters for the display pass (cannot inherit from AWK_LIB here)
  function fbytes(b) {
    if (b >= 1073741824) return sprintf("%.2f GB", b/1073741824)
    if (b >= 1048576)    return sprintf("%.2f MB", b/1048576)
    if (b >= 1024)       return sprintf("%.2f KB", b/1024)
    return b " B"
  }
  function fnum(n) {
    if (n >= 1000000000) return sprintf("%.2fB", n/1000000000)
    if (n >= 1000000)    return sprintf("%.2fM", n/1000000)
    if (n >= 1000)       return sprintf("%.2fK", n/1000)
    return n ""
  }
  function fms(ms) {
    if (ms >= 3600000) return sprintf("%.1f h",   ms/3600000)
    if (ms >= 60000)   return sprintf("%.1f min", ms/60000)
    if (ms >= 1000)    return sprintf("%.2f s",   ms/1000)
    return ms " ms"
  }
  BEGIN {
    hdr = "%-4s  %-19s  %-7s  %-12s  %-10s  %-11s  %-14s  %-11s  %-8s  %s"
    sep = "----  -------------------  -------  ------------  ----------  -----------  --------------  -----------  --------  ----"
    printf hdr "\n", "#", "DateTime", "State", "Duration", "ScanRows", "ScanBytes", "CpuCost(ns)", "MemBytes", "RetRows", "User"
    print sep
  }
  {
    # $1=sk  $2=dt  $3=qid  $4=state  $5=t_ms  $6=scan_r  $7=scan_b
    # $8=cpu_ns  $9=mem_b  $10=ret_r  $11=user  $12=stmt
    rank++
    printf hdr "\n",
      rank, $2, $4, fms($5+0), fnum($6+0), fbytes($7+0),
      fnum($8+0), fbytes($9+0), fnum($10+0), $11
    printf "      QueryId : %s\n", $3
    printf "      Stmt    : %s\n", $12
    print  ""
  }
  END {
    if (rank == 0)
      print "No matching queries found." > "/dev/stderr"
    else
      printf "── %d result(s) shown ──\n", rank
  }
  '
}

# ══════════════════════════════════════════════════════════════════════════
# MODULE: search
# ══════════════════════════════════════════════════════════════════════════
run_search() {
  echo -e "${B}Search — keyword:${NC} \"${C}${KEYWORD}${NC}\"" >&2
  echo -e "File: ${LOG_FILE}  |  Granularity: ${GRANULARITY}  |  Tag mode: ${TAG_MODE}${FILTER_STATE:+  |  State: $FILTER_STATE}" >&2
  [[ -n "$PREFILTER"   ]] && echo -e "Pre-filter  : ${PREFILTER}" >&2
  [[ -n "$FILTER_FROM" ]] && echo -e "From        : ${FILTER_FROM}" >&2
  [[ -n "$FILTER_TO"   ]] && echo -e "To          : ${FILTER_TO}" >&2
  echo "" >&2

  gawk -v kw="$KEYWORD" \
       -v gran="$GRANULARITY" \
       -v tm="$TAG_MODE" \
       -v fstate="$FILTER_STATE" \
       -v prefilter="$PREFILTER" \
       -v from_dt="$FILTER_FROM" \
       -v to_dt="$FILTER_TO" \
       "$AWK_LIB"'
  {
    # ── Pre-filter: whole-line string match (cheapest, runs first) ──
    if (prefilter != "" && !index(tolower($0), tolower(prefilter))) next

    tag = gtag($0)

    # Tag-mode filtering
    if (tm == "slow_only" && tag != "slow_query") next
    if (tm == "dedup"     && tag != "query")      next

    # Dedup for "all" mode
    qid = gstr($0, "QueryId")
    if (tm == "all" && qid != "" && seen[qid]++) next

    # Keyword match against Stmt (case-insensitive)
    stmt = gstmt($0)
    if (!index(tolower(stmt), tolower(kw))) next

    # Optional State filter
    if (fstate != "" && gstr($0, "State") != fstate) next

    # ── Time range filter ──
    dt = gdt($0)
    if (from_dt != "" && dt < from_dt) next
    if (to_dt   != "" && dt > to_dt)   next

    bucket = (gran == "hour") ? substr(dt, 1, 13) : substr(dt, 1, 16)

    counts[bucket]++
    total++

    # Keep first example Stmt per bucket for reference
    if (!(bucket in examples))
        examples[bucket] = trunc(stmt, 100)

    # Accumulate unique users per bucket
    user = gstr($0, "User")
    if (user != "")
        user_set[bucket, user] = 1

    # Track overall date range
    if (first_dt == "" || dt < first_dt) first_dt = dt
    if (last_dt  == "" || dt > last_dt)  last_dt  = dt
  }
  END {
    if (total == 0) {
        print "No matching queries found." > "/dev/stderr"
        exit 0
    }

    n = asorti(counts, bkts)   # sort bucket keys chronologically

    # Find max count for sparkline scaling
    max_c = 0
    for (i = 1; i <= n; i++) if (counts[bkts[i]] > max_c) max_c = counts[bkts[i]]

    gran_label = (gran == "hour") ? "Hour Bucket   " : "Minute Bucket  "
    printf "%-20s  %8s  %s\n", gran_label, "Count", "Bar"
    printf "%-20s  %8s  %s\n", "--------------------", "--------", "---"

    for (i = 1; i <= n; i++) {
        k  = bkts[i]
        c  = counts[k]
        # ASCII bar, max width 30
        bw = int(c * 30 / max_c)
        bar = ""
        for (j = 0; j < bw; j++) bar = bar "█"
        printf "%-20s  %8d  %s\n", k, c, bar
    }

    # Summary footer
    printf "\n%-20s  %8d\n", "TOTAL", total
    printf "%-20s  %s\n",   "First match", first_dt
    printf "%-20s  %s\n",   "Last match",  last_dt
    printf "%-20s  %d\n",   "Distinct buckets", n

    # Print a sample SQL for reference
    printf "\n-- Sample Stmt (first bucket) --\n%s\n", examples[bkts[1]]
  }
  ' "$AWK_INPUT"
}

# ── dispatch ───────────────────────────────────────────────────────────────
case "$MODULE" in
  top)    run_top    ;;
  search) run_search ;;
esac