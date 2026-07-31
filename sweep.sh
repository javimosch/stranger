#!/usr/bin/env bash
# Sweep every published tool and alert only when the answer CHANGES.
#
# M52 fixed eight broken install paths across the estate by hand. Nothing kept
# them fixed: most artifacts are built manually, the guards only fire if someone
# remembers to invoke them, and nothing re-checked after a release. The single
# thing standing between the estate and a repeat was me remembering to sweep.
#
# Transitions only, deliberately. A check that messages every day while
# something is wrong trains the recipient to mute it, which is worse than not
# checking at all — the same reasoning as readycheck.sh. It reports RECOVERY
# too, so nobody is left wondering whether it got fixed.
#
#   sweep.sh --repos "javimosch/grange javimosch/vigie ..." [--state /var/tmp/stranger.state]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
STATE="${STRANGER_STATE:-/var/tmp/stranger-sweep.state}"
TG_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TG_CHAT="${TELEGRAM_CHAT_ID:-}"
REPOS_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repos) REPOS_ARG="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --tg-token) TG_TOKEN="$2"; shift 2 ;;
    --tg-chat) TG_CHAT="$2"; shift 2 ;;
    *) echo "{\"ok\":false,\"error\":\"unknown option: $1\"}"; exit 64 ;;
  esac
done

# The default list is every repo the audit covered. A tool that drops off this
# list stops being checked silently, so it is written out rather than discovered.
DEFAULT_REPOS="javimosch/grange javimosch/roam javimosch/vigie javimosch/glane \
javimosch/cuzz javimosch/hart javimosch/relais javimosch/portier \
javimosch/machin-vault javimosch/machin-idp javimosch/machin-open-serpapi \
javimosch/machin-web-ui javimosch/tinybrain javimosch/poche javimosch/bossless \
javimosch/machin-terminal javimosch/crm-cli"
REPOS="${REPOS_ARG:-$DEFAULT_REPOS}"

PREV=""
[ -f "$STATE" ] && PREV=$(cat "$STATE" 2>/dev/null)

now_lines=""
broke=""
fixed=""
failing=0
checked=0

for repo in $REPOS; do
  name=${repo##*/}
  DIR=""
  [ -d "$HOME/ai/$name" ] && DIR="$HOME/ai/$name"
  if [ -n "$DIR" ]; then
    OUT=$("$HERE/stranger.sh" "$repo" --repo-dir "$DIR" 2>/dev/null | tail -1)
  else
    OUT=$("$HERE/stranger.sh" "$repo" 2>/dev/null | tail -1)
  fi
  checked=$((checked + 1))
  ST=$(echo "$OUT" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print("pass" if d.get("ok") else "FAIL:%s" % (d.get("notes") or "unspecified"))
except Exception:
    print("unreadable")' 2>/dev/null || echo unreadable)
  case "$ST" in FAIL*) failing=$((failing + 1)) ;; esac
  # A failure must be seen TWICE before it alerts.
  #
  # Two transient conditions produce a convincing false failure: raw.github's CDN
  # can serve a stale README for minutes after a push (so a repo you just fixed
  # reads as still broken), and the unauthenticated API allows 60 calls an hour,
  # which a few runs exhaust. Both self-clear by the next run. The first
  # scheduled run alerted on seven repos, none of which were broken, and an alert
  # that is usually wrong is worse than no alert.
  #
  # Recovery is reported on the FIRST pass, because being told too early that
  # something is fixed costs nothing.
  PREV_LINE=$(echo "$PREV" | grep "^$repo=" | head -1)
  WAS_N=${PREV_LINE##*#}
  case "$WAS_N" in ''|*[!0-9]*) WAS_N=0 ;; esac


  case "$ST" in
    FAIL*) N=$((WAS_N + 1)) ;;
    *)     N=0 ;;
  esac
  now_lines="$now_lines$repo=$ST#$N
"
  case "$ST" in
    FAIL*)
      # alert on the second consecutive failure only, and only once
      [ "$N" = "2" ] && broke="$broke $name($ST)"
      ;;
    pass)
      # recovered: it had failed at least twice (i.e. we alerted) and now passes
      [ "${WAS_N:-0}" -ge 2 ] 2>/dev/null && fixed="$fixed $name"
      ;;
  esac
done

# The LIVE services are a second surface with its own failure mode: an artifact
# can be perfect while the running service contradicts the contract an agent
# reads to drive it. Same debounce, same alert.
CONTRACT_OUT=""
if [ -x "$HERE/contract.sh" ]; then
  CONTRACT_OUT=$("$HERE/contract.sh" 2>/dev/null | tail -1)
  CBROKE=$(printf '%s' "$CONTRACT_OUT" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("broke",""))
except Exception: print("")' 2>/dev/null)
  CWAS=$(echo "$PREV" | grep "^__contract=" | head -1 | cut -d= -f2-)
  CN=${CWAS##*#}
  case "$CN" in ''|*[!0-9]*) CN=0 ;; esac
  if [ -n "$CBROKE" ]; then
    CN=$((CN + 1))
    [ "$CN" = "2" ] && broke="$broke contract:$CBROKE"
  else
    [ "${CN:-0}" -ge 2 ] 2>/dev/null && fixed="$fixed live-contracts"
    CN=0
  fi
  now_lines="${now_lines}__contract=${CBROKE:-pass}#${CN}
"
fi

printf '%s' "$now_lines" > "$STATE" 2>/dev/null || true

SENT=false
notify() {
  [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ] || return 0
  SENT=true
  curl -s -m 20 -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$TG_CHAT" --data-urlencode "text=$1" >/dev/null 2>&1
}

MSG=""
[ -n "$broke" ] && MSG="install path BROKE:$broke"
[ -n "$fixed" ] && MSG="$MSG${MSG:+ | }recovered:$fixed"
[ -n "$MSG" ] && notify "stranger sweep on $(hostname): $MSG
A documented install command that does not work is invisible to users — they cannot report what they could not run."

printf '{"ok":%s,"checked":%d,"failing":%d,"broke":"%s","recovered":"%s","contracts":%s,"transition":%s,"notified":%s}\n' \
  "$([ "$failing" = "0" ] && echo true || echo false)" "$checked" "$failing" \
  "${broke# }" "${fixed# }" "${CONTRACT_OUT:-null}" \
  "$([ -n "$MSG" ] && echo true || echo false)" "$SENT"
[ "$failing" = "0" ] || exit 1
exit 0
