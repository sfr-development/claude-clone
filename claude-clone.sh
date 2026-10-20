#!/usr/bin/env bash
# claude-clone - run several Claude accounts side by side (macOS and Linux).
#
# Finds Claude Desktop and Claude Code and creates extra, fully separate profiles ("clones").
# Every clone signs in on its own and gets its own launcher with the Claude icon.
# Your main installation is never modified.
#
#   ./claude-clone.sh                              interactive
#   ./claude-clone.sh --product desktop --names work,personal --yes
#   ./claude-clone.sh --list
#   ./claude-clone.sh --doctor        check every clone, change nothing
#   ./claude-clone.sh --repair        fix what --doctor finds
#   ./claude-clone.sh --remove work

set -euo pipefail

VERSION="1.3.0"
OS="$(uname -s)"

PRODUCT=""; COUNT=""; NAMES=""; BASE_PATH=""
SHARE=1; COPY=1; SHORTCUTS=1; MAIN_SHORTCUT=1; YES=0; LIST=0; REMOVE=""; PURGE=0; LAUNCH=""; DOCTOR=0

usage() {
  cat <<'EOF'
claude-clone - run several Claude accounts side by side (macOS and Linux).

Usage: claude-clone.sh [options]

Options:
  --product desktop|code|both   what to clone
  --count N                     number of clones (names default to account2, account3, ...)
  --names a,b                   clone names
  --path DIR                    where to store the profiles
  --no-share-sessions           do not share the Desktop session list with the main profile
  --no-copy-settings            do not copy MCP config / CLAUDE.md / skills
  --no-shortcuts                no launchers on the desktop / in the app menu
  --no-main-shortcut            no extra launcher for the main account
  --list                        list clones with their status (signed in, running)
  --doctor                      check every clone (dead links, missing folders), change nothing
  --repair                      fix what --doctor finds
  --launch NAME                 start a clone
  --remove NAME                 remove a clone (shortcuts and launchers)
  --purge                       with --remove: also delete the profile folder
  --yes                         accept all defaults, no questions
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --product) PRODUCT="$2"; shift 2 ;;
    --count) COUNT="$2"; shift 2 ;;
    --names) NAMES="$2"; shift 2 ;;
    --path) BASE_PATH="$2"; shift 2 ;;
    --no-share-sessions) SHARE=0; shift ;;
    --no-copy-settings) COPY=0; shift ;;
    --no-shortcuts) SHORTCUTS=0; shift ;;
    --no-main-shortcut) MAIN_SHORTCUT=0; shift ;;
    --list) LIST=1; shift ;;
    --doctor) DOCTOR=1; shift ;;
    --repair) DOCTOR=2; shift ;;
    --remove) REMOVE="$2"; shift 2 ;;
    --purge) PURGE=1; shift ;;
    --launch) LAUNCH="$2"; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

# ------------------------------------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------------------------------------
if [ -t 1 ]; then C_CY=$'\033[36m'; C_GR=$'\033[32m'; C_YE=$'\033[33m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else C_CY=""; C_GR=""; C_YE=""; C_DIM=""; C_B=""; C_0=""; fi
step() { printf '\n  %s%s%s\n' "$C_CY" "$1" "$C_0"; }
ok()   { printf '    %s[ok]%s %s\n' "$C_GR" "$C_0" "$1"; }
warn() { printf '    %s[!]%s  %s\n' "$C_YE" "$C_0" "$1"; }

ask() { # ask "question" "default" -> echo answer
  local q="$1" d="${2:-}" a=""
  if [ "$YES" = 1 ]; then printf '%s' "$d"; return; fi
  if [ -n "$d" ]; then { printf '  %s [%s] ' "$q" "$d" >/dev/tty; } 2>/dev/null || true; else { printf '  %s ' "$q" >/dev/tty; } 2>/dev/null || true; fi
  { IFS= read -r a </dev/tty; } 2>/dev/null || true
  if [ -z "$a" ]; then printf '%s' "$d"; else printf '%s' "$a"; fi
}

ask_yn() { # ask_yn "question" default(1|0) -> exit status
  local q="$1" d="${2:-1}" a="" hint="Y/n"
  if [ "$YES" = 1 ]; then [ "$d" = 1 ]; return; fi
  [ "$d" = 1 ] || hint="y/N"
  { printf '  %s [%s] ' "$q" "$hint" >/dev/tty; } 2>/dev/null || true
  { IFS= read -r a </dev/tty; } 2>/dev/null || true
  if [ -z "$a" ]; then [ "$d" = 1 ]; return; fi
  case "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" in y|yes|j|ja) return 0 ;; *) return 1 ;; esac
}

safe_name() { printf '%s' "$1" | sed 's/[^A-Za-z0-9_-]/-/g; s/^-*//; s/-*$//'; }

# ------------------------------------------------------------------------------------------
# State
# ------------------------------------------------------------------------------------------
STATE_DIR="$HOME/.claude-clone"
MANIFEST="$STATE_DIR/clones.tsv"   # name<TAB>product<TAB>dir<TAB>launcher<TAB>shortcut;shortcut<TAB>share
BIN_DIR="$HOME/.local/bin"
mkdir -p "$STATE_DIR"
touch "$MANIFEST"

desktop_folder() {
  local d=""
  if command -v xdg-user-dir >/dev/null 2>&1; then d="$(xdg-user-dir DESKTOP 2>/dev/null || true)"; fi
  [ -n "$d" ] && [ -d "$d" ] || d="$HOME/Desktop"
  printf '%s' "$d"
}
DESKTOP_DIR="$(desktop_folder)"

# ------------------------------------------------------------------------------------------
# Detection
# ------------------------------------------------------------------------------------------
DESKTOP_APP=""      # macOS: path to Claude.app; Linux: executable
DESKTOP_ICON=""     # macOS: .icns; Linux: icon name or file
MAIN_DATA=""        # main user-data folder of Claude Desktop

find_desktop() {
  if [ "$OS" = "Darwin" ]; then
    local c
    for c in "/Applications/Claude.app" "$HOME/Applications/Claude.app"; do
      [ -d "$c" ] && { DESKTOP_APP="$c"; break; }
    done
    if [ -z "$DESKTOP_APP" ] && command -v mdfind >/dev/null 2>&1; then
      DESKTOP_APP="$(mdfind "kMDItemCFBundleIdentifier == 'com.anthropic.claudefordesktop'" 2>/dev/null | head -n 1 || true)"
    fi
    if [ -n "$DESKTOP_APP" ]; then
      DESKTOP_ICON="$(ls -S "$DESKTOP_APP"/Contents/Resources/*.icns 2>/dev/null | head -n 1 || true)"
      MAIN_DATA="$HOME/Library/Application Support/Claude"
    fi
  else
    local c
    for c in claude-desktop Claude claude-desktop-bin; do
      if command -v "$c" >/dev/null 2>&1; then DESKTOP_APP="$(command -v "$c")"; break; fi
    done
    if [ -z "$DESKTOP_APP" ]; then
      for c in /usr/bin/claude-desktop /opt/Claude/claude-desktop /opt/claude-desktop/claude-desktop "$HOME"/Applications/*[Cc]laude*.AppImage "$HOME"/.local/bin/*[Cc]laude*.AppImage; do
        [ -x "$c" ] && { DESKTOP_APP="$c"; break; }
      done
    fi
    if [ -n "$DESKTOP_APP" ]; then
      MAIN_DATA="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"
      local f
      for f in /usr/share/applications/*laude*.desktop "$HOME"/.local/share/applications/*laude*.desktop; do
        [ -f "$f" ] || continue
        case "$f" in *claude-clone*) continue ;; esac
        DESKTOP_ICON="$(sed -n 's/^Icon=//p' "$f" | head -n 1)"
        [ -n "$DESKTOP_ICON" ] && break
      done
      [ -n "$DESKTOP_ICON" ] || DESKTOP_ICON="claude-desktop"
    fi
  fi
}

CODE_BIN=""
find_code() {
  if command -v claude >/dev/null 2>&1; then CODE_BIN="$(command -v claude)"; return; fi
  local c npmbin=""
  if command -v npm >/dev/null 2>&1; then npmbin="$(npm prefix -g 2>/dev/null)/bin/claude"; fi
  for c in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" "$npmbin" /usr/local/bin/claude /opt/homebrew/bin/claude; do
    [ -n "$c" ] && [ -x "$c" ] && { CODE_BIN="$c"; return; }
  done
}

# ------------------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------------------
# Empty fields are written as "-": read with IFS=tab collapses empty fields and would shift the
# columns that follow
manifest_put() { # name product dir launcher shortcuts [share]
  local tmp; tmp="$(mktemp)"
  awk -F '\t' -v n="$1" -v p="$2" '!($1 == n && $2 == p)' "$MANIFEST" > "$tmp" || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:--}" "${5:--}" "${6:--}" >> "$tmp"
  mv "$tmp" "$MANIFEST"
}

undash() { # after: read -r n p d l s sh
  [ "${l:-}" = - ] && l=""
  [ "${s:-}" = - ] && s=""
  [ "${sh:-}" = - ] && sh=""
  return 0
}

# Links only to a folder that exists: never create folders inside the main profile, a link to a
# folder that is gone shows an empty session list
link_shared() { # link target
  [ -e "$1" ] || [ -L "$1" ] && return 1
  [ -d "$2" ] || return 1
  ln -s "$2" "$1"
}

is_cloud_path() {
  case "$1" in
    */Dropbox|*/Dropbox/*|*/OneDrive*|*/Google\ Drive*|*/Library/Mobile\ Documents/*|*/Library/CloudStorage/*|*/Nextcloud/*|*/ownCloud/*|*/pCloud\ Drive/*) return 0 ;;
  esac
  return 1
}

# Shell code that runs before every start of a Desktop clone: removes links that point to a folder
# Claude no longer uses and links the main profile's folders again where they exist
desktop_heal_code() { # dir share
  cat <<EOF
d="$1"; m="$MAIN_DATA"; share=$2
for x in claude-code-sessions claude-code; do
  if [ -L "\$d/\$x" ] && [ ! -e "\$d/\$x" ]; then rm -f "\$d/\$x"; fi
  if [ "\$share" = 1 ] && [ ! -e "\$d/\$x" ] && [ ! -L "\$d/\$x" ] && [ -d "\$m/\$x" ]; then ln -s "\$m/\$x" "\$d/\$x"; fi
done
EOF
}

write_desktop_launcher() { # name dir share -> sets LAUNCHER
  local name="$1" dir="$2" title="Claude ($1)"
  if [ "$OS" = "Darwin" ]; then
    LAUNCHER="$HOME/Applications/$title.app"
    mkdir -p "$HOME/Applications"
    mac_app_bundle "$LAUNCHER" "# claude-clone $VERSION - Claude Desktop, profile '$name'
$(desktop_heal_code "$dir" "$3")
exec open -n -a \"$DESKTOP_APP\" --args --user-data-dir=\"$dir\"" "$DESKTOP_ICON" "$name"
  else
    mkdir -p "$BIN_DIR"
    LAUNCHER="$BIN_DIR/claude-desktop-$name"
    { printf '#!/usr/bin/env bash\n# claude-clone %s - Claude Desktop, profile '"'"'%s'"'"'\n' "$VERSION" "$name"
      desktop_heal_code "$dir" "$3"
      printf 'exec "%s" --user-data-dir="%s" "$@"\n' "$DESKTOP_APP" "$dir"; } > "$LAUNCHER"
    chmod +x "$LAUNCHER"
  fi
}

mac_app_bundle() { # bundle-path title exec-line icon id
  local b="$1"
  mkdir -p "$b/Contents/MacOS" "$b/Contents/Resources"
  printf '#!/bin/bash\n%s\n' "$2" > "$b/Contents/MacOS/launch"
  chmod +x "$b/Contents/MacOS/launch"
  local iconkey=""
  if [ -n "$3" ] && [ -f "$3" ]; then cp "$3" "$b/Contents/Resources/claude.icns"; iconkey="<key>CFBundleIconFile</key><string>claude</string>"; fi
  cat > "$b/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>launch</string>
<key>CFBundleIdentifier</key><string>io.github.claude-clone.$4</string>
<key>CFBundleName</key><string>$(basename "$b" .app)</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
$iconkey
</dict></plist>
EOF
  touch "$b"
}

linux_desktop_entry() { # file name exec icon terminal(true|false)
  cat > "$1" <<EOF
[Desktop Entry]
Type=Application
Name=$2
Exec=$3
Icon=$4
Terminal=$5
Categories=Utility;Development;
StartupNotify=true
EOF
  chmod +x "$1"
  command -v gio >/dev/null 2>&1 && gio set "$1" metadata::trusted true 2>/dev/null || true
}

# ------------------------------------------------------------------------------------------
# Create clones
# ------------------------------------------------------------------------------------------
desktop_clone() { # name base
  local name="$1" base="$2" dir shortcuts=""
  dir="$base/Claude-$name"
  [ -d "$dir" ] && warn "Profile folder already exists, reusing it: $dir"
  mkdir -p "$dir"
  if [ "$SHARE" = 1 ]; then
    link_shared "$dir/claude-code-sessions" "$MAIN_DATA/claude-code-sessions" && ok "session list shared with the main profile (each account still sees only its own sessions)" || true
    [ -d "$MAIN_DATA/claude-code" ] && { link_shared "$dir/claude-code" "$MAIN_DATA/claude-code" && ok "Claude Code runtime shared (no second download)" || true; }
  fi
  if [ "$COPY" = 1 ]; then
    [ -f "$MAIN_DATA/claude_desktop_config.json" ] && cp "$MAIN_DATA/claude_desktop_config.json" "$dir/" && ok "MCP / desktop settings copied"
    local x
    for x in "Claude Extensions" "Claude Extensions Settings"; do
      [ -d "$MAIN_DATA/$x" ] && [ ! -e "$dir/$x" ] && cp -R "$MAIN_DATA/$x" "$dir/$x" && ok "$x copied"
    done
  fi

  local launcher title="Claude ($name)"
  write_desktop_launcher "$name" "$dir" "$SHARE"
  launcher="$LAUNCHER"
  if [ "$OS" = "Darwin" ]; then
    ok "app: $launcher (repairs broken links in the profile before every start)"
    if [ "$SHORTCUTS" = 1 ]; then
      ln -sfn "$launcher" "$DESKTOP_DIR/$title.app" && shortcuts="$DESKTOP_DIR/$title.app" && ok "shortcut: Desktop ('$title')"
    fi
  else
    ok "command: claude-desktop-$name (repairs broken links in the profile before every start)"
    if [ "$SHORTCUTS" = 1 ]; then
      local apps="$HOME/.local/share/applications"; mkdir -p "$apps"
      linux_desktop_entry "$apps/claude-clone-$name.desktop" "$title" "$launcher" "$DESKTOP_ICON" false
      shortcuts="$apps/claude-clone-$name.desktop"
      if [ -d "$DESKTOP_DIR" ]; then
        linux_desktop_entry "$DESKTOP_DIR/claude-clone-$name.desktop" "$title" "$launcher" "$DESKTOP_ICON" false
        shortcuts="$shortcuts;$DESKTOP_DIR/claude-clone-$name.desktop"
      fi
      ok "shortcuts: app menu and Desktop ('$title')"
    fi
  fi
  manifest_put "$name" desktop "$dir" "$launcher" "$shortcuts" "$SHARE"
}

code_clone() { # name base
  local name="$1" base="$2" dir shortcuts=""
  dir="$base/.claude-$name"
  [ -d "$dir" ] && warn "Config folder already exists, reusing it: $dir"
  mkdir -p "$dir"
  if [ "$COPY" = 1 ] && [ -d "$HOME/.claude" ]; then
    local x
    for x in CLAUDE.md settings.json keybindings.json; do [ -f "$HOME/.claude/$x" ] && cp "$HOME/.claude/$x" "$dir/"; done
    for x in skills agents commands output-styles; do [ -d "$HOME/.claude/$x" ] && [ ! -e "$dir/$x" ] && cp -R "$HOME/.claude/$x" "$dir/$x"; done
    ok "CLAUDE.md, settings, skills, agents and commands copied (never credentials)"
  fi
  mkdir -p "$BIN_DIR"
  local launcher="$BIN_DIR/claude-$name"
  cat > "$launcher" <<EOF
#!/usr/bin/env bash
# claude-clone $VERSION - Claude Code, profile '$name'
export CLAUDE_CONFIG_DIR="$dir"
if command -v claude >/dev/null 2>&1; then exec claude "\$@"; fi
exec "$CODE_BIN" "\$@"
EOF
  chmod +x "$launcher"
  ok "command: claude-$name"
  if [ "$SHORTCUTS" = 1 ]; then
    local title="Claude Code ($name)"
    if [ "$OS" = "Darwin" ]; then
      printf '#!/bin/bash\nexec "%s"\n' "$launcher" > "$DESKTOP_DIR/$title.command"
      chmod +x "$DESKTOP_DIR/$title.command"
      shortcuts="$DESKTOP_DIR/$title.command"
    else
      local apps="$HOME/.local/share/applications"; mkdir -p "$apps"
      local icon="${DESKTOP_ICON:-utilities-terminal}"
      linux_desktop_entry "$apps/claude-clone-code-$name.desktop" "$title" "$launcher" "$icon" true
      shortcuts="$apps/claude-clone-code-$name.desktop"
      if [ -d "$DESKTOP_DIR" ]; then
        linux_desktop_entry "$DESKTOP_DIR/claude-clone-code-$name.desktop" "$title" "$launcher" "$icon" true
        shortcuts="$shortcuts;$DESKTOP_DIR/claude-clone-code-$name.desktop"
      fi
    fi
    ok "shortcut: Desktop ('$title')"
  fi
  manifest_put "$name" code "$dir" "$launcher" "$shortcuts"
}

main_shortcuts() { # do_desktop do_code
  if [ "$1" = 1 ]; then
    if [ "$OS" = "Darwin" ]; then
      ln -sfn "$DESKTOP_APP" "$DESKTOP_DIR/Claude (main).app" && ok "shortcut: Desktop ('Claude (main)')"
    elif [ -d "$DESKTOP_DIR" ]; then
      linux_desktop_entry "$DESKTOP_DIR/claude-clone-main.desktop" "Claude (main)" "$DESKTOP_APP" "$DESKTOP_ICON" false
      ok "shortcut: Desktop ('Claude (main)')"
    fi
  fi
  if [ "$2" = 1 ]; then
    if [ "$OS" = "Darwin" ]; then
      printf '#!/bin/bash\nexec "%s"\n' "$CODE_BIN" > "$DESKTOP_DIR/Claude Code (main).command"
      chmod +x "$DESKTOP_DIR/Claude Code (main).command"
    elif [ -d "$DESKTOP_DIR" ]; then
      linux_desktop_entry "$DESKTOP_DIR/claude-clone-code-main.desktop" "Claude Code (main)" "$CODE_BIN" "${DESKTOP_ICON:-utilities-terminal}" true
    fi
    ok "shortcut: Desktop ('Claude Code (main)')"
  fi
}

# ------------------------------------------------------------------------------------------
# List / remove
# ------------------------------------------------------------------------------------------
clone_status() { # product dir -> status text
  local p="$1" d="$2"
  [ -d "$d" ] || { printf 'missing'; return; }
  if [ "$p" = desktop ]; then
    if command -v pgrep >/dev/null 2>&1 && pgrep -f -- "--user-data-dir=\"?${d}" >/dev/null 2>&1; then printf 'running'; return; fi
    # only the presence of the token cache is checked, never its value
    if [ -f "$d/config.json" ] && grep -q '"oauth:tokenCache' "$d/config.json" 2>/dev/null; then printf 'signed in'; return; fi
    printf 'not signed in'
  else
    if [ -f "$d/.credentials.json" ]; then printf 'signed in'
    elif [ "$OS" = "Darwin" ]; then printf 'see keychain'
    else printf 'not signed in'; fi
  fi
}

show_clones() {
  if [ ! -s "$MANIFEST" ]; then echo "  No clones yet."; return; fi
  printf '  %s%-16s %-8s %-14s %s%s\n' "$C_DIM" NAME APP STATUS FOLDER "$C_0"
  local st col tilde="~"
  while IFS=$'\t' read -r n p d l s sh; do
    st="$(clone_status "$p" "$d")"
    case "$st" in running) col="$C_GR" ;; "signed in") col="$C_CY" ;; missing) col="$C_YE" ;; *) col="$C_DIM" ;; esac
    printf '  %-16s %-8s %s%-14s%s %s\n' "$n" "$p" "$col" "$st" "$C_0" "${d/#$HOME/$tilde}"
  done < "$MANIFEST"
}

# ------------------------------------------------------------------------------------------
# Doctor / repair
# ------------------------------------------------------------------------------------------
doctor() { # 1 = check only, 2 = repair, 3 = check what is left after a repair
  local issues=0 keep line x name target
  find_desktop
  [ -s "$MANIFEST" ] || { echo "  No clones yet."; return 0; }
  keep="$(mktemp)"
  while IFS=$'\t' read -r n p d l s sh; do
    undash
    if [ ! -d "$d" ]; then
      warn "$n ($p): profile folder is missing: $d"; issues=$((issues + 1))
      if [ "$1" = 2 ] && ask_yn "Remove '$n' from the list and delete its launcher and shortcuts?" 1; then
        IFS=';' read -r -a parts <<< "$s"
        for x in "${parts[@]:-}"; do [ -n "$x" ] && rm -rf -- "$x"; done
        [ -n "$l" ] && rm -rf -- "$l"
        ok "removed '$n' from the list"
        continue
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$p" "$d" "${l:--}" "${s:--}" "${sh:--}" >> "$keep"
      continue
    fi
    if [ "$p" = desktop ]; then
      # clones from before 1.3.0 did not record whether they share the session list
      if [ -z "$sh" ]; then if [ -L "$d/claude-code-sessions" ] || [ -L "$d/claude-code" ]; then sh=1; else sh=0; fi; fi
      for x in "$d"/* "$d"/.[!.]*; do
        [ -L "$x" ] || continue
        [ -e "$x" ] && continue
        name="$(basename "$x")"; target="$(readlink "$x" || true)"
        warn "$n: '$name' is a dead link to $target"; issues=$((issues + 1))
        if [ "$1" = 2 ]; then
          rm -f "$x"
          if [ -n "$MAIN_DATA" ] && [ -d "$MAIN_DATA/$name" ]; then ln -s "$MAIN_DATA/$name" "$x"; ok "$n: '$name' linked to $MAIN_DATA/$name"
          else ok "$n: dead link '$name' removed"; fi
        fi
      done
      if [ -n "$l" ] && ! grep -qs "claude-clone $VERSION" "$l" "$l/Contents/MacOS/launch"; then
        warn "$n: launcher is from an older claude-clone (it does not repair the profile before starting)"; issues=$((issues + 1))
        if [ "$1" = 2 ] && [ -n "$DESKTOP_APP" ]; then write_desktop_launcher "$n" "$d" "$sh"; l="$LAUNCHER"; ok "$n: launcher updated"; fi
      fi
    elif [ -n "$l" ] && [ ! -e "$l" ]; then
      warn "$n: command $l is missing - run: claude-clone.sh --product code --names $n"; issues=$((issues + 1))
    fi
    if is_cloud_path "$d"; then warn "$n: profile is in a cloud-synced folder ($d) - sync conflicts can damage its databases"; issues=$((issues + 1)); fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$p" "$d" "${l:--}" "${s:--}" "${sh:--}" >> "$keep"
  done < "$MANIFEST"
  if [ "$1" = 2 ]; then mv "$keep" "$MANIFEST"; else rm -f "$keep"; fi
  if [ "$issues" = 0 ]; then ok "all clones OK"; return 0; fi
  if [ "$1" = 1 ]; then printf '\n  %s point(s) found. Fix them with: claude-clone.sh --repair\n' "$issues"; return 1; fi
  if [ "$1" = 3 ]; then printf '\n  %s point(s) need you (see above).\n' "$issues"; return 1; fi
  step "Checking again"
  doctor 3
}

if [ "$LIST" = 1 ]; then
  show_clones
  exit 0
fi

if [ "$DOCTOR" != 0 ]; then
  if [ "$DOCTOR" = 2 ]; then step "Checking and repairing all clones"; else step "Checking all clones (nothing is changed)"; fi
  if doctor "$DOCTOR"; then exit 0; else exit 1; fi
fi

if [ -n "$LAUNCH" ]; then
  found=0
  while IFS=$'\t' read -r n p d l s sh; do
    [ "$n" = "$LAUNCH" ] || continue
    undash
    found=1
    if [ "$p" = desktop ]; then
      if [ "$OS" = "Darwin" ]; then open "$l"; else "$l" >/dev/null 2>&1 & fi
    else
      "$l" </dev/tty   # Claude Code runs in this terminal (not with the clone list as its input)
    fi
    echo "  started $p clone '$n'"
  done < "$MANIFEST"
  [ "$found" = 1 ] || { echo "No clone named '$LAUNCH'."; exit 1; }
  exit 0
fi

if [ -n "$REMOVE" ]; then
  found=0
  while IFS=$'\t' read -r n p d l s sh; do
    [ "$n" = "$REMOVE" ] || continue
    undash
    found=1
    step "Removing $p clone '$n'"
    IFS=';' read -r -a parts <<< "$s"
    for x in "${parts[@]:-}"; do [ -n "$x" ] && { rm -rf -- "$x"; ok "removed $x"; }; done
    if [ -n "$l" ] && { [ -e "$l" ] || [ -L "$l" ]; }; then rm -rf -- "$l"; ok "removed $l"; fi
    if [ "$PURGE" = 1 ] || ask_yn "Also delete the profile folder $d? This signs the account out on this machine." 0; then
      # rm -rf never follows symlinks, the shared folders of the main profile stay untouched
      rm -rf -- "$d"; ok "deleted $d"
    else
      echo "    kept $d"
    fi
  done < "$MANIFEST"
  [ "$found" = 1 ] || { echo "No clone named '$REMOVE'."; exit 1; }
  tmp="$(mktemp)"; awk -F '\t' -v n="$REMOVE" '$1 != n' "$MANIFEST" > "$tmp" || true; mv "$tmp" "$MANIFEST"
  exit 0
fi

# ------------------------------------------------------------------------------------------
# Interactive flow
# ------------------------------------------------------------------------------------------
printf '\n  %sclaude-clone%s  %sv%s  -  several Claude accounts side by side%s\n' "$C_B" "$C_0" "$C_DIM" "$VERSION" "$C_0"
printf '  %s------------------------------------------------------------%s\n' "$C_DIM" "$C_0"

if [ -s "$MANIFEST" ]; then step "Your clones"; show_clones; fi

step "Looking for Claude on this machine"
find_desktop; find_code
if [ -n "$DESKTOP_APP" ]; then ok "Claude Desktop: $DESKTOP_APP"; else warn "Claude Desktop: not found"; fi
if [ -n "$CODE_BIN" ]; then ok "Claude Code: $CODE_BIN"; else warn "Claude Code: not found"; fi
if [ -z "$DESKTOP_APP" ] && [ -z "$CODE_BIN" ]; then
  printf '\n  Nothing to clone. Install Claude Desktop or Claude Code first.\n'; exit 1
fi

if [ -z "$PRODUCT" ]; then
  if [ -n "$DESKTOP_APP" ] && [ -n "$CODE_BIN" ]; then
    step "What do you want to clone?"
    echo "    1) Claude Desktop      2) Claude Code (CLI)      3) both"
    case "$(ask "Choose 1, 2 or 3" 1)" in 2) PRODUCT=code ;; 3) PRODUCT=both ;; *) PRODUCT=desktop ;; esac
  elif [ -n "$DESKTOP_APP" ]; then PRODUCT=desktop
  else PRODUCT=code; fi
fi
DO_DESKTOP=0; DO_CODE=0
case "$PRODUCT" in desktop|both) [ -n "$DESKTOP_APP" ] && DO_DESKTOP=1 || warn "Claude Desktop is not installed - skipping it" ;; esac
case "$PRODUCT" in code|both) [ -n "$CODE_BIN" ] && DO_CODE=1 || warn "Claude Code is not installed - skipping it" ;; esac
[ "$DO_DESKTOP" = 1 ] || [ "$DO_CODE" = 1 ] || exit 1

LIST_NAMES=()
if [ -n "$NAMES" ]; then
  IFS=',' read -r -a raw <<< "$NAMES"
  for n in "${raw[@]}"; do n="$(safe_name "$n")"; [ -n "$n" ] && LIST_NAMES+=("$n"); done
else
  [ -n "$COUNT" ] || COUNT="$(ask "How many clones?" 1)"
  case "$COUNT" in ''|*[!0-9]*) COUNT=1 ;; esac
  [ "$COUNT" -ge 1 ] || COUNT=1
  i=1
  while [ "$i" -le "$COUNT" ]; do
    n="$(safe_name "$(ask "Name for clone $i" "account$((i + 1))")")"
    [ -n "$n" ] && LIST_NAMES+=("$n")
    i=$((i + 1))
  done
fi
[ "${#LIST_NAMES[@]}" -gt 0 ] || { echo "No valid names."; exit 1; }

DESK_BASE="$BASE_PATH"; CODE_BASE="$BASE_PATH"
if [ -z "$BASE_PATH" ]; then
  [ "$DO_DESKTOP" = 1 ] && DESK_BASE="$(ask "Where to store Claude Desktop profiles?" "$(dirname "$MAIN_DATA")")"
  [ "$DO_CODE" = 1 ] && CODE_BASE="$(ask "Where to store Claude Code profiles?" "$HOME")"
fi
DESK_BASE="${DESK_BASE/#\~/$HOME}"; CODE_BASE="${CODE_BASE/#\~/$HOME}"
for b in "$DESK_BASE" "$CODE_BASE"; do
  [ -n "$b" ] && is_cloud_path "$b" || continue
  warn "$b is in a cloud-synced folder. Claude writes its databases there all the time; the sync client can damage them."
  ask_yn "Use it anyway?" 0 || { echo "  Cancelled. Pick a local folder."; exit 1; }
done

if [ "$YES" != 1 ]; then
  if [ "$DO_DESKTOP" = 1 ] && [ "$SHARE" = 1 ]; then
    ask_yn "Share the Desktop session list with the main profile (each account still sees only its own sessions)?" 1 || SHARE=0
  fi
  [ "$COPY" = 1 ] && { ask_yn "Copy your settings (MCP servers, CLAUDE.md, skills; never login data)?" 1 || COPY=0; }
  [ "$SHORTCUTS" = 1 ] && { ask_yn "Create shortcuts with the Claude icon?" 1 || SHORTCUTS=0; }
  [ "$SHORTCUTS" = 1 ] && [ "$MAIN_SHORTCUT" = 1 ] && { ask_yn "Also create a 'main' shortcut for your current account?" 1 || MAIN_SHORTCUT=0; }
fi

step "Plan"
for n in "${LIST_NAMES[@]}"; do
  [ "$DO_DESKTOP" = 1 ] && echo "    Claude Desktop  '$n'  ->  $DESK_BASE/Claude-$n"
  [ "$DO_CODE" = 1 ] && echo "    Claude Code     '$n'  ->  $CODE_BASE/.claude-$n"
done
ask_yn "Go ahead?" 1 || { echo "  Cancelled."; exit 0; }

for n in "${LIST_NAMES[@]}"; do
  if [ "$DO_DESKTOP" = 1 ]; then step "Claude Desktop clone '$n'"; desktop_clone "$n" "$DESK_BASE"; fi
  if [ "$DO_CODE" = 1 ]; then step "Claude Code clone '$n'"; code_clone "$n" "$CODE_BASE"; fi
done

if [ "$SHORTCUTS" = 1 ] && [ "$MAIN_SHORTCUT" = 1 ]; then
  step "Main account"
  main_shortcuts "$DO_DESKTOP" "$DO_CODE"
fi

case ":$PATH:" in *":$BIN_DIR:"*) ;; *) warn "$BIN_DIR is not on your PATH - add it to use the claude-<name> commands" ;; esac

printf '\n  %sDone.%s\n' "$C_GR" "$C_0"
[ "$DO_DESKTOP" = 1 ] && echo "  Open a \"Claude (<name>)\" launcher and sign in with that account. Your main app stays as it is."
[ "$DO_CODE" = 1 ] && echo "  Run claude-<name> in a terminal and type /login once."
echo "  List clones:   claude-clone.sh --list"
echo "  Remove one:    claude-clone.sh --remove <name>"
echo
