#!/bin/sh
# DynamicIsland4Mac agent hook — shared by Claude Code, Codex and any future provider.
#
#   agent-hook.sh <provider-id>                       observe an event (async hooks)
#   agent-hook.sh <provider-id> permission <seconds>  ask the island for a decision (opt-in)
#
# The agent passes the event as JSON on stdin. This script forwards it to the
# DynamicIsland4Mac app on 127.0.0.1 together with a few environment details the app uses to
# jump to the right terminal tab.
#
# SAFETY CONTRACT (both agents rely on this; keep it true when editing):
#   * Always exit 0, even if the app isn't running, curl is missing, or anything fails.
#   * Never print anything in event mode. Claude Code feeds async hook output back to the
#     model, and Codex rejects plain text on some events, so output would change behavior.
#   * Return immediately in event mode. Codex gives SessionEnd/Interrupt hooks 1-3 s, so the
#     upload runs in a detached background curl with all of its output sent to /dev/null
#     (a child holding our stdout open would make the agent wait for it).
#   * In permission mode, print only what the app returned with HTTP 200, which is the exact
#     decision JSON for that provider. On timeout, error or "no decision", print nothing, so
#     the agent shows its normal prompt. This script can never approve anything by itself.
#
# Keep this file stable between releases: Codex asks users to re-trust changed hooks.

provider="${1:-unknown}"
mode="${2:-event}"
wait_seconds="${3:-45}"

dir="$HOME/Library/Application Support/DynamicIsland4Mac"

# Read stdin first, always, so the agent never blocks writing to us.
payload=$(cat 2>/dev/null)

# The bearer token is passed to curl as a header *file* (mode 600, written by the app) rather
# than on the command line, where other local users could read it with `ps`.
auth="$dir/auth-header"
port=$(cat "$dir/port" 2>/dev/null)
[ -r "$auth" ] && [ -n "$port" ] || exit 0
command -v curl >/dev/null 2>&1 || exit 0

# Header values must be single-line.
clean() { printf '%s' "$1" | tr -d '\r\n' | cut -c 1-200; }

tty_name=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')
gppid=$(ps -o ppid= -p "$PPID" 2>/dev/null | tr -d ' ')

set -- \
  -H "@$auth" \
  -H "Content-Type: application/json" \
  -H "X-DI4M-Provider: $(clean "$provider")" \
  -H "X-DI4M-Term-Program: $(clean "${TERM_PROGRAM:-}")" \
  -H "X-DI4M-Term-Session: $(clean "${TERM_SESSION_ID:-}")" \
  -H "X-DI4M-ITerm-Session: $(clean "${ITERM_SESSION_ID:-}")" \
  -H "X-DI4M-TTY: $(clean "$tty_name")" \
  -H "X-DI4M-PPID: $(clean "$PPID")" \
  -H "X-DI4M-GPPID: $(clean "$gppid")" \
  -H "X-DI4M-Bundle: $(clean "${__CFBundleIdentifier:-}")"

if [ "$mode" = "permission" ]; then
  # Synchronous: wait (up to the timeout) for the user to decide in the island.
  response=$(printf '%s' "$payload" | curl -s --max-time "$wait_seconds" --connect-timeout 1 \
    -w '\n%{http_code}' -X POST "$@" --data-binary @- "http://127.0.0.1:$port/permission" 2>/dev/null)
  code=$(printf '%s' "$response" | tail -n 1)
  body=$(printf '%s' "$response" | sed '$d')
  if [ "$code" = "200" ] && [ -n "$body" ]; then
    printf '%s\n' "$body"
  fi
  exit 0
fi

# Observational: hand off to a detached curl and return at once.
( printf '%s' "$payload" | curl -s -o /dev/null --max-time 3 --connect-timeout 1 \
    -X POST "$@" --data-binary @- "http://127.0.0.1:$port/events" ) >/dev/null 2>&1 </dev/null &
exit 0
