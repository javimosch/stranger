#!/usr/bin/env bash
# stranger — does your published tool work for someone who has none of your context?
#
# Every project's own test suite builds from source, in the repository, on a
# machine with the toolchain installed. None of that describes the person who
# found your README. They have a URL, a shell, and no reason to debug you.
#
# This walks that path instead: it fetches the PUBLISHED artifact into an empty
# directory with no repository, no toolchain, and a throwaway HOME, then checks
# that it runs and that it is what the README says it is.
#
# It was written after grange's documented install command turned out to have
# never worked — it pointed at an asset name no release had ever published, so
# `curl` wrote 9 bytes of "Not Found", `chmod +x` accepted it, and the tool
# answered "Not: command not found". Release downloads across every version:
# zero. A funnel with no users is also a funnel with no bug reports, so nothing
# was ever going to report it. The same sweep then found two SHIPPED tools whose
# READMEs promised "one static binary" while publishing dynamically linked ones
# that could not start on Debian 11, Ubuntu 20.04, RHEL 8 or Alpine.
#
# The checks that matter are the ones comparing the artifact to the CLAIM. A
# dynamically linked binary is not a bug; a dynamically linked binary under a
# paragraph promising no runtime dependencies is.
#
#   ./stranger.sh javimosch/grange
#   ./stranger.sh javimosch/vigie --asset vigie --repo-dir ~/ai/vigie
#   ./stranger.sh javimosch/roam --verb version
set -u

REPO=""
ASSET=""
REPO_DIR=""
VERB=""
KEEP=0
TAG="latest"
while [ $# -gt 0 ]; do
  case "$1" in
    --asset)    ASSET="$2"; shift 2 ;;
    --repo-dir) REPO_DIR="$2"; shift 2 ;;
    --verb)     VERB="$2"; shift 2 ;;
    --tag)      TAG="$2"; shift 2 ;;
    --keep)     KEEP=1; shift ;;
    -*)         echo "{\"ok\":false,\"error\":\"unknown option: $1\"}"; exit 64 ;;
    *)          REPO="$1"; shift ;;
  esac
done
[ -n "$REPO" ] || { echo '{"ok":false,"error":"usage: stranger.sh <owner/repo> [--asset NAME] [--repo-dir DIR] [--verb V]"}'; exit 64; }

NAME=$(basename "$REPO")
fails=0
warns=0
notes=""
check() { if [ "$2" = "1" ]; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }
warn()  { echo "  warn $1"; warns=$((warns + 1)); }
skip()  { echo "  skip $1"; }

WORK=$(mktemp -d "/tmp/stranger-$NAME-XXXX")
export HOME="$WORK/home"; mkdir -p "$HOME"
cd "$WORK" || exit 1

# THIS CHECKER IS NOT A USER.
#
# It downloads a binary into a fresh HOME and runs it several times, which to any
# usage-telemetry implementation looks exactly like a new machine being installed
# and used. grange recorded 15 "installs" — every one of them this script. The
# headline metric, "how many machines ran this", was entirely manufactured by the
# tool auditing it, and a daily sweep across 17 repos would have kept manufacturing
# it forever.
#
# DO_NOT_TRACK is the cross-vendor convention and cli-telemetry-spec requires
# honouring it before any network code runs. <TOOL>_TELEMETRY=0 covers the
# tool-specific switch for spec-conforming tools.
export DO_NOT_TRACK=1
TELVAR=$(printf '%s' "$NAME" | tr '[:lower:]-' '[:upper:]_')_TELEMETRY
export "$TELVAR=0"

# ---- 0. what does the README tell a stranger to do, and what does it promise?
#         Both are read from the repo, because the claim is half of every check
#         below. Without it this is a download test, and download tests pass on
#         tools nobody can install.
# Fetch by STATUS, not by emptiness. raw.githubusercontent returns the string
# "404: Not Found" as a 14-byte BODY, so a non-empty check treats it as a README
# — and because that made $README non-empty, the master fallback never ran. Every
# master-branch repo was then audited against a document containing no claims, no
# URLs and no install script, which reported them as having undocumented assets.
# Seven false alarms in the first scheduled run, and false alarms are how a check
# gets muted.
fetch_readme() {
  BODY=$(curl -sSL -m 25 -w '\n%{http_code}' "$1" 2>/dev/null)
  CODE=$(printf '%s' "$BODY" | tail -1)
  [ "$CODE" = "200" ] || return 1
  printf '%s' "$BODY" | sed '$d'
}
README=""
BRANCH=""
if [ -n "$REPO_DIR" ] && [ -f "$REPO_DIR/README.md" ]; then
  README=$(cat "$REPO_DIR/README.md"); BRANCH="local"
fi
if [ -z "$README" ]; then
  for b in main master; do
    if README=$(fetch_readme "https://raw.githubusercontent.com/$REPO/$b/README.md"); then BRANCH="$b"; break; fi
    README=""
  done
fi
if [ -n "$README" ]; then
  check "the README is reachable ($BRANCH) — a stranger reads this first" 1
else
  # A repo this checker cannot SEE is not a repo that is broken. Private (or
  # renamed) repos returned 404 on both branches and were reported as failures,
  # which put hart and crm-cli — both private — into a Telegram alert. A checker
  # that cries wolf about things it cannot inspect gets muted.
  echo "  skip $REPO is not publicly readable (private, renamed, or no README on main/master) — not judged"
  echo "{\"ok\":true,\"repo\":\"$REPO\",\"failures\":0,\"warnings\":0,\"notes\":\"not-public\"}"
  [ "$KEEP" = "0" ] && rm -rf "$WORK"
  exit 0
fi

CLAIMS_STATIC=0
echo "$README" | grep -qiE 'static(ally)?[- ](linked|binary)|single static binary|one static binary' && CLAIMS_STATIC=1
CLAIMS_NO_DEPS=0
echo "$README" | grep -qiE 'no (runtime )?dependencies|no glibc floor|zero dependencies|no Docker required' && CLAIMS_NO_DEPS=1

# the documented URL, exactly as printed — not one reconstructed from the API,
# because the whole point is whether what is WRITTEN DOWN works
DOC_URL=$(echo "$README" | grep -ohE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/(latest/download|download/[^/ ]+)/[A-Za-z0-9._-]+' | head -1)
if [ -n "$ASSET" ]; then
  URL="https://github.com/$REPO/releases/latest/download/$ASSET"
  [ "$TAG" != "latest" ] && URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
elif [ -n "$DOC_URL" ]; then
  URL="$DOC_URL"
else
  URL=""
fi

# ---- 1. is there anything to install at all?
# Distinguish "no releases" from "GitHub would not tell us". Unauthenticated
# api.github.com allows 60 requests an hour, and a rate-limited reply parsed as
# "no assets" turns a healthy repo into a failure report.
# A token raises the limit from 60/hour to 5000 and is optional: the checker must
# work for anyone auditing a repo they do not own.
GH_AUTH=""
[ -n "${GITHUB_TOKEN:-}" ] && GH_AUTH="Authorization: Bearer $GITHUB_TOKEN"
[ -z "$GH_AUTH" ] && [ -n "${GH_TOKEN:-}" ] && GH_AUTH="Authorization: Bearer $GH_TOKEN"
if [ -n "$GH_AUTH" ]; then
  API=$(curl -s -m 25 -H "$GH_AUTH" "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null)
else
  API=$(curl -s -m 25 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null)
fi
PUBLISHED=$(printf '%s' "$API" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    if isinstance(d, dict) and "rate limit" in (d.get("message") or "").lower():
        print("__RATELIMIT__")
    else:
        print(" ".join(a["name"] for a in d.get("assets", [])))
except Exception:
    print("")' 2>/dev/null)
if [ "$PUBLISHED" = "__RATELIMIT__" ]; then
  warn "GitHub API rate-limited — cannot tell whether releases exist; not judging this repo"
  echo "{\"ok\":true,\"repo\":\"$REPO\",\"failures\":$fails,\"warnings\":$warns,\"notes\":\"rate-limited\"}"
  [ "$KEEP" = "0" ] && rm -rf "$WORK"
  exit 0
fi

# An install SCRIPT is a documented install path too. The first version of this
# checker reported machin-terminal as having undocumented assets, when its README
# opens with `curl .../install.sh | bash` — a false positive, and the kind that
# would have had me "fixing" a README that was already correct.
INSTALL_SH=$(echo "$README" | grep -ohE 'https://raw\.githubusercontent\.com/[A-Za-z0-9_./-]+install[A-Za-z0-9_.-]*\.sh|https://[A-Za-z0-9_./-]+/install\.sh' | head -1)
if [ -z "$URL" ] && [ -n "$INSTALL_SH" ]; then
  SH_CODE=$(curl -sSL -o sh.txt -w '%{http_code}' -m 30 "$INSTALL_SH" 2>/dev/null)
  if [ "$SH_CODE" = "200" ] && [ -s sh.txt ]; then
    check "the documented install script resolves ($INSTALL_SH)" 1
    # it must reference a real release asset, or it will fail the same way a bad
    # URL does — just one level deeper, where nobody looks
    SH_ASSET=$(grep -ohE '[A-Za-z0-9_.-]+-(linux|darwin)[A-Za-z0-9_.-]*|releases/latest/download/[A-Za-z0-9._-]+' sh.txt | head -1 | sed 's|.*/||')
    if [ -n "$SH_ASSET" ] && echo "$PUBLISHED" | grep -q "$SH_ASSET"; then
      check "the install script points at a published asset ($SH_ASSET)" 1
    elif [ -n "$PUBLISHED" ]; then
      warn "could not confirm the install script's asset against published: $PUBLISHED"
    fi
    notes="$notes install-script"
  else
    check "the documented install script returns http $SH_CODE — the only install path is broken" 0
  fi
  echo "{\"ok\":$([ "$fails" = "0" ] && echo true || echo false),\"repo\":\"$REPO\",\"failures\":$fails,\"warnings\":$warns,\"notes\":\"${notes# }\"}"
  [ "$KEEP" = "0" ] && rm -rf "$WORK"
  exit $([ "$fails" = "0" ] && echo 0 || echo 1)
fi

if [ -z "$URL" ]; then
  if [ -n "$PUBLISHED" ]; then
    check "the README documents no download, but releases publish: $PUBLISHED" 0
    notes="$notes undocumented-assets"
  else
    # No artifact and no documented download. That is a legitimate choice —
    # build-from-source — but ONLY if the README says so. A README that promises
    # "one static binary" and offers nothing to download is the worse failure,
    # because the reader believes a binary exists.
    # "static binary" + no artifact is only a LIE when there is also no way to
    # get one. Where the README documents building from source, the claim
    # describes the build output and is true — bossless says "no public instance
    # and none is planned. Clone it, build it, own your own", and the first
    # version of this check called that a broken promise. A tool that flags
    # honest projects teaches you to ignore it.
    BUILDS_FROM_SOURCE=0
    echo "$README" | grep -qE '\./build\.sh|make build|go install|cargo install|git clone' && BUILDS_FROM_SOURCE=1
    if [ "$CLAIMS_STATIC" = "1" ] && [ "$BUILDS_FROM_SOURCE" = "0" ]; then
      check "the README promises a static binary, publishes NO artifact, and documents no way to build one" 0
      notes="$notes no-install-path"
    elif [ "$CLAIMS_STATIC" = "1" ]; then
      warn "no published artifact — 'static binary' describes the build output, and building is documented. A release would still save every reader a toolchain"
      notes="$notes source-only-by-design"
    else
      warn "no published artifact and none documented — build-from-source only"
      notes="$notes source-only"
    fi
  fi
  echo "{\"ok\":$([ "$fails" = "0" ] && echo true || echo false),\"repo\":\"$REPO\",\"failures\":$fails,\"warnings\":$warns,\"notes\":\"${notes# }\"}"
  [ "$KEEP" = "0" ] && rm -rf "$WORK"
  exit $([ "$fails" = "0" ] && echo 0 || echo 1)
fi

# ---- 2. the documented command, run verbatim
HTTP=$(curl -sSL -o bin -w '%{http_code}' -m 90 "$URL" 2>/dev/null)
[ "$HTTP" = "200" ] && check "the documented download URL resolves (http $HTTP)" 1 \
  || check "the documented download URL returns http $HTTP — a stranger gets nothing: $URL" 0
SIZE=$(wc -c < bin 2>/dev/null || echo 0)
[ "$SIZE" -gt 50000 ] 2>/dev/null && check "the download is a plausible binary ($SIZE bytes)" 1 \
  || check "the download is $SIZE bytes — an error page, not a binary" 0
chmod +x bin 2>/dev/null

# ---- 3. it must RUN with none of the author's machine around it
RUNS=0
if [ -x ./bin ] && ./bin --help >/dev/null 2>&1 || ./bin help >/dev/null 2>&1 || ./bin version >/dev/null 2>&1 || ./bin guide >/dev/null 2>&1; then
  RUNS=1
  check "the artifact executes here (no toolchain, no repo, empty HOME)" 1
else
  ERR=$(./bin --help 2>&1 | head -c 100)
  check "the artifact does not execute: $ERR" 0
fi

# ---- 4. artifact vs claim. These are gated on RUNS because they LIE on a
#         non-binary: ldd reports "not a dynamic executable" for a text file and
#         objdump finds no GLIBC symbols in one, so a 404 error page scores
#         "static, as promised".
if [ "$RUNS" = "0" ]; then
  [ "$CLAIMS_STATIC" = "1" ] && check "linkage cannot be assessed: the download is not runnable" 0
else
  LIBS=$(ldd ./bin 2>&1 | grep -oE 'lib[a-z0-9_]+\.so[^ ]*' | sort -u | tr '\n' ' ')
  STATIC=0
  ldd ./bin 2>&1 | grep -q "not a dynamic executable" && STATIC=1
  FLOOR=$(objdump -T ./bin 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1)

  if [ "$CLAIMS_STATIC" = "1" ] || [ "$CLAIMS_NO_DEPS" = "1" ]; then
    if [ "$STATIC" = "1" ]; then
      check "the README promises static, and the published binary is static" 1
    else
      check "the README promises a STATIC binary but the release links: $LIBS" 0
      notes="$notes false-static-claim"
    fi
    if [ -z "$FLOOR" ]; then
      check "no glibc floor, as promised" 1
    else
      # this is the concrete consequence, so name the distros rather than the symbol
      check "the README promises no glibc floor but the release needs $FLOOR — will not start on Debian 11, Ubuntu 20.04, RHEL 8, Alpine" 0
      notes="$notes glibc-floor"
    fi
  else
    [ "$STATIC" = "1" ] && echo "  ok   static binary (not claimed, but true)" \
      || warn "dynamically linked (${FLOOR:-no floor}): $LIBS — not claimed static, so not a broken promise, but it limits where it runs"
  fi
fi

# ---- 5. the agent-first contract (cli-guide-spec / cli-output-spec). A tool
#         that advertises these must honour them from a cold artifact, which is
#         the only place it matters.
if [ "$RUNS" = "1" ]; then
  # A mistyped verb must FAIL. Checked before anything else, because if a tool
  # exits 0 on nonsense then every "does this verb exist?" probe below is
  # meaningless — that is how this checker came to report "guide runs but is not
  # valid JSON" about a tool with no guide verb at all.
  ./bin zzz-not-a-real-verb >/dev/null 2>&1
  BADRC=$?
  BADOUT=$(./bin zzz-not-a-real-verb 2>&1 | head -c 200)
  if [ "$BADRC" = "0" ]; then
    check "a mistyped verb exits 0 — an agent cannot tell a typo from success (cli-output-spec: 80-89)" 0
    notes="$notes zero-exit-on-typo"
    VERB_PROBE_OK=0
  else
    check "a mistyped verb exits non-zero ($BADRC), so a typo is detectable" 1
    VERB_PROBE_OK=1
  fi

  # has_verb: exit 0 AND output that does not say "unknown command"
  has_verb() {
    ./bin "$1" >/dev/null 2>&1 || return 1
    [ "$VERB_PROBE_OK" = "1" ] && return 0
    ./bin "$1" 2>&1 | grep -qiE "unknown (command|verb)|usage:" && return 1
    return 0
  }

  if has_verb guide; then
    ./bin guide 2>/dev/null | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
      && check "guide is valid JSON, so an agent can drive it cold" 1 \
      || check "guide runs but is not valid JSON" 0
  else
    echo "$README" | grep -q "guide" && warn "the README mentions a guide but \`$NAME guide\` does not run" \
      || skip "no guide verb (cli-guide-spec not adopted)"
  fi
  if has_verb help-json; then
    ./bin help-json 2>/dev/null | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
      && check "help-json is a machine-readable catalog" 1 || check "help-json is not valid JSON" 0
  else
    skip "no help-json verb"
  fi
  # ---- does it phone home, and does it stop when told to?
  #
  # Two different questions, and users deserve both answers. Whether a tool sends
  # anything at all is a disclosure; whether it KEEPS sending after DO_NOT_TRACK=1
  # is a defect — cli-telemetry-spec requires that switch to be honoured before
  # any network code runs, and DO_NOT_TRACK is a cross-vendor convention that
  # predates it.
  #
  # Measured with strace when available, because it needs no cooperation from the
  # tool: a connect() to a non-loopback address is a connect() whatever the
  # binary claims. Where strace is absent this is skipped rather than guessed —
  # dk1, which runs the scheduled sweep, has no strace, and a check that silently
  # degrades into "pass" is worse than one that says it did not run.
  if command -v strace >/dev/null 2>&1; then
    # One number, always. The first version chained greps with `||` and printed
    # "0\n0\n0", which the arithmetic below then read as non-zero — reporting
    # "it made 0 connections DESPITE DO_NOT_TRACK=1" about a tool that had made
    # none.
    conns() {
      rm -f "$WORK/st.txt"
      env "$@" strace -f -e trace=connect -o "$WORK/st.txt" ./bin "$PROBE_VERB" >/dev/null 2>&1
      [ -f "$WORK/st.txt" ] || { echo 0; return; }
      grep 'connect(' "$WORK/st.txt" 2>/dev/null \
        | grep -v 'AF_UNIX\|AF_NETLINK\|127\.0\.0\.1\|ENOENT' \
        | wc -l | tr -d ' '
    }
    # The probe verb must be one the tool ACTUALLY has and that completes
    # normally. "version"/"help" were tried first and grange has neither — an
    # unknown verb exits before any telemetry runs, so the probe measured a code
    # path that could not phone home and concluded the tool never does.
    PROBE_VERB=""
    for cand in ${VERB:-} guide help-json version help; do
      [ -n "$cand" ] || continue
      if has_verb "$cand"; then PROBE_VERB="$cand"; break; fi
    done
    [ -n "$PROBE_VERB" ] || PROBE_VERB="help"

    # OFF: the switch must be honoured. A fresh HOME each time, because the first
    # run on a machine is exactly when a tool has most reason to announce itself.
    HOME="$WORK/dnt"; mkdir -p "$HOME"
    OFF=$(conns DO_NOT_TRACK=1 "$TELVAR=0")
    HOME="$WORK/home"
    if [ "${OFF:-0}" -eq 0 ] 2>/dev/null; then
      check "no outbound connection with DO_NOT_TRACK=1 — the off switch is real" 1
    else
      check "it made $OFF outbound connection(s) DESPITE DO_NOT_TRACK=1" 0
      notes="$notes ignores-do-not-track"
    fi

    # ON: informational. Phoning home is a choice; concealing it is the problem.
    HOME="$WORK/on"; mkdir -p "$HOME"
    # BOTH switches must be cleared: this script exports $TELVAR=0 for the whole
    # sandbox, so clearing DO_NOT_TRACK alone left the tool-specific opt-out in
    # force and the "on" probe was still off.
    # Aimed at TEST-NET-1 (RFC 5737, unroutable by definition) so the probe can
    # OBSERVE the connection attempt without delivering anything to a real
    # collector — otherwise the check that exists to stop this script polluting
    # someone's metrics would itself send an event on every audit.
    #
    # Only works for tools that honour <TOOL>_TELEMETRY_URL, which
    # cli-telemetry-spec requires (§5.5). A tool with a hardcoded endpoint will
    # receive one event per audit; that is a reason for the spec to require the
    # override, not a reason to skip the check.
    URLVAR="${TELVAR}_URL"
    ON=$(conns DO_NOT_TRACK= "$TELVAR=" "$URLVAR=http://192.0.2.1/stranger-probe")
    HOME="$WORK/home"
    if [ "${ON:-0}" -gt 0 ] 2>/dev/null; then
      echo "  info this tool contacts the network by default ($ON connection(s) on \`$NAME $PROBE_VERB\`) and stops when asked"
    else
      echo "  info this tool makes no outbound connection at all"
    fi
  else
    skip "phone-home check (strace not installed — not guessing)"
  fi

  # stdout discipline on whatever verb we can safely run
  V="${VERB:-version}"
  if OUT=$(./bin "$V" 2>/dev/null) && [ -n "$OUT" ]; then
    if echo "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
      check "\`$NAME $V\` puts parseable JSON on stdout" 1
    else
      warn "\`$NAME $V\` prints non-JSON on stdout (fine for a human verb, not for a data one)"
    fi
  fi
fi

cd /
[ "$KEEP" = "1" ] && echo "  kept: $WORK" || rm -rf "$WORK"

echo "{\"ok\":$([ "$fails" = "0" ] && echo true || echo false),\"repo\":\"$REPO\",\"failures\":$fails,\"warnings\":$warns,\"notes\":\"${notes# }\"}"
[ "$fails" = "0" ] || exit 1
exit 0
