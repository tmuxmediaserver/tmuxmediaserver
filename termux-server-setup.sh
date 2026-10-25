#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  termux-server-setup.sh
#  Installs a small self-hosting stack in Termux and creates quick commands:
#
#    * Jellyfin        (optional; native Termux packages, no proot:
#                       pkg install jellyfin-server aspnetcore-runtime-10.0)
#    * File Browser    (gtsteffaniak/filebrowser "Quantum")  and/or
#      copyparty       (9001/copyparty)                      -- you choose
#    * Syncthing       (optional)
#    * cloudflared or ngrok tunnel (optional) -- you choose; both run natively
#
#  If an SD card is present, everything big and growing is kept on it instead
#  of the phone's internal storage: Jellyfin's database/metadata/cache/
#  transcodes/temp files, File Browser's thumbnail cache and copyparty's
#  index/thumbnails. Download caches are cleaned up after each install so they
#  don't eat internal space. Program files (Jellyfin, .NET, binaries) must stay
#  on internal storage: Android doesn't allow running programs from an SD card.
#
#  Before anything else it requests phone storage access and offers to
#  install OpenSSH and set the Termux password.
#
#  Usage:   bash termux-server-setup.sh
#  Safe to re-run: existing pieces are detected / refreshed.
# =============================================================================

set -u

# ---------- sanity checks ----------------------------------------------------
if [ -z "${PREFIX:-}" ] || [ "${PREFIX#*com.termux}" = "$PREFIX" ]; then
  echo "This script must be run inside Termux on Android." >&2
  exit 1
fi

BIN="$PREFIX/bin"
HOME_DIR="$HOME"
README="$HOME_DIR/servers-readme.txt"
BASHRC="$HOME_DIR/.bashrc"
PHONE_STORAGE="/storage/emulated/0"

# ---------- pretty output ----------------------------------------------------
# Colours are used only on a real terminal (and never if NO_COLOR is set).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_B=$'\033[1;34m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'
  C_C=$'\033[1;36m'; C_D=$'\033[2m';    C_BOLD=$'\033[1m'; C_0=$'\033[0m'
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_C=""; C_D=""; C_BOLD=""; C_0=""
fi
export DEBIAN_FRONTEND=noninteractive
SPIN_PID=""
_cursor_on() { [ -t 1 ] && printf '\033[?25h'; return 0; }
trap '_cursor_on' EXIT
trap '[ -n "$SPIN_PID" ] && kill "$SPIN_PID" 2>/dev/null; _cursor_on; printf "\n  Interrupted.\n"; exit 130' INT TERM

step() {
  local t="$*" pad
  pad=$(( 56 - ${#t} )); [ "$pad" -lt 3 ] && pad=3
  printf '\n%s━━%s %s%s%s %s%s%s\n' "$C_B" "$C_0" "$C_BOLD" "$t" "$C_0" \
    "$C_B" "$(printf '━%.0s' $(seq 1 "$pad"))" "$C_0"
}
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s⚠%s %s\n' "$C_Y" "$C_0" "$*"; }
err()  { printf '  %s✘%s %s\n' "$C_R" "$C_0" "$*"; }
info() { printf '  %s•%s %s\n' "$C_C" "$C_0" "$*"; }
menu_item() { printf '    %s%s%s  %s %s%s%s\n' "$C_C" "$1" "$C_0" "$2" "$C_D" "${3:-}" "$C_0"; }

print_banner() {
  printf '\n%s' "$C_C"
  echo ' ╭──────────────────────────────────────────────────╮'
  echo ' │                                                  │'
  printf ' │   %s%-46s%s%s │\n' "$C_BOLD" "Termux Server Setup" "$C_0" "$C_C"
  printf ' │   %s%-46s%s%s │\n' "$C_D" "Jellyfin | File manager | Sync | Tunnel" "$C_0" "$C_C"
  echo ' │                                                  │'
  echo ' ╰──────────────────────────────────────────────────╯'
  printf '%s' "$C_0"
}

# run_quiet "message" command...   -> hides the command's output behind a spinner
# and shows the last lines of its log only if it fails.
run_quiet() {
  local msg="$1" log rc i=0 frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  shift
  mkdir -p "${TMPDIR:-$PREFIX/tmp}" 2>/dev/null
  log="$(mktemp "${TMPDIR:-$PREFIX/tmp}/tss.XXXXXX" 2>/dev/null)" || log="$HOME_DIR/.tss-run.log"
  "$@" >"$log" 2>&1 </dev/null &
  SPIN_PID=$!
  if [ -t 1 ]; then
    printf '\033[?25l'
    while kill -0 "$SPIN_PID" 2>/dev/null; do
      printf '\r  %s%s%s %s%s%s' "$C_C" "${frames:i:1}" "$C_0" "$C_D" "$msg" "$C_0"
      i=$(( (i + 1) % ${#frames} ))
      sleep 0.12
    done
    printf '\r\033[K\033[?25h'
  fi
  wait "$SPIN_PID"; rc=$?
  SPIN_PID=""
  if [ "$rc" -eq 0 ]; then
    ok "$msg"
  else
    err "$msg ${C_R}(failed, exit $rc)${C_0}"
    printf '%s' "$C_D"; tail -n 12 "$log" | sed 's/^/      /'; printf '%s' "$C_0"
  fi
  rm -f "$log"
  return "$rc"
}

# read from the terminal even when the script is piped (curl ... | bash)
ask_yn() {
  local def="${2:-n}" hint reply
  [ "$def" = y ] && hint="Y/n" || hint="y/N"
  while true; do
    read -rp "  ${C_Y}?${C_0} $1 ${C_D}[$hint]${C_0} " reply </dev/tty || reply=""
    reply="${reply:-$def}"
    case "${reply,,}" in y|yes) return 0 ;; n|no) return 1 ;; esac
  done
}

# Colourise the saved notes when printing them to the screen.
show_readme() {
  awk -v d="$C_D" -v b="$C_BOLD" -v c="$C_C" -v z="$C_0" '
    /^[=-][=-][=-][=-][=-]/            { print d $0 z; next }
    /^ [A-Z][A-Z .]+ +start:/          { print b c $0 z; next }
    /^ [A-Z][A-Z ]+$/                  { print b c $0 z; next }
    /^  HOW TO USE/                    { print b $0 z; next }
    { print }' "$README"
}

# Print the real path of the SD card's Termux folder, if there is one.
# (termux-setup-storage creates ~/storage/external-N for each removable card.)
_sd_scan() {
  local l d
  for l in "$HOME_DIR"/storage/external-*; do
    [ -d "$l" ] || continue
    d="$(readlink -f "$l" 2>/dev/null)" || continue
    case "$d" in /storage/emulated/*|"") continue ;; esac
    [ -w "$d" ] && { echo "$d"; return 0; }
  done
  # fallback: look straight in /storage for a removable volume (UUID-style name)
  for l in /storage/*-*; do
    d="$l/Android/data/com.termux/files"
    [ -d "$d" ] && [ -w "$d" ] && { echo "$d"; return 0; }
  done
  return 1
}
# Adopted ("internal") SD card: Android merges it into /storage/emulated/0, so it
# looks like phone storage. If that volume has far more free space than Termux's
# own home, treat its Termux folder as the big-storage location.
_adopted_scan() {
  local d="$PHONE_STORAGE/Android/data/com.termux/files" big small
  [ -d "$PHONE_STORAGE" ] || return 1
  mkdir -p "$d" 2>/dev/null; [ -w "$d" ] || return 1
  big="$(df -Pk "$d" 2>/dev/null | awk 'NR==2{print $4}')"
  small="$(df -Pk "$HOME_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
  [ -n "${big:-}" ] && [ -n "${small:-}" ] && [ "$big" -gt $((small * 2)) ] || return 1
  echo "$d"
}
find_sd() {
  _sd_scan && return 0
  _adopted_scan && return 0
  # A card inserted after the first termux-setup-storage has no link yet:
  # run it again once to refresh the links, then look again.
  if ls -d /storage/*-* >/dev/null 2>&1; then
    termux-setup-storage >/dev/null 2>&1
    sleep 3
    _sd_scan && return 0
  fi
  return 1
}

# Can SQLite (what Jellyfin uses) lock and write on this folder? SD card
# filesystems on some phones can't, which makes Jellyfin fail with
# "database is locked" errors.
sqlite_ok() {
  python3 - "$1" <<'PYEOF' 2>/dev/null
import sqlite3, sys, os
d = os.path.join(sys.argv[1], ".sqlite-test")
os.makedirs(d, exist_ok=True)
db = os.path.join(d, "t.db")
try:
    c = sqlite3.connect(db)
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("CREATE TABLE IF NOT EXISTS t(x)")
    c.execute("INSERT INTO t VALUES (1)")
    c.commit()
    c.close()
finally:
    for f in os.listdir(d):
        try: os.remove(os.path.join(d, f))
        except OSError: pass
    try: os.rmdir(d)
    except OSError: pass
PYEOF
}

# Download caches only waste internal space once things are installed.
clean_cache() { apt-get clean >/dev/null 2>&1; rm -rf "$HOME_DIR/.cache/pip" 2>/dev/null; }

random_pw() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 14; }

# =============================================================================
#  0. Phone storage access + optional SSH (runs before everything else)
# =============================================================================
print_banner
step "Requesting access to phone storage (tap ALLOW on the popup)"
if [ -d "$HOME_DIR/storage" ] && [ -r "$PHONE_STORAGE" ]; then
  ok "Storage already set up"
else
  termux-setup-storage
  for _ in $(seq 1 30); do
    [ -d "$HOME_DIR/storage" ] && [ -r "$PHONE_STORAGE" ] && break
    sleep 1
  done
  if [ -r "$PHONE_STORAGE" ]; then
    ok "Storage access granted"
  else
    warn "Storage access not confirmed. Services that use $PHONE_STORAGE won't see your files until you allow it."
  fi
fi

SSH_OK=0
echo
if ask_yn "Install OpenSSH and set a Termux password (lets you log in from a computer)?" y; then
  run_quiet "Updating package lists" pkg update -y
  if run_quiet "Installing OpenSSH" pkg install -y openssh; then
    echo
    info "Set the Termux login password now (you will be asked to type it twice):"
    if passwd </dev/tty; then
      SSH_OK=1
      ok "OpenSSH installed and password set"
    else
      warn "Password not set. Run 'passwd' later, then start SSH with 'ssh-on'."
      SSH_OK=1
    fi
  else
    err "OpenSSH install failed. Continuing without it."
  fi
fi

# =============================================================================
#  1. Ask all the questions up front, then run unattended
# =============================================================================

USE_SD=0; SD_DIR=""
if SD_DIR="$(find_sd)"; then
  step "SD card"
  ok "SD card found: $SD_DIR"
  info "Free space: $(df -h "$SD_DIR" 2>/dev/null | awk 'NR==2{print $4}') on the card, $(df -h "$HOME_DIR" 2>/dev/null | awk 'NR==2{print $4}') on internal storage"
  info "Android can't run programs from an SD card, so program files stay on"
  info "internal storage. All data, caches and temp files go on the card."
  ask_yn "Put all data (Jellyfin library/metadata/cache, thumbnails, temp files) on the SD card?" y && USE_SD=1
else
  SD_DIR=""
  step "SD card"
  info "No SD card found (or it isn't accessible to Termux); data will use internal storage."
  info "If a card is inserted: run 'termux-setup-storage', allow it, then re-run this script."
fi

step "What would you like to install?"
WANT_JF=0; ask_yn "Install Jellyfin (media server)?" n && WANT_JF=1

echo
printf '  %sFile manager%s %s(web UI for browsing/uploading files on your phone)%s\n' "$C_BOLD" "$C_0" "$C_D" "$C_0"
menu_item 1 "File Browser Quantum" "(gtsteffaniak/filebrowser)"
menu_item 2 "copyparty" "(9001/copyparty)"
menu_item 3 "Both"
menu_item 4 "Neither"
FM_CHOICE=""
while [[ ! "$FM_CHOICE" =~ ^[1-4]$ ]]; do read -rp "  ${C_Y}?${C_0} Choose ${C_D}[1-4]${C_0}: " FM_CHOICE </dev/tty || FM_CHOICE=4; done
WANT_FB=0; WANT_CP=0
case "$FM_CHOICE" in 1) WANT_FB=1 ;; 2) WANT_CP=1 ;; 3) WANT_FB=1; WANT_CP=1 ;; esac

echo
WANT_ST=0; ask_yn "Install Syncthing (continuous file sync)?" n && WANT_ST=1

echo
printf '  %sTunnel%s %s(expose a local service to the internet with a public URL)%s\n' "$C_BOLD" "$C_0" "$C_D" "$C_0"
menu_item 1 "cloudflared" "(Cloudflare quick tunnel, no account needed)"
menu_item 2 "ngrok" "(free account + authtoken required)"
menu_item 3 "Neither"
TN_CHOICE=""
while [[ ! "$TN_CHOICE" =~ ^[1-3]$ ]]; do read -rp "  ${C_Y}?${C_0} Choose ${C_D}[1-3]${C_0}: " TN_CHOICE </dev/tty || TN_CHOICE=3; done
NGROK_TOKEN=""
if [ "$TN_CHOICE" = 2 ]; then
  read -rp "  ${C_Y}?${C_0} Paste your ngrok authtoken ${C_D}(Enter to add it later)${C_0}: " NGROK_TOKEN </dev/tty || NGROK_TOKEN=""
fi

step "Ready to install"
PLAN=()
[ $WANT_JF -eq 1 ] && PLAN+=("Jellyfin")
[ $WANT_FB -eq 1 ] && PLAN+=("File Browser Quantum")
[ $WANT_CP -eq 1 ] && PLAN+=("copyparty")
[ $WANT_ST -eq 1 ] && PLAN+=("Syncthing")
[ "$TN_CHOICE" = 1 ] && PLAN+=("cloudflared")
[ "$TN_CHOICE" = 2 ] && PLAN+=("ngrok")
if [ ${#PLAN[@]} -eq 0 ]; then
  info "Nothing selected (only base packages and helper commands will be set up)"
else
  for _item in "${PLAN[@]}"; do ok "$_item"; done
fi
[ $SSH_OK -eq 1 ] && info "OpenSSH already installed"
if [ $USE_SD -eq 1 ]; then info "Data location: SD card ($SD_DIR)"; else info "Data location: internal storage"; fi
echo
ask_yn "Continue?" y || { echo "Aborted."; exit 0; }

# =============================================================================
#  2. Base packages + storage access
# =============================================================================
step "Updating Termux and installing base packages"
export DEBIAN_FRONTEND=noninteractive
run_quiet "Updating package lists" pkg update -y
run_quiet "Upgrading installed packages" apt-get -y -o Dpkg::Options::="--force-confold" upgrade
run_quiet "Installing base packages (curl, git, tmux, ffmpeg, python, ...)" \
  pkg install -y curl wget git tmux nano openssh python ffmpeg jq tar unzip \
  || { err "Base package install failed. Check your network / run 'termux-change-repo'."; exit 1; }
clean_cache

# ---------- where does data go? ----------------------------------------------
JF_ROOT="$HOME_DIR/.jellyfin"      # Jellyfin data/config/cache/log/tmp
FB_CACHE_ROOT=""                   # File Browser thumbnail cache ("" = internal)
CP_HIST=""                         # copyparty index/thumbnails ("" = inside the shared folder)
if [ $USE_SD -eq 1 ]; then
  step "Checking the SD card"
  SD_ROOT="$SD_DIR/termux-server"
  if mkdir -p "$SD_ROOT" && sqlite_ok "$SD_ROOT"; then
    JF_ROOT="$SD_ROOT/jellyfin"
    FB_CACHE_ROOT="$SD_ROOT/filebrowser"
    CP_HIST="$SD_ROOT/copyparty"
    ok "SD card is usable: data will be stored in $SD_ROOT"
  else
    warn "The SD card could not run a database test (file locking not supported there)."
    warn "Falling back to internal storage for data."
    USE_SD=0
  fi
fi
INT_FREE_MB="$(df -Pk "$HOME_DIR" 2>/dev/null | awk 'NR==2{print int($4/1024)}')"
if [ -n "${INT_FREE_MB:-}" ] && [ "$INT_FREE_MB" -lt 1500 ]; then
  warn "Only ${INT_FREE_MB} MiB free on internal storage. The program files themselves"
  warn "(Jellyfin plus .NET need several hundred MiB) stay there; the install may fail if it runs out."
fi

clean_cache

# ---------- helper commands used by every service ----------------------------
step "Creating helper commands"

# svc-run <name> <command...>  -> runs a service in a detached tmux session
cat > "$BIN/svc-run" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Run a service in a background tmux session and keep the CPU awake.
name="$1"; shift
termux-wake-lock 2>/dev/null
if tmux has-session -t "$name" 2>/dev/null; then
  echo "[$name] is already running."
  echo "  view output : tmux attach -t $name    (detach: Ctrl+b then d)"
  echo "  stop it     : stop-servers $name"
  exit 0
fi
tmux new-session -d -s "$name" bash -c '"$@"; echo; read -rp "[process exited - press Enter to close] "' _ "$@"
echo "[$name] started in the background."
echo "  view output : tmux attach -t $name    (detach: Ctrl+b then d)"
echo "  stop it     : stop-servers $name"
EOF

# stop-servers [name...]
cat > "$BIN/stop-servers" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Stop one or all background services started with the start-* commands.
if [ $# -gt 0 ]; then names=("$@"); else names=(jellyfin filebrowser copyparty syncthing); fi
for n in "${names[@]}"; do
  if tmux has-session -t "$n" 2>/dev/null; then
    tmux kill-session -t "$n" && echo "stopped $n"
  fi
done
# release the wake lock when nothing is left running
tmux ls >/dev/null 2>&1 || termux-wake-unlock 2>/dev/null
exit 0
EOF
chmod +x "$BIN/svc-run" "$BIN/stop-servers"
ok "svc-run, stop-servers"

ALIASES=""   # collected "alias x='y'" lines
add_alias() { ALIASES+="alias $1='$2'"$'\n'; }
add_alias servers-help "cat $README"
add_alias stop-all "stop-servers"
add_alias ssh-on "sshd"
add_alias ssh-off "pkill sshd"

# =============================================================================
#  3. Jellyfin (native Termux, no proot)
# =============================================================================
JF_OK=0
if [ $WANT_JF -eq 1 ]; then
step "Installing Jellyfin (native Termux packages)"
# Jellyfin 10.11+ refuses to start with under 2 GiB free on its data volume
mkdir -p "$JF_ROOT"
FREE_KB="$(df -Pk "$JF_ROOT" 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "${FREE_KB:-}" ] && [ "$FREE_KB" -lt 2097152 ]; then
  warn "Only $((FREE_KB / 1024)) MiB free where Jellyfin's data will live ($JF_ROOT);"
  warn "Jellyfin needs at least 2 GiB free or it will refuse to start."
fi
if run_quiet "Installing Jellyfin + .NET runtime (can take a few minutes)" pkg install -y jellyfin-server aspnetcore-runtime-10.0; then
  # The Jellyfin launcher is a .NET 10 apphost and must be told where .NET lives.
  JF_DOTNET_ROOT="$PREFIX/lib/dotnet"
  if [ ! -x "$JF_DOTNET_ROOT/dotnet" ] && command -v dotnet >/dev/null 2>&1; then
    JF_DOTNET_ROOT="$(dirname "$(readlink -f "$(command -v dotnet)")")"
  fi
  [ -x "$JF_DOTNET_ROOT/dotnet" ] || warn "dotnet not found under $JF_DOTNET_ROOT (check: dpkg -L aspnetcore-runtime-10.0)"
  # work out where the packages put things, so we don't hard-code paths
  ALLFILES="$(for p in jellyfin-server jellyfin-web jellyfin-ffmpeg; do dpkg -L "$p" 2>/dev/null; done)"

  JF_BIN="$(echo "$ALLFILES" | grep -E '/bin/jellyfin$' | head -n1)"
  JF_DLL="$(echo "$ALLFILES" | grep -E '/jellyfin\.dll$' | head -n1)"
  [ -z "$JF_BIN" ] && JF_BIN="$(command -v jellyfin || true)"
  if [ -n "$JF_BIN" ] && [ -x "$JF_BIN" ]; then
    JF_CMD="$JF_BIN"
  elif [ -n "$JF_DLL" ]; then
    JF_CMD="dotnet $JF_DLL"
  else
    JF_CMD=""
  fi
  JF_WEB="$(echo "$ALLFILES" | grep -E '/web/index\.html$' | head -n1)"; JF_WEB="${JF_WEB%/index.html}"
  JF_FFMPEG="$(echo "$ALLFILES" | grep -E '/jellyfin-ffmpeg[^/]*/ffmpeg$' | head -n1)"
  [ -z "$JF_FFMPEG" ] && JF_FFMPEG="$BIN/ffmpeg"

  # A PredefinedCulturesOnly value in Jellyfin's runtimeconfig overrides the env
  # variable, so set it there too (else: "en-US is an invalid culture identifier").
  JF_RC="$(echo "$ALLFILES" | grep -E '/jellyfin\.runtimeconfig\.json$' | head -n1)"
  [ -z "$JF_RC" ] && [ -n "$JF_DLL" ] && JF_RC="${JF_DLL%.dll}.runtimeconfig.json"
  if [ -n "$JF_RC" ] && [ -f "$JF_RC" ]; then
    if jq '.runtimeOptions.configProperties["System.Globalization.PredefinedCulturesOnly"]=false' "$JF_RC" > "$JF_RC.new" 2>/dev/null; then
      mv "$JF_RC.new" "$JF_RC" && ok "Allowed named cultures in $JF_RC"
    else
      rm -f "$JF_RC.new"; warn "Could not edit $JF_RC"
    fi
  else
    warn "jellyfin.runtimeconfig.json not found (en-US culture error may occur)"
  fi

  if [ -n "$JF_CMD" ]; then
    JF_ARGS="--datadir $JF_ROOT/data --configdir $JF_ROOT/config --cachedir $JF_ROOT/cache --logdir $JF_ROOT/log"
    [ -n "$JF_WEB" ] && JF_ARGS+=" --webdir $JF_WEB"
    JF_ARGS+=" --ffmpeg $JF_FFMPEG"
    cat > "$BIN/start-jellyfin" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
# Jellyfin (native). Data lives in $JF_ROOT
# Your phone's storage is at $PHONE_STORAGE
mkdir -p "$JF_ROOT"/{data,config,cache,log,tmp}
echo "Starting Jellyfin on port 8096 ..."
# invariant globalization: the .NET runtime on Termux can't load ICU data
# (crash on startup: Could not load ICU data, UErrorCode 2). Passed via
# env so it reaches tmux even if a tmux server is already running.
# PREDEFINED_CULTURES_ONLY=false is also needed: Jellyfin creates the en-US
# culture, which invariant mode otherwise rejects.
# TMPDIR/DOTNET_EnableDiagnostics keep .NET temp files (and its diagnostic
# socket, which SD cards can't hold) off the small internal partition.
exec svc-run jellyfin env DOTNET_ROOT=$JF_DOTNET_ROOT DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 DOTNET_SYSTEM_GLOBALIZATION_PREDEFINED_CULTURES_ONLY=false DOTNET_EnableDiagnostics=0 TMPDIR=$JF_ROOT/tmp $JF_CMD $JF_ARGS
EOF
    chmod +x "$BIN/start-jellyfin"
    add_alias jf start-jellyfin
    JF_OK=1
    clean_cache
    ok "Jellyfin installed  ->  command: start-jellyfin   (alias: jf)"
  else
    err "Installed the packages but could not find the Jellyfin executable. Run: dpkg -L jellyfin-server"
  fi
else
  err "pkg install jellyfin-server aspnetcore-runtime-10.0 failed (see log above; try 'pkg update' or 'termux-change-repo')."
fi
else
  info "Skipping Jellyfin (not selected)."
fi

# =============================================================================
#  4. File Browser Quantum
# =============================================================================
FB_PW=""; FB_OK=0
if [ $WANT_FB -eq 1 ]; then
  step "Installing File Browser Quantum"
  case "$(uname -m)" in
    aarch64|arm64) FB_ASSET="linux-arm64-filebrowser" ;;
    x86_64)        FB_ASSET="linux-amd64-filebrowser" ;;
    *)             FB_ASSET="" ;;
  esac
  if [ -z "$FB_ASSET" ]; then
    err "No prebuilt File Browser Quantum binary for CPU '$(uname -m)'. Skipping."
  else
    FB_DIR="$HOME_DIR/filebrowser"
    FB_CACHE="$FB_DIR/cache"
    [ -n "$FB_CACHE_ROOT" ] && FB_CACHE="$FB_CACHE_ROOT/cache"
    mkdir -p "$FB_DIR" "$FB_CACHE"
    if run_quiet "Downloading File Browser Quantum" curl -fsSL --retry 3 -o "$FB_DIR/filebrowser.new" \
         "https://github.com/gtsteffaniak/filebrowser/releases/latest/download/$FB_ASSET"; then
      mv "$FB_DIR/filebrowser.new" "$FB_DIR/filebrowser"
      chmod +x "$FB_DIR/filebrowser"
      # File Browser Quantum v2 changed the config layout (port moved to "http:",
      # database path is no longer a plain string). A v1-style config makes it exit
      # with "old database path is set in the config", so set it aside.
      if [ -f "$FB_DIR/config.yaml" ] && ! grep -q '^http:' "$FB_DIR/config.yaml"; then
        mv "$FB_DIR/config.yaml" "$FB_DIR/config.yaml.v1.bak"
        warn "Old-format File Browser config saved as config.yaml.v1.bak; writing a v2 one"
      fi
      if [ ! -f "$FB_DIR/config.yaml" ]; then
        FB_PW="$(random_pw)"
        # No database setting: v2 defaults to filebrowser.sqlite in $FB_DIR (we cd there).
        cat > "$FB_DIR/config.yaml" <<EOF
http:
  port: 8080
server:
  cacheDir: $FB_CACHE
  sources:
    - path: $PHONE_STORAGE
      name: Phone
      config:
        defaultEnabled: true
auth:
  adminUsername: admin
  adminPassword: $FB_PW
EOF
        chmod 600 "$FB_DIR/config.yaml"
      else
        warn "Existing config kept: $FB_DIR/config.yaml (password unchanged)"
        FB_PW="(see $FB_DIR/config.yaml)"
      fi
      cat > "$BIN/start-filebrowser" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
cd "$FB_DIR" || exit 1
exec svc-run filebrowser ./filebrowser -c "$FB_DIR/config.yaml"
EOF
      chmod +x "$BIN/start-filebrowser"
      add_alias fb start-filebrowser
      FB_OK=1
      ok "File Browser installed  ->  command: start-filebrowser   (alias: fb)"
    else
      err "Download failed. Check https://github.com/gtsteffaniak/filebrowser/releases"
    fi
  fi
fi

# =============================================================================
#  5. copyparty
# =============================================================================
CP_PW=""; CP_OK=0
if [ $WANT_CP -eq 1 ]; then
  step "Installing copyparty"
  run_quiet "Installing Pillow (for thumbnails)" pkg install -y python-pillow || warn "python-pillow not installed (thumbnails will be limited)"
  if run_quiet "Installing copyparty (pip)" pip install --upgrade --no-cache-dir copyparty; then
    CP_PW="$(random_pw)"
    CP_HIST_ARG=""
    [ -n "$CP_HIST" ] && mkdir -p "$CP_HIST" && CP_HIST_ARG="--hist $CP_HIST"
    cat > "$BIN/start-copyparty" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
# Shares $PHONE_STORAGE at port 3923. Login: admin / (password below)
exec svc-run copyparty python -m copyparty -p 3923 $CP_HIST_ARG \\
  -a admin:$CP_PW \\
  -v $PHONE_STORAGE::A,admin
EOF
    chmod 700 "$BIN/start-copyparty"   # contains the password
    add_alias cpy start-copyparty
    CP_OK=1
    ok "copyparty installed  ->  command: start-copyparty   (alias: cpy)"
  else
    err "pip install copyparty failed."
  fi
fi

# =============================================================================
#  6. Syncthing
# =============================================================================
ST_OK=0
if [ $WANT_ST -eq 1 ]; then
  step "Installing Syncthing"
  if run_quiet "Installing Syncthing" pkg install -y syncthing; then
    cat > "$BIN/start-syncthing" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
exec svc-run syncthing syncthing serve --no-browser --no-upgrade
EOF
    chmod +x "$BIN/start-syncthing"
    add_alias st start-syncthing
    ST_OK=1
    ok "Syncthing installed  ->  command: start-syncthing   (alias: st)"
  else
    err "Syncthing install failed."
  fi
fi

# =============================================================================
#  7. Tunnel: cloudflared or ngrok
# =============================================================================
TUN_NAME=""
if [ "$TN_CHOICE" = 1 ]; then
  step "Installing cloudflared"
  if run_quiet "Installing cloudflared" pkg install -y cloudflared; then
    cat > "$BIN/start-tunnel" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# usage: start-tunnel [port]      (default 8096 = Jellyfin)
PORT="${1:-8096}"
echo "Opening a Cloudflare quick tunnel to http://localhost:$PORT"
echo "Look for the https://<random>.trycloudflare.com URL below. Ctrl+C to stop."
exec cloudflared tunnel --url "http://localhost:$PORT"
EOF
    chmod +x "$BIN/start-tunnel"
    add_alias tun start-tunnel
    TUN_NAME="cloudflared"
    ok "cloudflared installed  ->  command: start-tunnel [port]   (alias: tun)"
  else
    err "cloudflared install failed."
  fi
elif [ "$TN_CHOICE" = 2 ]; then
  step "Installing ngrok (native, no proot)"
  case "$(uname -m)" in
    aarch64|arm64) NG_ARCH="arm64" ;;
    armv7l|armv8l|arm) NG_ARCH="arm" ;;
    x86_64) NG_ARCH="amd64" ;;
    *) NG_ARCH="" ;;
  esac
  if [ -z "$NG_ARCH" ]; then
    err "Unsupported CPU for ngrok."
  elif run_quiet "Downloading ngrok" curl -fsSL --retry 3 -o "$HOME_DIR/ngrok.tgz" \
       "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-$NG_ARCH.tgz"; then
    tar -xzf "$HOME_DIR/ngrok.tgz" -C "$BIN" ngrok && chmod +x "$BIN/ngrok"
    rm -f "$HOME_DIR/ngrok.tgz"

    # Android has no /etc/resolv.conf, so ngrok (a Go binary) can't find a DNS
    # server. Instead of proot, give it explicit resolvers in its own config.
    NG_CFG="$HOME_DIR/.config/ngrok/ngrok.yml"
    mkdir -p "$(dirname "$NG_CFG")"
    {
      echo 'version: "3"'
      echo 'agent:'
      [ -n "$NGROK_TOKEN" ] && echo "  authtoken: $NGROK_TOKEN"
      echo '  dns_resolver_ips:'
      echo '    - 1.1.1.1'
      echo '    - 8.8.8.8'
      # the CRL (revocation) check uses Go's default resolver, which also fails
      # without /etc/resolv.conf, so skip it. TLS itself is still verified.
      echo '  crl_noverify: true'
    } > "$NG_CFG"
    chmod 600 "$NG_CFG"
    [ -n "$NGROK_TOKEN" ] && ok "ngrok authtoken saved"

    cat > "$BIN/start-tunnel" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
# usage: start-tunnel [port]      (default 8096 = Jellyfin)
PORT="\${1:-8096}"
export SSL_CERT_FILE="$PREFIX/etc/tls/cert.pem"
echo "Opening an ngrok tunnel to http://localhost:\$PORT  (Ctrl+C to stop)"
exec ngrok http "\$PORT" --config "$NG_CFG"
EOF
    chmod +x "$BIN/start-tunnel"
    add_alias tun start-tunnel
    TUN_NAME="ngrok"
    ok "ngrok installed  ->  command: start-tunnel [port]   (alias: tun)"
  else
    err "ngrok download failed."
  fi
fi

# =============================================================================
#  8. Write aliases to ~/.bashrc (replaces any previous block)
# =============================================================================
step "Adding aliases to $BASHRC"
touch "$BASHRC"
sed -i '/# >>> termux-server-setup >>>/,/# <<< termux-server-setup <<</d' "$BASHRC"
{
  echo "# >>> termux-server-setup >>>"
  printf '%s' "$ALIASES"
  echo "# <<< termux-server-setup <<<"
} >> "$BASHRC"
ok "Aliases saved (active in new Termux sessions)"

# =============================================================================
#  9. Instructions
# =============================================================================
{
cat <<'EOF'
=====================================================================
  HOW TO USE YOUR TERMUX SERVERS
=====================================================================

Open a NEW Termux session (or run:  source ~/.bashrc) so the aliases
work. Re-read these notes any time with:  servers-help

Your phone's IP address is in Settings > Wi-Fi. Other devices on the
same network use  http://PHONE_IP:PORT . On the phone itself use
http://127.0.0.1:PORT .

Each service runs in the background in its own tmux session:
  see its output :  tmux attach -t NAME     (leave it: Ctrl+b, then d)
  stop one       :  stop-servers NAME
  stop all       :  stop-all

EOF

if [ $SSH_OK -eq 1 ]; then
cat <<EOF
---------------------------------------------------------------------
 SSH                          start:  ssh-on   stop:  ssh-off
---------------------------------------------------------------------
 From a computer on the same network:
     ssh -p 8022 $(whoami)@PHONE_IP
 Login with the password you set (change it any time with: passwd).
 sshd must be running (ssh-on) for this to work.

EOF
fi

if [ $JF_OK -eq 1 ]; then
cat <<EOF
---------------------------------------------------------------------
 JELLYFIN                     start:  start-jellyfin    (alias: jf)
---------------------------------------------------------------------
 Web UI : http://127.0.0.1:8096   (first start takes a minute or two)
 First run: open the URL, create your admin account, then Add Media
 Library and browse to your phone's storage, e.g.:
        /storage/emulated/0/Movies
 (requires the storage permission granted to Termux)
 Jellyfin refuses to start with less than 2 GiB free storage on the phone.
 Data lives in $JF_ROOT . Software transcoding on a phone is slow;
 use Direct Play when you can.
EOF
fi

if [ $FB_OK -eq 1 ]; then
cat <<EOF

---------------------------------------------------------------------
 FILE BROWSER QUANTUM         start:  start-filebrowser (alias: fb)
---------------------------------------------------------------------
 Web UI : http://127.0.0.1:8080
 Login  : admin / $FB_PW
 Config : $HOME_DIR/filebrowser/config.yaml  (edit, then restart)
 Docs   : https://filebrowserquantum.com
 Shares : $PHONE_STORAGE
EOF
fi

if [ $CP_OK -eq 1 ]; then
cat <<EOF

---------------------------------------------------------------------
 COPYPARTY                    start:  start-copyparty   (alias: cpy)
---------------------------------------------------------------------
 Web UI : http://127.0.0.1:3923
 Login  : admin / $CP_PW
 Shares : $PHONE_STORAGE   (change in $BIN/start-copyparty)
 Update : pip install --upgrade --no-cache-dir copyparty
EOF
[ -n "$CP_HIST" ] && echo " Index/thumbnails: $CP_HIST  (on the SD card)"
fi

if [ $ST_OK -eq 1 ]; then
cat <<'EOF'

---------------------------------------------------------------------
 SYNCTHING                    start:  start-syncthing   (alias: st)
---------------------------------------------------------------------
 Web UI : http://127.0.0.1:8384  (open it in the phone's browser)
 First run: set a GUI username/password under Actions > Settings > GUI,
 then add your other devices by Device ID and share folders (the
 storage path is /storage/emulated/0/... ).
EOF
fi

if [ -n "$TUN_NAME" ]; then
cat <<'EOF'

---------------------------------------------------------------------
 TUNNEL                       start:  start-tunnel [port] (alias: tun)
---------------------------------------------------------------------
 The service you want to share must already be running. Open a SECOND
 Termux session (swipe in from the left edge > New session), then:
     start-tunnel 8096     Jellyfin
     start-tunnel 8080     File Browser
     start-tunnel 3923     copyparty
     start-tunnel 8384     Syncthing GUI (not recommended)
EOF
if [ "$TUN_NAME" = cloudflared ]; then
cat <<'EOF'
 cloudflared prints a public https://<random>.trycloudflare.com URL.
 It changes every time. Press Ctrl+C to close the tunnel.
EOF
else
cat <<'EOF'
 ngrok shows your public URL in its status screen. Ctrl+C closes it.
 If you skipped the authtoken during setup, get one at
 https://dashboard.ngrok.com/get-started/your-authtoken and run:
     ngrok config add-authtoken YOUR_TOKEN --config ~/.config/ngrok/ngrok.yml
 (DNS resolvers are set in that config file because Android has no
  /etc/resolv.conf, and CRL checking is disabled for the same reason;
  no proot is involved.)
EOF
fi
cat <<'EOF'
 SECURITY: a tunnel puts the service on the public internet. Use strong
 passwords and only keep the tunnel open while you need it.
EOF
fi

cat <<'EOF'

---------------------------------------------------------------------
 KEEPING THINGS RUNNING ON ANDROID
---------------------------------------------------------------------
 * Install Termux from F-Droid or GitHub, NOT the Play Store build.
 * Settings > Apps > Termux > Battery > set to Unrestricted.
 * The start-* commands take a wake lock automatically; the Termux
   notification must stay visible (do not swipe Termux away in Recents).
 * Android 12+ may kill background processes ("phantom process killer").
   If services die randomly: Developer options > "Disable child process
   restrictions" (Android 14+), or disable it via adb.
 * Updating Jellyfin: pkg upgrade jellyfin-server (or re-run this script).
   Your Jellyfin data is kept.
 * Re-running termux-server-setup.sh is safe; it will refresh things.
=====================================================================
EOF
} > "$README"

step "How to use it"
echo
show_readme
step "All done"
ok "Setup finished in $((SECONDS / 60))m $((SECONDS % 60))s"
info "Notes saved to $README  (read them again any time with: servers-help)"
info "Internal storage free: $(df -h "$HOME_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
if [ $USE_SD -eq 1 ]; then
  info "SD card data folder:   $SD_ROOT  ($(df -h "$SD_ROOT" 2>/dev/null | awk 'NR==2{print $4}') free)"
fi
info "Open a NEW Termux session (or run: source ~/.bashrc) to use the aliases."
echo
