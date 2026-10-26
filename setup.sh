#!/bin/bash

# BentoSpaces: add or remove the block in ~/.config/hypr/input.lua that loads
# the plugin's gestures.lua into Hyprland.
#
#   setup.sh status    prints enabled, manual or disabled
#   setup.sh enable    adds the block (after a backup) and reloads Hyprland
#   setup.sh disable   removes the block (after a backup) and reloads Hyprland
#
# Only the lines between the two markers are ever touched. The plugin runs
# this only when the Enable button in its settings popup is pressed.

set -euo pipefail

input="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/input.lua"
begin="-- >>> BentoSpaces (io.github.jjnuthuagen.bentospaces)"
end="-- <<< BentoSpaces"
plugin_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
home=$(cd -- "$HOME" && pwd -P)

fail() {
  echo "bentospaces: $1" >&2
  exit 1
}

has_block() {
  [[ -f $input ]] && grep -qxF -- "$begin" "$input"
}

# A block from the manual install instructions, without the markers.
has_manual_block() {
  [[ -f $input ]] && grep -qF -- "io.github.jjnuthuagen.bentospaces/gestures.lua" "$input" && ! has_block
}

# The path goes into a Lua string, so only plain path characters are allowed.
lua_path() {
  local rel
  [[ $plugin_dir == "$home"/* ]] || fail "plugin directory is outside \$HOME: $plugin_dir"
  rel=${plugin_dir#"$home"}
  [[ $rel =~ ^[A-Za-z0-9._/-]+$ ]] || fail "unsupported characters in plugin path: $plugin_dir"
  printf 'os.getenv("HOME") .. "%s/gestures.lua"' "$rel"
}

backup() {
  [[ -f $input ]] || return 0
  cp -p -- "$input" "$(mktemp -- "$input.bak.$(date +%s).XXXX")"
}

# Write through a temporary file in the same directory, then rename it over
# input.lua, so Hyprland never reads a half-written file.
replace_input() {
  local tmp
  tmp=$(mktemp -- "$input.XXXXXX")
  cat > "$tmp"
  [[ -f $input ]] && chmod --reference="$input" -- "$tmp"
  mv -f -- "$tmp" "$input"
}

reload_hyprland() {
  command -v hyprctl > /dev/null && hyprctl reload > /dev/null 2>&1 || true
}

case "${1:-status}" in
  status)
    if has_block; then echo enabled
    elif has_manual_block; then echo manual
    else echo disabled
    fi
    ;;
  enable)
    has_block || has_manual_block && exit 0
    path=$(lua_path)
    mkdir -p -- "$(dirname -- "$input")"
    backup
    {
      [[ -f $input ]] && cat -- "$input"
      printf '\n%s\n' "$begin"
      printf '%s\n' "-- Trackpad gestures and Mission Control for the BentoSpaces bar widget. Remove this"
      printf '%s\n' "-- block with the plugin's setup.sh disable, or delete it by hand."
      printf 'do\n  local ok, err = pcall(dofile, %s)\n' "$path"
      printf '%s\n' '  if not ok then print("bentospaces: " .. tostring(err)) end'
      printf 'end\n%s\n' "$end"
    } | replace_input
    reload_hyprland
    ;;
  disable)
    has_block || exit 0
    backup
    # Blank lines are held back so the one written before the block goes
    # with it, instead of piling up over repeated enable/disable.
    awk -v begin="$begin" -v end="$end" '
      $0 == begin { skip = 1; held = 0; next }
      skip { if ($0 == end) skip = 0; next }
      $0 == "" { held++; next }
      { while (held > 0) { print ""; held-- } print }
    ' "$input" | replace_input
    reload_hyprland
    ;;
  *)
    fail "usage: setup.sh status|enable|disable"
    ;;
esac
