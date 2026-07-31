#!/usr/bin/env bash
# contract — does the RUNNING service do what its own /llms.txt says?
#
# stranger.sh checks a published artifact. This checks a deployed one, which is a
# different question with different failure modes: a service can be healthy,
# monitored and green while quietly contradicting the contract an agent reads to
# learn how to use it.
#
# The agent-first specs make /llms.txt the front door: an agent fetches it, reads
# the routes, and drives the service with no other context. If that document is
# wrong, the agent fails in a way nobody sees — it does not file an issue, and
# the service's own health check stays green throughout.
#
# It was written after `curl -I https://grange.intrane.fr/llms.txt` returned 401
# while `curl` returned 200: the front door answered "unauthorized" to a HEAD
# request, on two of eight live services. Every test in those repos passes,
# because none of them ever issued a HEAD.
#
# What it checks, per service:
#   1. /llms.txt is readable with NO credential (the front door must be open)
#   2. HEAD agrees with GET on it (a probe is not an attack)
#   3. every route the contract advertises exists, with the method it shows
#   4. routes the contract calls authenticated ACTUALLY refuse without a token
#      — the inverse failure, and the one that leaks
#
#   ./contract.sh https://grange.intrane.fr [https://peage.intrane.fr ...]
set -u
fails=0
warns=0
check() { if [ "$2" = "1" ]; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }
warn()  { echo "  warn $1"; warns=$((warns + 1)); }

SERVICES="$*"
[ -n "$SERVICES" ] || SERVICES="https://grange.intrane.fr https://peage.intrane.fr \
https://relais.intrane.fr https://sso.intrane.fr https://vigie.intrane.fr \
https://cuzz.intrane.fr https://hart.intrane.fr https://idp.intrane.fr"

WORK=$(mktemp -d /tmp/contract-XXXX)
broke=""

for BASE in $SERVICES; do
  NAME=$(printf '%s' "$BASE" | sed 's|https\?://||; s|\..*||')
  HOST=$(printf '%s' "$BASE" | sed 's|https\?://||; s|/.*||')
  echo "== $BASE"

  # ---- 1. the front door, with no credential at all
  CODE=$(curl -s -o "$WORK/llms" -w '%{http_code}' -m 25 "$BASE/llms.txt" 2>/dev/null)
  if [ "$CODE" = "200" ] && [ -s "$WORK/llms" ]; then
    check "$NAME: /llms.txt is readable unauthenticated ($(wc -c < "$WORK/llms") bytes)" 1
  else
    check "$NAME: /llms.txt returned $CODE — an agent cannot learn this service" 0
    broke="$broke $NAME(front-door)"
    continue
  fi

  # ---- 2. HEAD must agree with GET. A HEAD is what every link checker, uptime
  #         probe and cautious client sends first; answering 401 to it while
  #         answering 200 to GET is a lie told to exactly the careful callers.
  HCODE=$(curl -s -I -o /dev/null -w '%{http_code}' -m 25 "$BASE/llms.txt" 2>/dev/null)
  if [ "$HCODE" = "$CODE" ]; then
    check "$NAME: HEAD agrees with GET on the front door" 1
  else
    check "$NAME: HEAD /llms.txt returns $HCODE but GET returns $CODE — the method changes the answer" 0
    broke="$broke $NAME(head-disagrees)"
  fi

  # ---- 3. every advertised route must exist. Routes are read out of the
  #         contract itself rather than a list kept here, so a service that adds
  #         or removes one is checked against what it currently claims.
  # Contracts write routes two ways, and an extractor that only knows one
  # reports "every advertised route exists (1 probed)" about a document
  # describing twenty. grange and hart use shell examples ($G/find, -X POST
  # "$G/bulk"); the others use prose tables (GET /health).
  # Request BODIES are not route documentation. peage's contract contains
  # -d '{"memo":"GET /search"}' — a human-readable memo inside an example
  # payload — and the extractor read it as an advertised route, then reported a
  # 404 for something the service never claimed to serve. Strip curl body lines
  # before looking for routes at all.
  grep -v -- "-d '" "$WORK/llms" | grep -v '"memo"' > "$WORK/llms_routes"
  ROUTES=$( { grep -ohE '(GET|POST|PUT|DELETE) +/[a-zA-Z0-9_./-]*' "$WORK/llms_routes" | sed 's/  */ /g'
              grep -ohE '(-X (POST|PUT|DELETE) +)?"?\$[A-Z_]+/[a-zA-Z0-9_./-]+' "$WORK/llms_routes" \
                | sed -E 's|-X (POST\|PUT\|DELETE) "?\$[A-Z_]+|\1 |; s|^"?\$[A-Z_]+|GET |' \
                | sed 's/  */ /g'
              # A third form: absolute URLs inside curl examples — but ONLY for
              # THIS service's host. The first version stripped the host from
              # every URL in the document, so github.com/javimosch/machin-hart
              # became the route "/javimosch/machin-hart" and was reported as a
              # 404 on hart. A contract that links elsewhere is not a contract
              # that lies about itself.
              # `-X POST "https://..."` AND the prose form `POST https://...`.
              # Only the first was handled, so a POST-only route documented in
              # prose was probed with GET and reported as a 404 that did not
              # exist — the method must come from the document, not a default.
              grep -ohE "((-X )?(POST|PUT|DELETE) +)?'?\`?https://$HOST/[a-zA-Z0-9_./-]+" "$WORK/llms_routes" \
                | sed -E "s|(-X )?(POST\|PUT\|DELETE) '?\`?https://$HOST|\2 |; s|^'?\`?https://$HOST|GET |" \
                | sed 's/  */ /g'
            } | sed 's/[?&].*//' | sort -u | head -40)
  GHOSTS=""
  N=0
  while IFS=' ' read -r METHOD ROUTE; do
    [ -n "${ROUTE:-}" ] || continue
    case "$ROUTE" in
      */) continue ;;
      *'<'*|*'{'*) continue ;;   # templated paths need values we do not have
      # placeholder examples: a contract showing /a/you/name is teaching a shape,
      # not advertising a route, and probing it reports a 404 that means nothing
      */you/*|*/name|*example*|*YOUR*|*your-*) continue ;;
      # elided placeholders: relais documents catch_url as /c/in_.. — the ".."
      # means "your id goes here", and probing it literally proves nothing
      *..*) continue ;;
    esac
    N=$((N + 1))
    if [ "$METHOD" = "GET" ]; then
      RC=$(curl -s -o /dev/null -w '%{http_code}' -m 20 "$BASE$ROUTE" 2>/dev/null)
    else
      RC=$(curl -s -o /dev/null -w '%{http_code}' -m 20 -X "$METHOD" "$BASE$ROUTE" -d '{}' 2>/dev/null)
    fi
    # 404 means the contract advertises something that is not there. Anything
    # else — 200, 400, 401, 402, 422 — means the route EXISTS and is reacting,
    # which is all this check can honestly assert without credentials.
    [ "$RC" = "404" ] && GHOSTS="$GHOSTS $METHOD:$ROUTE"
  done <<EOF
$ROUTES
EOF
  if [ "$N" = "0" ]; then
    # "every advertised route exists (0 probed)" is not a pass, it is a checker
    # that could not read the document. hart's contract writes absolute URLs
    # inside curl examples and scored a clean 0 for exactly that reason.
    warn "$NAME: no routes could be extracted from this contract — not verified"
  elif [ -z "$GHOSTS" ]; then
    check "$NAME: every advertised route exists ($N probed)" 1
  else
    check "$NAME: the contract advertises routes that 404:$GHOSTS" 0
    broke="$broke $NAME(ghost-routes)"
  fi

  # ---- 4. the inverse, and the one that leaks: a route the contract describes
  #         as gated must actually refuse an anonymous caller. A service that
  #         documents authentication it does not enforce is worse than one that
  #         documents none.
  LEAKS=""
  for R in /stats /usage /collections /dbs /admin /sessions /api/sessions /api/stats/overview; do
    grep -q -- "$R" "$WORK/llms" || continue
    RC=$(curl -s -o "$WORK/body" -w '%{http_code}' -m 20 "$BASE$R" 2>/dev/null)
    if [ "$RC" = "200" ]; then
      # a 200 is only a leak if it returns something other than an error envelope
      if grep -qi '"ok":false\|error' "$WORK/body" 2>/dev/null; then :; else
        LEAKS="$LEAKS $R"
      fi
    fi
  done
  [ -z "$LEAKS" ] && check "$NAME: documented-as-gated routes refuse an anonymous caller" 1 \
    || check "$NAME: these answer 200 with data and no credential:$LEAKS" 0
  [ -n "$LEAKS" ] && broke="$broke $NAME(open-gate)"
done

rm -rf "$WORK"
printf '{"ok":%s,"failures":%d,"warnings":%d,"broke":"%s"}\n' \
  "$([ "$fails" = "0" ] && echo true || echo false)" "$fails" "$warns" "${broke# }"
[ "$fails" = "0" ] || exit 1
exit 0
