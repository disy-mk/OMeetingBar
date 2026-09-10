#!/usr/bin/env bash

# Idempotent installer for OMeetingBar, an Omarchy shell plugin.
# Safe to re-run: it never overwrites an existing config and never calls sudo.
# Package installation is printed for the user to run, not attempted.

set -euo pipefail

PLUGIN_ID="io.github.disy-mk.omeetingbar"
REQUIRED_PACKAGES=(gnome-online-accounts gnome-online-accounts-gtk evolution-data-server)

# The shell hardcodes ~/.config/omarchy/plugins (PluginRegistry.qml pluginsDir),
# so this path is HOME-based on purpose and ignores XDG_CONFIG_HOME.
OMARCHY_CONFIG_DIR="$HOME/.config/omarchy"
PLUGINS_DIR="$OMARCHY_CONFIG_DIR/plugins"
CONFIG_FILE="$OMARCHY_CONFIG_DIR/omeetingbar.json"
# Pre-release names of the config and the wrapper; migrated, never overwritten.
LEGACY_CONFIG_FILE="$OMARCHY_CONFIG_DIR/meetings.json"
LEGACY_WRAPPER="$HOME/.local/bin/meetings-fetch"

DRY_RUN=0
UNINSTALL=0

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*" >&2; }
fail() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<USAGE
Usage: ./install.sh [--dry-run] [--uninstall]

Installs and registers the $PLUGIN_ID plugin in the running Omarchy shell.

  --uninstall Reverse what this script created: the PATH wrapper, the runtime
              cache and the bar entry. Leaves your config, the packages and
              the Google account alone and says so.
  --dry-run   Print every change without making one.
  -h, --help  This text.

The script never calls sudo. Missing Arch packages are only reported, with the
exact pacman command to run by hand.
USAGE
}

while (( $# > 0 )); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) fail "unknown option: $1 (see --help)" ;;
  esac
  shift
done

(( DRY_RUN )) && say "DRY RUN — nothing will be changed."

# ------------------------------------------------------------------- location

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

[[ ${SCRIPT_DIR##*/} == "$PLUGIN_ID" ]] ||
  fail "this script must live in a directory named $PLUGIN_ID, not ${SCRIPT_DIR##*/}"

[[ -d $PLUGINS_DIR ]] || fail "plugin directory not found: $PLUGINS_DIR"
PLUGINS_DIR_REAL=$(cd -- "$PLUGINS_DIR" && pwd -P)
[[ ${SCRIPT_DIR%/*} == "$PLUGINS_DIR_REAL" ]] ||
  fail "expected the plugin under $PLUGINS_DIR_REAL, found it in ${SCRIPT_DIR%/*}"

step "Plugin directory"
say "  $SCRIPT_DIR"

# ------------------------------------------------------------------ tooling

for tool in omarchy omarchy-shell jq pacman; do
  command -v "$tool" >/dev/null 2>&1 || fail "required command not found: $tool"
done

# ---------------------------------------------------------------- uninstall

if (( UNINSTALL )); then
  step "Uninstall"
  runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$UID}/omeetingbar"
  for w in "$HOME/.local/bin/omeetingbar-fetch" "$LEGACY_WRAPPER"; do
    # Only a wrapper that points at THIS plugin is ours to remove.
    if [[ -f $w ]] && grep -q "omarchy/plugins/" "$w" && grep -q "omeetingbar-fetch\|meetings-fetch" "$w"; then
      if (( DRY_RUN )); then say "  would remove $w"; else rm -f -- "$w"; say "  removed $w"; fi
    fi
  done
  if [[ -d $runtime_dir ]]; then
    if (( DRY_RUN )); then say "  would remove $runtime_dir"; else rm -rf -- "$runtime_dir"; say "  removed $runtime_dir"; fi
  fi
  if omarchy-shell shell ping >/dev/null 2>&1; then
    if (( DRY_RUN )); then say "  would run: omarchy plugin disable $PLUGIN_ID"
    elif omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1; then say "  bar entry removed (omarchy plugin disable)"
    else warn "could not disable the plugin over IPC — remove the bar entry with: omarchy plugin disable $PLUGIN_ID"; fi
  else
    warn "omarchy-shell is not running; remove the bar entry later with: omarchy plugin disable $PLUGIN_ID"
  fi
  say ""
  say "  Left in place on purpose:"
  say "    $CONFIG_FILE   (your settings)"
  say "    the Arch packages   (sudo pacman -Rs evolution-data-server gnome-online-accounts gnome-online-accounts-gtk)"
  say "    the Google account  (remove it in gnome-online-accounts-gtk)"
  say "  To delete the plugin files themselves: omarchy plugin remove $PLUGIN_ID"
  exit 0
fi

# --------------------------------------------------------------- validation

# Read-only, and the same checks the running shell applies, so a manifest the
# shell would reject never reaches the registration steps below.
step "Validating the manifest"
if validate_output=$(omarchy plugin validate "$SCRIPT_DIR" 2>&1); then
  say "  manifest.json and all entry points are valid"
else
  [[ -n $validate_output ]] && printf '%s\n' "$validate_output" >&2
  fail "omarchy plugin validate failed — fix the manifest before installing"
fi

# ------------------------------------------------------------------- config

step "User configuration"
jq -e . "$SCRIPT_DIR/config.example.json" >/dev/null 2>&1 ||
  fail "config.example.json is not valid JSON"

if [[ ! -e $CONFIG_FILE && -e $LEGACY_CONFIG_FILE ]]; then
  # Pre-release installs called the file meetings.json. Carry the settings over
  # rather than silently starting from defaults.
  if (( DRY_RUN )); then say "  would move $LEGACY_CONFIG_FILE -> $CONFIG_FILE"
  else mv -- "$LEGACY_CONFIG_FILE" "$CONFIG_FILE"; say "  moved $LEGACY_CONFIG_FILE -> $CONFIG_FILE"; fi
fi

if [[ -e $CONFIG_FILE ]]; then
  say "  $CONFIG_FILE exists — left untouched"
  jq -e . "$CONFIG_FILE" >/dev/null 2>&1 ||
    warn "$CONFIG_FILE is not valid JSON; the plugin will fall back to its built-in defaults"
elif (( DRY_RUN )); then
  say "  would create $CONFIG_FILE from config.example.json (mode 0600)"
else
  say "  creating $CONFIG_FILE from config.example.json (mode 0600)"
  install -Dm600 "$SCRIPT_DIR/config.example.json" "$CONFIG_FILE"
fi

# ----------------------------------------------------------------- packages

step "Arch packages for the eds backend"
missing_packages=()
demo_advised=0
for package in "${REQUIRED_PACKAGES[@]}"; do
  if pacman -Q -- "$package" >/dev/null 2>&1; then
    say "  present: $package"
  else
    say "  MISSING: $package"
    missing_packages+=("$package")
  fi
done

if (( ${#missing_packages[@]} )); then
  say ""
  say "  Install them yourself — this script never runs sudo:"
  say ""
  say "      sudo pacman -S --needed ${missing_packages[*]}"
  say ""
  # config.example.json ships backend "eds" as the intended steady state, so a
  # fresh install without these packages needs to be told to start on demo.
  say "  Until they are installed, run the plugin on the demo backend:"
  say ""
  say "      jq '.backend = \"demo\"' $CONFIG_FILE > $CONFIG_FILE.tmp \\"
  say "        && mv $CONFIG_FILE.tmp $CONFIG_FILE"
  demo_advised=1
fi

# -------------------------------------------------------------- path wrapper

# The fetcher lives inside the plugin dir, which nobody wants to type. A wrapper
# on PATH makes `omeetingbar-fetch --diagnose` work from anywhere. Not named
# omarchy-* on purpose: the omarchy CLI resolves `omarchy <group> <action>` to
# omarchy-<group>-<action> on PATH, and this is not a first-party command.
step "Wrapper auf PATH"
WRAPPER="$HOME/.local/bin/omeetingbar-fetch"
wrapper_body="#!/usr/bin/env bash
# Thin wrapper for the $PLUGIN_ID event fetcher, so it is reachable from any
# directory. Deliberately not named omarchy-*: the omarchy CLI resolves
# \`omarchy <group> <action>\` to omarchy-<group>-<action> on PATH, and this is
# not a first-party command. Written by install.sh — edit it there.
set -euo pipefail
exec /usr/bin/python3 \"\$HOME/.config/omarchy/plugins/$PLUGIN_ID/bin/omeetingbar-fetch\" \"\$@\"
"
# Both sides go through command substitution so the trailing newline is stripped
# from each: comparing against $wrapper_body directly never matches.
if [[ -e $WRAPPER ]] && [[ $(cat "$WRAPPER" 2>/dev/null) == "$(printf '%s' "$wrapper_body")" ]]; then
  say "  $WRAPPER ist aktuell"
elif (( DRY_RUN )); then
  say "  would write $WRAPPER (mode 0755)"
else
  say "  schreibe $WRAPPER"
  install -Dm755 /dev/stdin "$WRAPPER" <<<"$wrapper_body"
fi
if [[ -f $LEGACY_WRAPPER ]] && grep -q "omarchy/plugins/" "$LEGACY_WRAPPER" && grep -q "meetings-fetch" "$LEGACY_WRAPPER"; then
  if (( DRY_RUN )); then say "  would remove the pre-release wrapper $LEGACY_WRAPPER"
  else rm -f -- "$LEGACY_WRAPPER"; say "  removed the pre-release wrapper $LEGACY_WRAPPER"; fi
fi
case ":$PATH:" in
  *":$HOME/.local/bin:"*) : ;;
  *) warn "$HOME/.local/bin liegt nicht auf dem PATH — der Wrapper ist dann nicht aufrufbar." ;;
esac

# ------------------------------------------------------------- registration

# Enabling a bar-widget plugin inserts it into bar.layout.<defaultSection>, and
# the shell treats "id present in shell.json" as enabled for every kind the
# manifest declares. So one enable also mounts the service and the overlay, and
# placing the widget is not a separate step. `omarchy bar put` stays below as a
# guarded fallback because it is the one verb that leaves a placed widget alone.

# absent | disabled | enabled | unknown. For a bar-widget plugin listPlugins
# reports enabled as inBar(), so "enabled" here means "sitting in the bar".
plugin_state() {
  local listing state
  listing=$(omarchy plugin list --json 2>/dev/null) || {
    printf 'unknown\n'
    return 0
  }
  state=$(jq -r --arg id "$PLUGIN_ID" '
    (map(select(.id == $id)) | first) as $p
    | if $p == null then "absent"
      elif $p.enabled then "enabled"
      else "disabled" end
  ' <<<"$listing" 2>/dev/null) || state=""
  printf '%s\n' "${state:-unknown}"
}

step "Registering the plugin with the running shell"
if ! omarchy-shell shell ping >/dev/null 2>&1; then
  warn "omarchy-shell is not running or not ready — skipping registration."
  say "  Start a shell (or run omarchy-restart-shell) and re-run ./install.sh."
elif (( DRY_RUN )); then
  say "  current state: $(plugin_state)"
  say "  would run: omarchy-shell shell rescanPlugins"
  say "  would run: omarchy plugin enable $PLUGIN_ID   (only while not enabled)"
  say "  would run: omarchy bar put $PLUGIN_ID         (only while not on the bar)"
  say "  would run: omarchy plugin list --json           (verification)"
else
  say "  rescanning plugin directories"
  omarchy-shell shell rescanPlugins

  # The rescan is an async subprocess, so the id can lag the IPC reply.
  for _ in {1..50}; do
    [[ $(plugin_state) == "absent" ]] || break
    sleep 0.2
  done

  state=$(plugin_state)
  case "$state" in
    absent)
      fail "the shell still does not know $PLUGIN_ID — check journalctl --user -t omarchy-shell"
      ;;
    unknown)
      fail "could not read the plugin list from the shell — check journalctl --user -t omarchy-shell"
      ;;
    enabled)
      say "  already enabled and on the bar — nothing to do"
      ;;
    disabled)
      say "  enabling $PLUGIN_ID"
      omarchy plugin enable "$PLUGIN_ID"
      ;;
  esac

  if [[ $(plugin_state) != "enabled" ]]; then
    say "  putting the widget on the bar"
    omarchy bar put "$PLUGIN_ID"
  fi

  step "Verifying"
  omarchy plugin list --json |
    jq -r --arg id "$PLUGIN_ID" --arg sep ", " '
      map(select(.id == $id))
      | if length == 0 then "  not registered"
        else .[0] as $p
          | "  id:      " + $p.id,
            "  name:    " + ($p.name // ""),
            "  kinds:   " + ($p.kinds | join($sep)),
            "  enabled: " + ($p.enabled | tostring)
        end
    '
  [[ $(plugin_state) == "enabled" ]] ||
    warn "the widget is not on the bar; run: omarchy bar put $PLUGIN_ID"
fi

# ---------------------------------------------------------------- next steps

# The steps are built, not pasted, so they can never contradict the package
# block above: "switch to eds" is only printed when the config actually sits on
# demo — because that block just advised it, or because an existing
# omeetingbar.json says so. On a fresh install (config.example.json ships "eds")
# that jq line would be a no-op the user cannot tell apart from a real change.
config_backend="eds"
if [[ -e $CONFIG_FILE ]]; then
  config_backend=$(jq -r '
    if type == "object" and (.backend | type) == "string" then .backend else "eds" end
  ' "$CONFIG_FILE" 2>/dev/null) || config_backend="eds"
  [[ -n $config_backend ]] || config_backend="eds"
fi

step_number=0
next_step() {
  step_number=$((step_number + 1))
  printf '\n  %d. %s\n' "$step_number" "$*"
}

printf '\n==> Nächste Schritte\n'

if (( ${#missing_packages[@]} )); then
  next_step "Fehlende Pakete installieren:"
  say "       sudo pacman -S --needed ${missing_packages[*]}"
fi

next_step "Google-Workspace-Konto verbinden:"
say "       gnome-online-accounts-gtk"
say '     Google auswählen, anmelden, "Kalender" einschalten.'

if (( demo_advised )) || [[ $config_backend == "demo" ]]; then
  next_step "Backend von demo auf eds umstellen (erst wenn die Schritte oben erledigt sind):"
  say "       jq '.backend = \"eds\"' $CONFIG_FILE > $CONFIG_FILE.tmp \\"
  say "         && mv $CONFIG_FILE.tmp $CONFIG_FILE"
fi

next_step "Testen:"
say "       omarchy-shell omeetingbar test    # Vollbild-Alarm sofort, ohne Kalender"
say "       omarchy-shell omeetingbar status  # Backend-Status, Cache-Alter, nächster Termin"
say "       omeetingbar-fetch --diagnose      # Pakete, Typelibs, GOA-Konten, Kalender"
printf '\n'
