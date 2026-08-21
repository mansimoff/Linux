#!/usr/bin/env bash
# audit-repo.sh — Red-flag / supply-chain audit for third-party repos
# (bash scripts, installers, python helpers, etc.) before you install them.
#
# This is NOT a replacement for ShellCheck (bugs) or ClamAV (known malware
# signatures). It specifically looks for the kind of things a security-aware
# human would grep for by hand when reviewing an unknown install.sh:
#   - remote-code-execution patterns (curl|bash, eval on untrusted input...)
#   - hidden network destinations
#   - privilege / persistence abuse (sudoers, cron, systemd, LD_PRELOAD...)
#   - obfuscation (base64/hex blobs, suspiciously long single lines)
#   - hardcoded secrets / key material
#   - git metadata sanity (age, author count, force-pushes)
#
# Usage:
#   ./audit-repo.sh /path/to/repo
#   ./audit-repo.sh /path/to/repo --strict     # exit non-zero on MEDIUM too
#   ./audit-repo.sh /path/to/repo --report out.txt
#
# Exit codes:
#   0 - no HIGH severity findings (MEDIUM/LOW may still be present)
#   1 - at least one HIGH severity finding
#   2 - usage error
#
# Requires only: bash 4+, grep (GNU, for -P/-o), find, git (optional)

set -uo pipefail

# ─────────────────────────── Args ────────────────────────────────────────
TARGET="${1:-}"
STRICT=0
REPORT_FILE=""

shift || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --strict) STRICT=1; shift ;;
        --report) REPORT_FILE="${2:-}"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^#//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$TARGET" || ! -d "$TARGET" ]]; then
    echo "Usage: $0 <path-to-repo> [--strict] [--report FILE]" >&2
    exit 2
fi
TARGET="$(cd "$TARGET" && pwd)"

# ─────────────────────────── Output plumbing ──────────────────────────────
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m' C_RED=$'\033[0;31m' C_YEL=$'\033[0;33m'
    C_GRN=$'\033[0;32m' C_BLU=$'\033[0;34m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
else
    C_RESET="" C_RED="" C_YEL="" C_GRN="" C_BLU="" C_BOLD="" C_DIM=""
fi

HIGH_COUNT=0
MED_COUNT=0
LOW_COUNT=0

# All findings are also mirrored to $REPORT_FILE (plain text, no colors) if set.
report() {
    if [[ -n "$REPORT_FILE" ]]; then
        # Strip ANSI color codes for the file copy.
        sed -E 's/\x1b\[[0-9;]*m//g' <<<"$*" >> "$REPORT_FILE"
    fi
}

say()  { echo -e "$*"; report "$*"; }
hi()   { HIGH_COUNT=$((HIGH_COUNT+1)); say "  ${C_RED}${C_BOLD}[HIGH]${C_RESET}   $*"; }
med()  { MED_COUNT=$((MED_COUNT+1));   say "  ${C_YEL}[MED]${C_RESET}    $*"; }
lo()   { LOW_COUNT=$((LOW_COUNT+1));   say "  ${C_DIM}[LOW]${C_RESET}    $*"; }
sect() { say ""; say "${C_BLU}${C_BOLD}== $* ==${C_RESET}"; }

[[ -n "$REPORT_FILE" ]] && : > "$REPORT_FILE"

say "${C_BOLD}audit-repo.sh${C_RESET} — scanning: ${C_BLU}${TARGET}${C_RESET}"
say "$(date -u +'%Y-%m-%d %H:%M:%S UTC')"

# ─────────────────────────── File set ─────────────────────────────────────
# Scriptable / executable-ish files we care about. Skip .git internals and
# obvious binary/vendor blobs.
mapfile -d '' SCRIPT_FILES < <(
    find "$TARGET" \
        -path '*/.git' -prune -o \
        -path '*/node_modules' -prune -o \
        -path '*/vendor' -prune -o \
        -type f \( \
            -name '*.sh' -o -name '*.bash' -o -name '*.zsh' -o \
            -name '*.py' -o -name '*.pl' -o -name '*.rb' -o \
            -name '*.ps1' -o -name '*.psm1' -o -name '*.vbs' -o \
            -name '*.ahk' -o -name 'Makefile' -o -name '*.service' -o \
            -name '*.timer' -o -name '*.desktop' \
        \) -print0
)

FILE_COUNT="${#SCRIPT_FILES[@]}"
say "Files scanned: ${FILE_COUNT}"

if [[ "$FILE_COUNT" -eq 0 ]]; then
    say "${C_YEL}No script-like files found — nothing to scan.${C_RESET}"
    exit 0
fi

# Helper: grep a pattern across all script files, print matches with context.
# Usage: scan_pattern <severity_fn> <label> <extended_regex> [grep_extra_args...]
scan_pattern() {
    local sev_fn="$1" label="$2" pattern="$3"; shift 3
    local hits
    hits=$(grep -nE "$pattern" "$@" "${SCRIPT_FILES[@]}" 2>/dev/null)
    if [[ -n "$hits" ]]; then
        "$sev_fn" "$label"
        while IFS= read -r line; do
            say "           ${C_DIM}${line#"$TARGET"/}${C_RESET}"
        done <<< "$hits"
    fi
}

# ═══════════════════════════ 1. Remote code execution ══════════════════════
sect "Remote code execution patterns"

scan_pattern hi "curl/wget piped straight into a shell (curl ... | bash)" \
    '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh|python[0-9.]*|perl)\b'

scan_pattern hi "process substitution running a freshly downloaded script" \
    'source[[:space:]]+<\(|\.[[:space:]]+<\(.*\b(curl|wget)\b'

scan_pattern med "eval on a variable (verify the variable can't contain attacker/network-controlled data)" \
    '\beval[[:space:]]+"?\$'

scan_pattern med "dynamic code execution via python exec()/eval()" \
    '\b(exec|eval)\s*\('  '--include=*.py'

# ═══════════════════════════ 2. Persistence / privilege abuse ══════════════
sect "Persistence & privilege escalation"

scan_pattern hi "writes to /etc/sudoers or adds NOPASSWD" \
    '/etc/sudoers|visudo|NOPASSWD'

scan_pattern hi "modifies crontab / at jobs" \
    '\bcrontab[[:space:]]+-|>[[:space:]]*/etc/cron|\bat[[:space:]]+now'

scan_pattern hi "installs a systemd unit outside the user's own runtime dir" \
    '/etc/systemd/system|/usr/lib/systemd/system'

scan_pattern hi "LD_PRELOAD / LD_LIBRARY_PATH manipulation" \
    'LD_PRELOAD|LD_LIBRARY_PATH='

scan_pattern hi "writes to SSH authorized_keys" \
    'authorized_keys'

scan_pattern med "chmod with world-writable or setuid/setgid bits" \
    'chmod[[:space:]]+([0-7]*[7][0-7]{2}|[ug]?\+s|4[0-7]{3}\b)'

scan_pattern med "sudo usage (expected in installers — verify each call)" \
    '\bsudo\b'

# ═══════════════════════════ 3. Network exfiltration / C2 ══════════════════
sect "Outbound network destinations"

DOMAINS=$(grep -rhoE 'https?://[a-zA-Z0-9._-]+' "${SCRIPT_FILES[@]}" 2>/dev/null \
            | sed -E 's#https?://##' | sort -u)
if [[ -n "$DOMAINS" ]]; then
    lo "Domains referenced in scripts (review each — expected: vendor/update URLs only):"
    while IFS= read -r d; do say "           ${C_DIM}${d}${C_RESET}"; done <<< "$DOMAINS"
else
    say "  ${C_GRN}No http(s):// URLs found in scripts.${C_RESET}"
fi

scan_pattern hi "raw TCP/UDP socket via bash /dev/tcp or /dev/udp (classic reverse shell primitive)" \
    '/dev/(tcp|udp)/'

scan_pattern hi "netcat used with -e / -c (command execution over a socket)" \
    '\bnc(\.traditional)?\b[^|]*-[a-zA-Z]*[ec]\b'

scan_pattern med "raw IP literal used as a connection target (harder to audit than a domain name)" \
    "https?://[0-9]{1,3}(\\.[0-9]{1,3}){3}"

# ═══════════════════════════ 4. Obfuscation ═════════════════════════════════
sect "Obfuscation heuristics"

scan_pattern med "base64 (or similar) decode piped directly into a shell/eval" \
    'base64[[:space:]]+-d[^|]*\|[[:space:]]*(bash|sh|eval)|base64[[:space:]]+--decode[^|]*\|[[:space:]]*(bash|sh|eval)'

scan_pattern med "xxd/od reversing hex back into a shell" \
    'xxd[[:space:]]+-r[^|]*\|[[:space:]]*(bash|sh)'

# Long single-line "blobs" (>500 chars on one line) often indicate packed /
# minified / obfuscated payloads hiding in an otherwise readable script.
LONG_LINES=$(grep -nE '^.{500,}$' "${SCRIPT_FILES[@]}" 2>/dev/null)
if [[ -n "$LONG_LINES" ]]; then
    med "Very long single lines (>500 chars) — could be minified/packed payloads, or just a long array/string; check manually"
    while IFS= read -r line; do
        f="${line%%:*}"; rest="${line#*:}"; ln="${rest%%:*}"
        say "           ${C_DIM}${f#"$TARGET"/}:${ln}${C_RESET}"
    done <<< "$LONG_LINES"
fi

# ═══════════════════════════ 5. Secret-like strings ═════════════════════════
sect "Hardcoded secrets / key material (heuristic — false positives expected)"

scan_pattern med "possible private key material committed to the repo" \
    '-----BEGIN (RSA|EC|OPENSSH|DSA|PGP) PRIVATE KEY-----'

scan_pattern lo "possible API-key / token-shaped assignment (var = long opaque string)" \
    '\b(api[_-]?key|secret|token|passwd|password)[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9_\-]{16,}["'"'"']' \
    '--exclude-dir=tests' '-i'

# ═══════════════════════════ 6. Filesystem footprint ════════════════════════
sect "Filesystem writes outside \$HOME"

scan_pattern med "writes to system paths (/etc, /usr, /opt) — expected only in an explicit, sudo'd installer step" \
    '(cp|mv|install|tee|>>?)[[:space:]].*[[:space:]](/etc/|/usr/(local/)?(bin|share|lib)/|/opt/)'

# ═══════════════════════════ 7. Git metadata sanity ══════════════════════════
sect "Git repository metadata"

if [[ -d "$TARGET/.git" ]] && command -v git >/dev/null 2>&1; then
    ( cd "$TARGET" && git config --global --add safe.directory "$TARGET" 2>/dev/null )
    COMMITS=$(git -C "$TARGET" log --oneline 2>/dev/null | wc -l)
    AUTHORS=$(git -C "$TARGET" log --format='%ae' 2>/dev/null | sort -u | wc -l)
    FIRST=$(git -C "$TARGET" log --format='%ad' --date=short 2>/dev/null | tail -1)
    LAST=$(git -C "$TARGET" log --format='%ad' --date=short 2>/dev/null | head -1)
    REMOTE=$(git -C "$TARGET" remote get-url origin 2>/dev/null || echo "none")

    say "  Commits: ${COMMITS}   Unique authors: ${AUTHORS}"
    say "  First commit: ${FIRST}   Last commit: ${LAST}"
    say "  Origin: ${REMOTE}"

    if [[ "$AUTHORS" -le 1 ]]; then
        lo "Single-author repository — no independent review of history; trust rests entirely on this one maintainer"
    fi

    # Rough "young repo" check: fewer than ~30 days between first and last commit
    # and still very active is fine; a repo that's only days old is worth extra
    # scrutiny before you let it touch a fintech dev box.
    if command -v date >/dev/null 2>&1 && [[ -n "$FIRST" ]]; then
        FIRST_EPOCH=$(date -d "$FIRST" +%s 2>/dev/null || echo 0)
        NOW_EPOCH=$(date +%s)
        AGE_DAYS=$(( (NOW_EPOCH - FIRST_EPOCH) / 86400 ))
        if [[ "$AGE_DAYS" -ge 0 && "$AGE_DAYS" -lt 14 ]]; then
            med "Repository is very young (${AGE_DAYS} days old) — less time for issues to surface publicly"
        else
            say "  Repository age: ~${AGE_DAYS} days"
        fi
    fi
else
    lo "Not a git checkout (or git unavailable) — can't assess history/author count"
fi

# ═══════════════════════════ Summary ════════════════════════════════════════
sect "Summary"
say "  ${C_RED}HIGH:${C_RESET}   ${HIGH_COUNT}"
say "  ${C_YEL}MEDIUM:${C_RESET} ${MED_COUNT}"
say "  ${C_DIM}LOW:${C_RESET}    ${LOW_COUNT}"
say ""

if [[ "$HIGH_COUNT" -gt 0 ]]; then
    say "${C_RED}${C_BOLD}Result: HIGH severity findings present. Manually review every flagged line before running anything from this repo.${C_RESET}"
elif [[ "$MED_COUNT" -gt 0 ]]; then
    say "${C_YEL}${C_BOLD}Result: No HIGH findings, but MEDIUM items need a manual look (most installers legitimately use sudo/eval — context matters).${C_RESET}"
else
    say "${C_GRN}${C_BOLD}Result: No red flags found by this heuristic scan. This does NOT guarantee safety — it only means the obvious patterns aren't present. Still read install.sh yourself.${C_RESET}"
fi

[[ -n "$REPORT_FILE" ]] && say "${C_DIM}(Full plain-text report written to ${REPORT_FILE})${C_RESET}"

if [[ "$HIGH_COUNT" -gt 0 ]]; then
    exit 1
elif [[ "$STRICT" -eq 1 && "$MED_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
