#!/bin/bash
# ============================================================
# statusline.sh — One-line Claude usage for the Claude Code status line.
#
#   5h 39% ↻1h21m · 7d 67%          (⚠ appended when on pace to hit a limit)
#
# Use it directly as the status line command, or call it from your own
# status line script and append its output. Prints nothing if usage is
# unavailable. Uses usage.sh's 60s cache, so it's cheap to run often.
# ============================================================

[ -t 0 ] || cat >/dev/null   # Claude Code pipes session JSON on stdin; not needed here

"$(dirname "$0")/usage.sh" claude --json 2>/dev/null | jq -r '
  def dur: (. / 86400 | floor) as $d | (. % 86400 / 3600 | floor) as $h | (. % 3600 / 60 | floor) as $m
    | if $d > 0 then "\($d)d\($h)h" elif $h > 0 then "\($h)h\($m)m" else "\($m)m" end;
  .tools[0] | select(.ok) | .windows as $w
  | ($w | map(select(.name == "5-hour")) | first) as $five
  | ($w | map(select(.name == "7-day")) | first) as $seven
  | [ ($five  | select(. != null) | "5h \(.used | floor)%" + (if .resets_in then " ↻\(.resets_in | dur)" else "" end)),
      ($seven | select(. != null) | "7d \(.used | floor)%") ]
  | join(" · ")
    + (if any($w[]; .pace == "over" or .pace == "limit") then " ⚠" else "" end)'
