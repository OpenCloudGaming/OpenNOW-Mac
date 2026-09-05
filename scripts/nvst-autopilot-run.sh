#!/bin/zsh
# scripts/nvst-autopilot-run.sh <cmsId> <shortName> <seconds> [defaults key=value ...]
# Drives one "OpenNOW Dev" session with nobody at the keyboard: writes a .gfnpc shortcut, opens the
# Debug build with OPN_NVST_AUTOPILOT_SECONDS (auto End Stream + quit) and OPN_NVST_AUTOPILOT_SCRIPT
# (`<s>:key36`, `<s>:click0.5,0.5`, `<s>:padA` (pad 0 button tap: A/B/X/Y/Start/Select/LB/RB/Up/Down/
# Left/Right), `<s>:reconnect` (in-place same-session reconnect), `<s>:snapName` -> $TMP/Name.jpg),
# waits, prints the log verdict. OPN_NVST_ANNOUNCE_OVERRIDES="x-nv-…=…;…" announces knobs verbatim (A/B).
# Extra args are defaults to write first, e.g. OpenNOW.Stream.ColorQualityIndex=2.
# Steam titles stop at the Steam password prompt: type it on the stream, the script carries on.
# Known cmsIds: Streets of Rage 4 100688311 streets_of_rage_4_gfn_pc; Manor Lords 101729111; BeamNG 100163111.
# Drives one OpenNOW Dev session from the shell and prints the log verdict.
set -u
CMS=$1; SHORT=$2; SECS=$3; shift 3
APP="$HOME/Library/Developer/Xcode/DerivedData/OpenNOW-aypoihoujtvbghfylbguaccefpxq/Build/Products/Debug/OpenNOW Dev.app"
DOMAIN=io.github.opencloudgaming.opennow.dev
TMP=${OPN_AUTOPILOT_DIR:-$HOME/Library/Logs/OpenNOW/autopilot}; mkdir -p "$TMP"
LOGDIR="$HOME/Library/Logs/OpenNOW"
DIAG="$HOME/Library/Caches/OpenNOW/OpenNOW-diagnostics-current.log"
for kv in "$@"; do defaults write "$DOMAIN" "${kv%%=*}" -int "${kv#*=}"; done
if pgrep -xq "OpenNOW Dev"; then echo "OpenNOW Dev already running; aborting"; exit 2; fi
GFN="$TMP/autopilot-$SHORT.gfnpc"
printf '{"url-route":"#?cmsId=%s&launchSource=External&shortName=%s&parentGameId=%s"}' "$CMS" "$SHORT" "$SHORT" > "$GFN"
before=$(/bin/ls -t "$LOGDIR" 2>/dev/null | head -1)
start=$(date +%s)
SHOT=${SHOT:-0}; SCRIPT=${SCRIPT:-}
open -a "$APP" --env "OPN_NVST_ANNOUNCE_OVERRIDES=${OPN_NVST_ANNOUNCE_OVERRIDES:-}" --env "OPN_NVST_AUTOPILOT_SECONDS=$SECS" --env "OPN_NVST_AUTOPILOT_SCRIPT=$SCRIPT" --env "OPN_NVST_AUTOPILOT_SNAPSHOT_DIR=$TMP" "$GFN" || { echo "open failed"; exit 3; }
limit=$((SECS + 150)); shot_done=0
while pgrep -xq "OpenNOW Dev"; do
  sleep 3
  if (( SHOT > 0 && shot_done == 0 && $(date +%s) - start >= SHOT )); then screencapture -x -t jpg "$TMP/shot-$SHORT.jpg"; shot_done=1; echo "shot at +${SHOT}s -> $TMP/shot-$SHORT.jpg"; fi
  if (( $(date +%s) - start > limit )); then echo "timeout; killing"; pkill -x "OpenNOW Dev"; break; fi
done
elapsed=$(( $(date +%s) - start ))
newest=$(/bin/ls -t "$LOGDIR" | head -1)
echo "run: cms=$CMS secs=$SECS elapsed=${elapsed}s log=$newest new=$([ "$newest" != "$before" ] && echo yes || echo NO)"
f="$LOGDIR/$newest"
/usr/bin/grep -hE 'decoder session created|NVST BITRATE|SESSION SUMMARY|control connection failed|keepalive GET_PARAMETER #1 ' "$f" | cut -c25-220
/usr/bin/grep -hE 'hud rtt=' "$f" | tail -1 | cut -c25-140
/usr/bin/grep -hE 'Video output format|Video presentation mode|16:9 title|Autopilot|Pillarbox fill mode' "$DIAG" | awk -v s="$(date -u -r $start +%Y-%m-%dT%H:%M)" '$1 >= s' | cut -c1-200 | tail -8
