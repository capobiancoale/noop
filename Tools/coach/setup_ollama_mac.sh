#!/bin/bash
# NOOP Coach: Ollama on the Mac as the Coach's server (provider "Custom" / "Personalizzato").
#
# Run in the Mac's Terminal:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/capobiancoale/noop/refs/heads/claude/blissful-mayer-0dvnwt/Tools/coach/setup_ollama_mac.sh)"
#
# What it does (safe to run again at any time):
#   1. installs Ollama in Applications if it is missing (free, about 230 MB to download);
#   2. makes it reachable from the other devices on your Wi-Fi (port 11434), also after a restart;
#   3. downloads llama3.2:3b (about 2 GB, speaks Italian) and adds "noop-coach", the same model with an
#      8192-token context window so the Coach's metrics fit (it shares the files: no extra space);
#   4. tries the model and prints what to type into the Coach on the iPhone.
#
# No key is involved: Ollama uses none. Nothing leaves the Mac except the two downloads.
# Messages are in Italian for the person running it.

set -u

BASE_MODEL="${NOOP_COACH_MODEL:-llama3.2:3b}"
COACH_MODEL="noop-coach"
CONTEXT=8192
PORT=11434
DMG_URL="https://ollama.com/download/Ollama.dmg"
AGENT="$HOME/Library/LaunchAgents/com.noop.ollama-host.plist"
LOCAL="http://127.0.0.1:$PORT"
# The CLI below always talks to the server on this Mac, whatever the shell has set.
export OLLAMA_HOST="127.0.0.1:$PORT"

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '\033[33m   %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Questo script è per macOS."

server_up() { curl -s -m 2 "$1/api/version" >/dev/null 2>&1; }

wait_for() {  # wait_for up|down seconds
  i=0
  while [ "$i" -lt "$2" ]; do
    if server_up "$LOCAL"; then [ "$1" = up ] && return 0; else [ "$1" = down ] && return 0; fi
    sleep 1; i=$((i + 1))
  done
  return 1
}

find_app() {
  for a in "/Applications/Ollama.app" "$HOME/Applications/Ollama.app"; do
    [ -d "$a" ] && { echo "$a"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------- 1. Ollama
bold "1/4  Ollama"
APP_PATH="$(find_app || true)"
if [ -z "$APP_PATH" ]; then
  info "Non è installato: lo scarico (gratuito, circa 230 MB)."
  TMP="$(mktemp -d)" || fail "Non riesco a creare una cartella temporanea."
  curl -fL --progress-bar -o "$TMP/Ollama.dmg" "$DMG_URL" || fail "Download di Ollama non riuscito. Controlla la connessione e riprova."
  mkdir -p "$TMP/mnt"
  hdiutil attach -nobrowse -quiet -mountpoint "$TMP/mnt" "$TMP/Ollama.dmg" || fail "Non riesco ad aprire Ollama.dmg."
  SRC="$(ls -d "$TMP/mnt"/*.app 2>/dev/null | head -1)"
  DEST="/Applications"
  [ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
  rc=1
  [ -n "$SRC" ] && cp -R "$SRC" "$DEST/" && rc=0
  hdiutil detach -quiet "$TMP/mnt" >/dev/null 2>&1 && rm -rf "$TMP"
  [ "$rc" -eq 0 ] || fail "Non riesco a copiare Ollama in $DEST."
  APP_PATH="$DEST/$(basename "$SRC")"
  info "Installato in $APP_PATH"
else
  info "Già installato: $APP_PATH"
fi

CLI="$APP_PATH/Contents/Resources/ollama"
[ -x "$CLI" ] || CLI="$(find "$APP_PATH/Contents" -type f -name ollama -perm -u+x 2>/dev/null | head -1)"
[ -n "$CLI" ] && [ -x "$CLI" ] || CLI="$(command -v ollama || true)"
[ -n "$CLI" ] || fail "Non trovo il comando ollama dentro $APP_PATH."

# ---------------------------------------------------------------- 2. Network
bold "2/4  Rendo Ollama raggiungibile dall'iPhone sulla tua rete Wi-Fi"
launchctl setenv OLLAMA_HOST "0.0.0.0:$PORT"
# The same setting again at every login, so it survives a restart of the Mac.
mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.noop.ollama-host</string>
  <key>ProgramArguments</key>
  <array><string>/bin/launchctl</string><string>setenv</string><string>OLLAMA_HOST</string><string>0.0.0.0:$PORT</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST

# Restart Ollama so it picks the setting up.
osascript -e 'quit app "Ollama"' >/dev/null 2>&1
wait_for down 15 || warn "Un altro server Ollama è ancora acceso su questo Mac (aperto dal Terminale o da Homebrew?): chiudilo e rilancia lo script."
open "$APP_PATH" || fail "Non riesco ad aprire Ollama."
wait_for up 60 || fail "Ollama non si è avviato. Aprilo a mano da Applicazioni e rilancia lo script."

IFACE="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
IP=""
[ -n "$IFACE" ] && IP="$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)"
[ -n "$IP" ] || IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
HOSTNAME_LOCAL="$(scutil --get LocalHostName 2>/dev/null || true)"

EXPOSED=0
if [ -n "$IP" ] && server_up "http://$IP:$PORT"; then
  EXPOSED=1
  info "Ollama risponde anche in rete su $IP"
elif [ -z "$IP" ]; then
  warn "Il Mac non sembra collegato a una rete: collegalo al Wi-Fi di casa e rilancia lo script."
else
  warn "Ollama risponde solo su questo Mac. Apri Ollama, vai nelle Impostazioni, attiva"
  warn "\"Expose Ollama to the network\" e rilancia lo script."
fi

FW="$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null || true)"
case "$FW" in
  *"State = 0"*|"") ;;
  *) info "Il firewall del Mac è attivo: se macOS chiede se Ollama può accettare connessioni, scegli Consenti."
     info "(Oppure Impostazioni di Sistema > Rete > Firewall > Opzioni > Ollama > Consenti connessioni in entrata.)" ;;
esac

# ---------------------------------------------------------------- 3. Model
bold "3/4  Modello $BASE_MODEL (circa 2 GB, si scarica solo la prima volta)"
"$CLI" pull "$BASE_MODEL" || fail "Download del modello non riuscito. Controlla la connessione e rilancia lo script."
MF="$(mktemp)" || fail "Non riesco a creare un file temporaneo."
printf 'FROM %s\nPARAMETER num_ctx %s\n' "$BASE_MODEL" "$CONTEXT" > "$MF"
"$CLI" create "$COACH_MODEL" -f "$MF" >/dev/null 2>&1 || { rm -f "$MF"; fail "Non riesco a creare il modello $COACH_MODEL."; }
rm -f "$MF"
info "Pronto: $COACH_MODEL ($BASE_MODEL con $CONTEXT token di contesto)"

# ---------------------------------------------------------------- 4. Try it
bold "4/4  Provo il modello (la prima risposta può metterci un po')"
REPLY_JSON="$(curl -s -m 240 "$LOCAL/v1/chat/completions" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$COACH_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Rispondi solo con la parola: pronto\"}],\"max_tokens\":20}")"
case "$REPLY_JSON" in
  *'"choices"'*) info "Risposta del modello: $(printf '%s' "$REPLY_JSON" | sed -n 's/.*"content":"\([^"]*\)".*/\1/p' | head -1)" ;;
  *) warn "Il modello non ha risposto come previsto: ${REPLY_JSON:-nessuna risposta}" ;;
esac

# ---------------------------------------------------------------- Summary
bold "Sull'iPhone: NOOP > Coach"
info "Provider:        Personalizzato"
if [ -n "$HOSTNAME_LOCAL" ]; then
  info "URL del server:  http://$HOSTNAME_LOCAL.local:$PORT/v1"
  [ -n "$IP" ] && info "                 (se non si collega: http://$IP:$PORT/v1)"
elif [ -n "$IP" ]; then
  info "URL del server:  http://$IP:$PORT/v1"
fi
info "Modello:         $COACH_MODEL  (tocca \"Aggiorna modelli\"; se non compare, \"Personalizzato…\" e scrivi $COACH_MODEL)"
info "Chiave API:      lascia vuoto"
info "Poi tocca \"Collega\". Se iOS chiede di trovare dispositivi sulla rete locale, tocca Consenti."
echo
info "Il Mac deve essere acceso, sveglio e sulla stessa rete Wi-Fi dell'iPhone."
[ "$EXPOSED" -eq 1 ] || warn "Attenzione: per ora Ollama non è raggiungibile dalla rete (vedi il passo 2)."
