#!/usr/bin/env bash
# =============================================================================
# install_keet_dropin.sh
# =============================================================================
#   - Installs into an explicitly selected target: Hermes-agent, Nanobot,
#     CoPaw/QwenPaw, OpenClaw (or explicit auto-detect mode).
#   - Installs Node v20 inside the selected workspace (if missing).
#   - Installs required npm dependencies.
#   - Creates a shared always-on Keet core (daemon + RPC + event stream).
#   - Generates equivalent skills/adapters for Nanobot, CoPaw, Hermes, OpenClaw.
# =============================================================================

set -euo pipefail

# -------------------------------------------------------------------------
# Configuration
# -------------------------------------------------------------------------
NODE_VERSION="20.12.0"

# -------------------------------------------------------------------------
# Helper functions for pretty output
# -------------------------------------------------------------------------
log()   { printf "\e[32m[✔]\e[0m %s\n" "$*"; }
warn()  { printf "\e[33m[!]\e[0m %s\n" "$*"; }
error() { printf "\e[31m[✖]\e[0m %s\n" "$*" >&2; exit 1; }

print_help() {
  cat <<'EOF'
Keet Drop-in installer

Usage:
  bash install_keet_dropin.sh [--target <hermes|nanobot|copaw|openclaw|auto>] [--reset-state] [--help]

Targets:
  hermes    Install for Hermes-agent (recommended/default in interactive mode)
  nanobot   Install for NanoBot
  copaw     Install for CoPaw / QwenPaw
  openclaw  Install for OpenClaw workspace (run from OpenClaw repo root)
  auto      Auto-detect exactly one installed runtime (fails if multiple are found)

Examples:
  # Interactive install (defaults to Hermes)
  bash install_keet_dropin.sh

  # Non-interactive install for Hermes
  bash install_keet_dropin.sh --target hermes

  # Non-interactive install for NanoBot
  bash install_keet_dropin.sh --target nanobot

  # Non-interactive install for CoPaw / QwenPaw
  bash install_keet_dropin.sh --target copaw

  # Non-interactive install for OpenClaw (run from OpenClaw repo root)
  bash install_keet_dropin.sh --target openclaw

  # Remote install with explicit target
  bash <(curl -fsSL https://raw.githubusercontent.com/pepeneif/keet-dropin-module/main/install_keet_dropin.sh) --target hermes

  # Piped install with explicit target
  curl -fsSL https://raw.githubusercontent.com/pepeneif/keet-dropin-module/main/install_keet_dropin.sh | bash -s -- --target hermes

  # Recovery install for Hermes (backs up + resets persisted Keet state)
  bash install_keet_dropin.sh --target hermes --reset-state
EOF
}

normalize_target() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

TARGET=""
RESET_STATE="false"
RESET_BACKUP_SUFFIX=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      [[ $# -ge 2 ]] || error "Missing value for --target. Use --help for examples."
      TARGET=$(normalize_target "$2")
      shift 2
      ;;
    --target=*)
      TARGET=$(normalize_target "${1#*=}")
      shift
      ;;
    --reset-state)
      RESET_STATE="true"
      shift
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      error "Unknown argument: $1. Use --help for supported options."
      ;;
  esac
done

is_supported_target() {
  case "$1" in
    hermes|nanobot|copaw|openclaw|auto) return 0 ;;
    *) return 1 ;;
  esac
}

select_target_interactive() {
  echo ""
  echo "Select OpenClaw-family target for Keet installation:"
  echo "  1) Hermes-agent (default, recommended)"
  echo "  2) NanoBot"
  echo "  3) CoPaw / QwenPaw"
  echo "  4) OpenClaw"
  echo "  5) Auto-detect (explicit)"
  read -r -p "Choose target [1]: " choice

  case "${choice:-1}" in
    1) TARGET="hermes" ;;
    2) TARGET="nanobot" ;;
    3) TARGET="copaw" ;;
    4) TARGET="openclaw" ;;
    5) TARGET="auto" ;;
    *) error "Invalid choice: ${choice}." ;;
  esac
}

detect_agent_auto() {
  local detected=()

  if command -v hermes-agent >/dev/null 2>&1 || command -v hermes >/dev/null 2>&1; then
    detected+=("hermes")
  fi
  command -v nanobot >/dev/null 2>&1 && detected+=("nanobot")
  command -v copaw >/dev/null 2>&1 && detected+=("copaw")
  [[ -d "$(pwd)/src" && -f "$(pwd)/package.json" ]] && detected+=("openclaw")

  if (( ${#detected[@]} == 0 )); then
    error "Auto-detect found no supported target. Re-run with --target <hermes|nanobot|copaw|openclaw>."
  fi

  if (( ${#detected[@]} > 1 )); then
    error "Auto-detect is ambiguous (found: ${detected[*]}). Re-run with explicit --target <hermes|nanobot|copaw|openclaw>."
  fi

  printf '%s' "${detected[0]}"
}

validate_target_prereqs() {
  case "$1" in
    hermes)
      if ! command -v hermes-agent >/dev/null 2>&1 && ! command -v hermes >/dev/null 2>&1; then
        error "--target hermes requested but neither 'hermes-agent' nor 'hermes' was found in PATH."
      fi
      ;;
    nanobot)
      command -v nanobot >/dev/null 2>&1 || error "--target nanobot requested but 'nanobot' was not found in PATH."
      ;;
    copaw)
      command -v copaw >/dev/null 2>&1 || error "--target copaw requested but 'copaw' was not found in PATH."
      ;;
    openclaw)
      [[ -d "$(pwd)/src" && -f "$(pwd)/package.json" ]] || error "--target openclaw requires running from the OpenClaw workspace root (must contain ./src and ./package.json)."
      ;;
    *)
      error "Unsupported target: $1"
      ;;
  esac
}

validate_target_capabilities() {
  case "$1" in
    nanobot)
      if ! nanobot --help >/dev/null 2>&1; then
        warn "NanoBot binary is present but 'nanobot --help' failed. Continuing; runtime command surface may differ."
      fi
      ;;
    copaw)
      copaw channels --help >/dev/null 2>&1 || error "--target copaw requires a CoPaw CLI with 'channels' support (expected command: 'copaw channels ...')."
      ;;
    openclaw)
      [[ -w "$WORKSPACE" ]] || error "OpenClaw workspace is not writable: $WORKSPACE"
      if ! grep -qi 'openclaw' "$WORKSPACE/package.json"; then
        warn "OpenClaw target selected, but package.json does not appear to reference openclaw explicitly. Verify plugin SDK compatibility manually."
      fi
      ;;
  esac
}

stop_existing_keet_daemon() {
  local daemon_path="${SKILLS_ROOT}/keet-core/daemon.js"
  local socket_path="${ROOMS_DIR}/keet-core.sock"
  local pid_path="${ROOMS_DIR}/keet-core.pid"
  local stopped=0

  if command -v pkill >/dev/null 2>&1; then
    if pkill -f "$daemon_path" >/dev/null 2>&1; then
      stopped=1
    fi
  fi

  if [[ -f "$pid_path" ]]; then
    local pid
    pid=$(tr -d '[:space:]' < "$pid_path" || true)
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" >/dev/null 2>&1; then
      if ps -p "$pid" -o command= | grep -F -- "$daemon_path" >/dev/null 2>&1; then
        kill "$pid" >/dev/null 2>&1 || true
        stopped=1
      else
        warn "Ignoring stale PID file: pid $pid does not match Keet daemon command"
      fi
    fi
  fi

  rm -f "$socket_path" "$pid_path"

  if (( stopped == 1 )); then
    log "Stopped existing Keet daemon process"
  fi
  log "Cleared stale Keet IPC files (socket/pid) in $ROOMS_DIR"
}

reset_persisted_keet_state() {
  local ts key_path state_path backed_up=0
  ts=$(date +%Y%m%d-%H%M%S)
  key_path="${ROOMS_DIR}/keet-key-material.json"
  state_path="${ROOMS_DIR}/keet-state.json"

  if [[ -f "$key_path" ]]; then
    cp "$key_path" "${key_path}.bak.${ts}"
    backed_up=1
  fi

  if [[ -f "$state_path" ]]; then
    cp "$state_path" "${state_path}.bak.${ts}"
    backed_up=1
  fi

  rm -f "$key_path" "$state_path"
  RESET_BACKUP_SUFFIX="$ts"

  if (( backed_up == 1 )); then
    log "Backed up persisted Keet state to *.bak.${ts}"
  else
    warn "No persisted Keet state files found to back up"
  fi

  log "Reset persisted Keet state via --reset-state"
}

# -------------------------------------------------------------------------
# Detect OS and architecture for Node download
# -------------------------------------------------------------------------
detect_platform() {
  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)

  case "$os" in
    linux) OS="linux" ;;
    darwin) OS="darwin" ;;
    *) error "Unsupported operating system: $os" ;;
  esac

  case "$arch" in
    x86_64) ARCH="x64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) error "Unsupported architecture: $arch" ;;
  esac

  PLATFORM="${OS}-${ARCH}"
}

# -------------------------------------------------------------------------
# 1️⃣ Resolve install target (explicit selection first)
# -------------------------------------------------------------------------
if [[ -z "$TARGET" ]]; then
  if [[ -t 0 ]]; then
    select_target_interactive
  else
    error "Non-interactive mode requires --target <hermes|nanobot|copaw|openclaw|auto>."
  fi
fi

is_supported_target "$TARGET" || error "Unsupported target '$TARGET'. Use --help for supported values."

if [[ "$TARGET" == "auto" ]]; then
  AGENT_TYPE="$(detect_agent_auto)"
  log "Target auto-detected: $AGENT_TYPE"
else
  AGENT_TYPE="$TARGET"
  log "Target selected: $AGENT_TYPE"
fi

validate_target_prereqs "$AGENT_TYPE"

# -------------------------------------------------------------------------
# 2️⃣ Define workspace paths based on selected target
# -------------------------------------------------------------------------
PLUGIN_ROOT=""
CHANNEL_ROOT=""
case "$AGENT_TYPE" in
  nanobot)
    WORKSPACE="${HOME}/.nanobot/workspace"
    SKILLS_ROOT="${WORKSPACE}/skills"
    ROOMS_DIR="${HOME}/.nanobot/rooms"
    ;;
  copaw)
    WORKSPACE="${HOME}/.copaw"
    SKILLS_ROOT="${WORKSPACE}/skills"
    CHANNEL_ROOT="${WORKSPACE}/custom_channels"
    ROOMS_DIR="${HOME}/.copaw/rooms"
    ;;
  hermes)
    WORKSPACE="${HOME}/.hermes"
    SKILLS_ROOT="${WORKSPACE}/skills"
    PLUGIN_ROOT="${WORKSPACE}/plugins"
    ROOMS_DIR="${HOME}/.hermes/rooms"
    ;;
  openclaw)
    WORKSPACE="$(pwd)"
    SKILLS_ROOT="${WORKSPACE}/skills"
    PLUGIN_ROOT="${WORKSPACE}/src/plugins/keet-channel"
    ROOMS_DIR="${HOME}/.openclaw/rooms"
    ;;
esac

validate_target_capabilities "$AGENT_TYPE"

mkdir -p "$WORKSPACE"
mkdir -p "$SKILLS_ROOT"
mkdir -p "$ROOMS_DIR"
mkdir -p "${ROOMS_DIR}/sessions"
log "Workspace -> $WORKSPACE"
log "Persistent rooms folder -> $ROOMS_DIR"

# Pre-install daemon hygiene (default for all targets)
stop_existing_keet_daemon

# Optional persisted-state reset (backup + purge)
if [[ "$RESET_STATE" == "true" ]]; then
  reset_persisted_keet_state
fi

# -------------------------------------------------------------------------
# 3️⃣ Ensure Node v20 is present (download it if necessary)
# -------------------------------------------------------------------------
detect_platform
NODE_DIR="${WORKSPACE}/node-v${NODE_VERSION}-${PLATFORM}"
NODE_BIN="${NODE_DIR}/bin/node"
NPM_BIN="${NODE_DIR}/bin/npm"

if [[ -x "$NODE_BIN" ]]; then
  log "Node v${NODE_VERSION} already present -> $NODE_BIN"
else
  log "Downloading Node v${NODE_VERSION} for ${PLATFORM}..."
  TMPDIR=$(mktemp -d)
  pushd "$TMPDIR" >/dev/null
  NODE_TAR="node-v${NODE_VERSION}-${PLATFORM}.tar.xz"
  NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TAR}"
  curl -fsSLO "$NODE_URL" || error "Failed to download Node from $NODE_URL"
  mkdir -p "$NODE_DIR"
  tar -xJf "$NODE_TAR" -C "$NODE_DIR" --strip-components=1
  popd >/dev/null
  rm -rf "$TMPDIR"
  log "Node installed in $NODE_DIR"
fi
export PATH="${NODE_DIR}/bin:$PATH"

# -------------------------------------------------------------------------
# 4️⃣ Init a Node project (if missing) and install required npm packages
# -------------------------------------------------------------------------
cd "$WORKSPACE"
if [[ ! -f "package.json" ]]; then
  log "Initializing a new Node project..."
  "$NPM_BIN" init -y >/dev/null
fi

log "Installing required npm dependencies..."
"$NPM_BIN" install blind-pairing-core hypercore-id-encoding hypercore random-access-file z32 || error "Failed to install npm dependencies"
log "Dependencies installed"

# -------------------------------------------------------------------------
# 5️⃣ Generate shared Keet core + skills (common to all agents)
# -------------------------------------------------------------------------
ROOMS_DIR_JS="${ROOMS_DIR//\'/\\\'}"

mkdir -p "${SKILLS_ROOT}/keet-core"
mkdir -p "${SKILLS_ROOT}/keet-create-room"
mkdir -p "${SKILLS_ROOT}/keet-join-room"
mkdir -p "${SKILLS_ROOT}/keet-send-message"
mkdir -p "${SKILLS_ROOT}/keet-leave-room"
mkdir -p "${SKILLS_ROOT}/keet-list-sessions"

# ---- keet-core / daemon.js ---------------------------------------------
cat > "${SKILLS_ROOT}/keet-core/daemon.js" <<EOF
#!/usr/bin/env node

const fs = require('fs')
const os = require('os')
const path = require('path')
const net = require('net')
const crypto = require('crypto')
const hypercore = require('hypercore')
const RAF = require('random-access-file')
const { createInvite, decodeInvite } = require('blind-pairing-core')
const { decode: decodeCoreKey } = require('hypercore-id-encoding')
const z32 = require('z32')

const BASE_DIR = '${ROOMS_DIR_JS}'
const SOCKET_PATH = path.join(BASE_DIR, 'keet-core.sock')
const PID_PATH = path.join(BASE_DIR, 'keet-core.pid')
const STATE_PATH = path.join(BASE_DIR, 'keet-state.json')
const KEY_MATERIAL_PATH = path.join(BASE_DIR, 'keet-key-material.json')
const STORAGE_DIR = path.join(BASE_DIR, 'sessions')

fs.mkdirSync(BASE_DIR, { recursive: true })
fs.mkdirSync(STORAGE_DIR, { recursive: true })

const sessions = new Map()
let nextEventId = 1
const events = []
const waiters = new Set()
let keyMaterial = null
let agentIdentityKey = null

function nowIso() {
  return new Date().toISOString()
}

function writeJsonAtomicSecure(filePath, data) {
  const tmpPath = filePath + '.tmp'
  const payload = JSON.stringify(data, null, 2)
  fs.writeFileSync(tmpPath, payload, { mode: 0o600 })
  fs.renameSync(tmpPath, filePath)
  try { fs.chmodSync(filePath, 0o600) } catch (_) {}
}

function decodeBase64Key(value, label) {
  const buf = Buffer.from(String(value || ''), 'base64')
  if (buf.byteLength !== 32) {
    throw new Error('Invalid key material for ' + label + ': expected 32 bytes')
  }
  return buf
}

function buildDefaultKeyMaterial() {
  const createdAt = nowIso()
  return {
    schemaVersion: 1,
    createdAt,
    updatedAt: createdAt,
    agentIdentity: {
      secretKey: crypto.randomBytes(32).toString('base64'),
      createdAt
    },
    roomOwnership: {}
  }
}

function normalizeKeyMaterial(raw) {
  const normalized = buildDefaultKeyMaterial()
  if (!raw || typeof raw !== 'object') return normalized

  if (typeof raw.createdAt === 'string') {
    normalized.createdAt = raw.createdAt
  }

  if (raw.agentIdentity && typeof raw.agentIdentity === 'object' && typeof raw.agentIdentity.secretKey === 'string') {
    try {
      decodeBase64Key(raw.agentIdentity.secretKey, 'agentIdentity.secretKey')
      normalized.agentIdentity = {
        secretKey: raw.agentIdentity.secretKey,
        createdAt: typeof raw.agentIdentity.createdAt === 'string' ? raw.agentIdentity.createdAt : normalized.createdAt
      }
    } catch (_) {}
  }

  if (raw.roomOwnership && typeof raw.roomOwnership === 'object') {
    for (const [roomId, roomMeta] of Object.entries(raw.roomOwnership)) {
      if (!roomMeta || typeof roomMeta !== 'object') continue
      if (typeof roomMeta.ownerKey !== 'string') continue

      try {
        decodeBase64Key(roomMeta.ownerKey, 'roomOwnership.' + roomId + '.ownerKey')
      } catch (_) {
        continue
      }

      normalized.roomOwnership[roomId] = {
        ownerKey: roomMeta.ownerKey,
        roomName: typeof roomMeta.roomName === 'string' ? roomMeta.roomName : '',
        createdAt: typeof roomMeta.createdAt === 'string' ? roomMeta.createdAt : normalized.createdAt
      }
    }
  }

  return normalized
}

function loadKeyMaterial() {
  let parsed = null

  if (fs.existsSync(KEY_MATERIAL_PATH)) {
    try {
      parsed = JSON.parse(fs.readFileSync(KEY_MATERIAL_PATH, 'utf-8'))
    } catch (_) {
      parsed = null
    }
  }

  const normalized = normalizeKeyMaterial(parsed)
  normalized.updatedAt = nowIso()
  writeJsonAtomicSecure(KEY_MATERIAL_PATH, normalized)
  return normalized
}

function initializeKeyMaterial() {
  if (keyMaterial) return
  keyMaterial = loadKeyMaterial()
  agentIdentityKey = decodeBase64Key(keyMaterial.agentIdentity.secretKey, 'agentIdentity.secretKey')
}

function persistKeyMaterial() {
  if (!keyMaterial) return
  keyMaterial.updatedAt = nowIso()
  writeJsonAtomicSecure(KEY_MATERIAL_PATH, keyMaterial)
}

function agentIdentityFingerprint() {
  initializeKeyMaterial()
  return crypto.createHash('sha256').update(agentIdentityKey).digest('hex').slice(0, 16)
}

function normalizeInvite(url) {
  const m = String(url || '').trim().match(/^pear:\/\/keet\/([^/\s]+)$/)
  if (!m) throw new Error('Invalid Keet invite URL. Expected pear://keet/<roomId>')
  const roomId = m[1]

  // Backward compatibility: older installer versions encoded only discoveryKey
  // using hypercore-id-encoding (52-char z32 / 64-char hex).
  if (roomId.length === 52 || roomId.length === 64) {
    let discoveryKey
    try {
      discoveryKey = decodeCoreKey(roomId)
    } catch (_) {
      discoveryKey = null
    }

    if (discoveryKey && discoveryKey.byteLength === 32) {
      return {
        roomId,
        inviteUrl: 'pear://keet/' + roomId,
        discoveryKey,
        invitePayload: null,
        inviteFormat: 'legacy-discovery-key'
      }
    }
  }

  // Canonical Keet room IDs are z32-encoded blind-pairing invite payloads.
  let invitePayload
  try {
    invitePayload = z32.decode(roomId)
  } catch (_) {
    throw new Error('Invalid Keet invite URL payload')
  }

  let decodedInvite
  try {
    decodedInvite = decodeInvite(invitePayload)
  } catch (_) {
    throw new Error('Invalid Keet invite payload. Expected canonical blind-pairing invite data')
  }

  if (!decodedInvite.discoveryKey || decodedInvite.discoveryKey.byteLength !== 32) {
    throw new Error('Invalid Keet invite payload. Missing discovery key')
  }

  return {
    roomId,
    inviteUrl: 'pear://keet/' + roomId,
    discoveryKey: decodedInvite.discoveryKey,
    invitePayload,
    inviteFormat: 'canonical-invite'
  }
}

function storageFactory(storagePath) {
  return (name) => RAF(storagePath + '.' + name)
}

function pickEvents(since, sessionId) {
  return events.filter((e) => e.id > since && (!sessionId || e.sessionId === sessionId))
}

function pushEvent(event) {
  const enriched = {
    id: nextEventId++,
    ts: new Date().toISOString(),
    ...event
  }
  events.push(enriched)
  if (events.length > 5000) events.shift()

  for (const waiter of Array.from(waiters)) {
    const available = pickEvents(waiter.since, waiter.sessionId)
    if (available.length > 0) {
      clearTimeout(waiter.timer)
      waiters.delete(waiter)
      waiter.resolve(available)
    }
  }

  return enriched
}

function serializeState() {
  return {
    sessions: Array.from(sessions.values()).map((s) => ({
      sessionId: s.sessionId,
      inviteUrl: s.inviteUrl,
      roomId: s.roomId,
      storagePath: s.storagePath,
      joinedAt: s.joinedAt
    }))
  }
}

function persistState() {
  fs.writeFileSync(STATE_PATH, JSON.stringify(serializeState(), null, 2))
}

async function ensureSession(params) {
  const sessionId = params.sessionId || crypto.randomUUID()
  const existing = sessions.get(sessionId)
  if (existing) return existing

  if (!params.url) {
    throw new Error('Missing room URL for new session')
  }

  const invite = normalizeInvite(params.url)
  const discoveryKey = invite.discoveryKey
  const storagePath = path.join(STORAGE_DIR, invite.roomId + '_' + sessionId)
  const core = hypercore(storageFactory(storagePath), discoveryKey, { valueEncoding: 'utf-8' })
  await core.ready()

  const session = {
    sessionId,
    inviteUrl: invite.inviteUrl,
    roomId: invite.roomId,
    storagePath,
    joinedAt: new Date().toISOString(),
    core,
    stream: null
  }

  session.stream = core.createReadStream({ live: true, start: 0 })
  session.stream.on('data', (data) => {
    pushEvent({
      type: 'message',
      sessionId,
      roomId: invite.roomId,
      message: String(data)
    })
  })
  session.stream.on('error', (err) => {
    pushEvent({
      type: 'error',
      sessionId,
      roomId: invite.roomId,
      message: err.message
    })
  })

  sessions.set(sessionId, session)
  persistState()
  return session
}

async function cmdCreateRoom(params = {}) {
  initializeKeyMaterial()
  const roomName = String(params.roomName || '').trim() || crypto.randomUUID()
  const sessionId = crypto.randomUUID()
  const ownerKey = crypto.randomBytes(32)
  const { invite } = createInvite(ownerKey)
  const roomId = z32.encode(invite)

  keyMaterial.roomOwnership[roomId] = {
    ownerKey: ownerKey.toString('base64'),
    roomName,
    createdAt: nowIso()
  }
  persistKeyMaterial()

  return {
    roomId,
    inviteUrl: 'pear://keet/' + roomId,
    sessionId,
    roomName
  }
}

async function cmdJoinRoom(params = {}) {
  const session = await ensureSession({ url: params.url, sessionId: params.sessionId })
  pushEvent({
    type: 'joined',
    sessionId: session.sessionId,
    roomId: session.roomId,
    message: 'Session joined'
  })
  return {
    sessionId: session.sessionId,
    roomId: session.roomId,
    inviteUrl: session.inviteUrl,
    joinedAt: session.joinedAt
  }
}

async function cmdSendMessage(params = {}) {
  const message = String(params.message || '').trim()
  if (!message) throw new Error('Message cannot be empty')

  const session = await ensureSession({ url: params.url, sessionId: params.sessionId })
  await new Promise((resolve, reject) => {
    session.core.append(message, (err) => (err ? reject(err) : resolve()))
  })

  pushEvent({
    type: 'sent',
    sessionId: session.sessionId,
    roomId: session.roomId,
    message
  })

  return {
    status: 'sent',
    sessionId: session.sessionId,
    roomId: session.roomId
  }
}

async function cmdLeaveRoom(params = {}) {
  const sessionId = params.sessionId
  if (!sessionId) throw new Error('sessionId is required')

  const session = sessions.get(sessionId)
  if (!session) {
    return { status: 'noop', sessionId, detail: 'session not active' }
  }

  if (session.stream) {
    try { session.stream.destroy() } catch (_) {}
  }
  try { await session.core.close() } catch (_) {}
  sessions.delete(sessionId)
  persistState()

  pushEvent({
    type: 'left',
    sessionId,
    roomId: session.roomId,
    message: 'Session left'
  })

  return { status: 'left', sessionId, roomId: session.roomId }
}

async function cmdListSessions() {
  return Array.from(sessions.values()).map((s) => ({
    sessionId: s.sessionId,
    roomId: s.roomId,
    inviteUrl: s.inviteUrl,
    joinedAt: s.joinedAt
  }))
}

async function cmdFetchEvents(params = {}) {
  const since = Number.isFinite(Number(params.since)) ? Number(params.since) : 0
  const timeoutMs = Number.isFinite(Number(params.timeoutMs)) ? Number(params.timeoutMs) : 25000
  const sessionId = params.sessionId || null

  const immediate = pickEvents(since, sessionId)
  if (immediate.length > 0) return immediate

  return await new Promise((resolve) => {
    const waiter = {
      since,
      sessionId,
      resolve,
      timer: null
    }
    waiter.timer = setTimeout(() => {
      waiters.delete(waiter)
      resolve([])
    }, timeoutMs)
    waiters.add(waiter)
  })
}

async function restoreSessions() {
  if (!fs.existsSync(STATE_PATH)) return

  let state
  try {
    state = JSON.parse(fs.readFileSync(STATE_PATH, 'utf-8'))
  } catch (_) {
    return
  }

  const entries = Array.isArray(state.sessions) ? state.sessions : []
  for (const item of entries) {
    try {
      await ensureSession({ url: item.inviteUrl, sessionId: item.sessionId })
      pushEvent({
        type: 'restored',
        sessionId: item.sessionId,
        roomId: item.roomId,
        message: 'Session restored on daemon startup'
      })
    } catch (err) {
      pushEvent({
        type: 'error',
        sessionId: item.sessionId,
        roomId: item.roomId,
        message: 'Restore failed: ' + err.message
      })
    }
  }
}

async function handleRpc(req) {
  const method = req.method
  const params = req.params || {}

  if (method === 'ping') return { ok: true }
  if (method === 'createRoom') return await cmdCreateRoom(params)
  if (method === 'joinRoom') return await cmdJoinRoom(params)
  if (method === 'sendMessage') return await cmdSendMessage(params)
  if (method === 'leaveRoom') return await cmdLeaveRoom(params)
  if (method === 'listSessions') return await cmdListSessions()
  if (method === 'fetchEvents') return await cmdFetchEvents(params)

  throw new Error('Unknown RPC method: ' + method)
}

function cleanupSocket() {
  try {
    if (fs.existsSync(SOCKET_PATH)) fs.unlinkSync(SOCKET_PATH)
  } catch (_) {}
}

async function shutdown(server) {
  for (const s of sessions.values()) {
    if (s.stream) {
      try { s.stream.destroy() } catch (_) {}
    }
    try { await s.core.close() } catch (_) {}
  }
  sessions.clear()

  try { server.close() } catch (_) {}
  cleanupSocket()
  try { fs.unlinkSync(PID_PATH) } catch (_) {}
  process.exit(0)
}

async function main() {
  cleanupSocket()
  const identity = agentIdentityFingerprint()
  await restoreSessions()

  const server = net.createServer((socket) => {
    let buffer = ''

    socket.on('data', async (chunk) => {
      buffer += chunk.toString('utf-8')
      while (true) {
        const idx = buffer.indexOf('\n')
        if (idx < 0) break

        const line = buffer.slice(0, idx).trim()
        buffer = buffer.slice(idx + 1)
        if (!line) continue

        let req
        try {
          req = JSON.parse(line)
        } catch (err) {
          socket.write(JSON.stringify({ id: null, ok: false, error: 'Invalid JSON: ' + err.message }) + '\n')
          continue
        }

        try {
          const result = await handleRpc(req)
          socket.write(JSON.stringify({ id: req.id || null, ok: true, result }) + '\n')
        } catch (err) {
          socket.write(JSON.stringify({ id: req.id || null, ok: false, error: err.message }) + '\n')
        }
      }
    })
  })

  server.listen(SOCKET_PATH, () => {
    fs.writeFileSync(PID_PATH, String(process.pid))
    console.log('Keet core daemon listening on ' + SOCKET_PATH + ' (agent ' + identity + ')')
  })

  process.on('SIGINT', () => shutdown(server))
  process.on('SIGTERM', () => shutdown(server))
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
EOF
chmod +x "${SKILLS_ROOT}/keet-core/daemon.js"

# ---- keet-core / ensure_daemon.js --------------------------------------
cat > "${SKILLS_ROOT}/keet-core/ensure_daemon.js" <<EOF
#!/usr/bin/env node

const fs = require('fs')
const os = require('os')
const path = require('path')
const net = require('net')
const { spawn } = require('child_process')

const BASE_DIR = '${ROOMS_DIR_JS}'
const SOCKET_PATH = path.join(BASE_DIR, 'keet-core.sock')
const PID_PATH = path.join(BASE_DIR, 'keet-core.pid')
const DAEMON_PATH = path.join(__dirname, 'daemon.js')

fs.mkdirSync(BASE_DIR, { recursive: true })

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function isPidRunning(pid) {
  try {
    process.kill(pid, 0)
    return true
  } catch (_) {
    return false
  }
}

async function ping(timeoutMs = 800) {
  return await new Promise((resolve) => {
    const socket = net.createConnection(SOCKET_PATH)
    const timer = setTimeout(() => {
      try { socket.destroy() } catch (_) {}
      resolve(false)
    }, timeoutMs)

    socket.on('connect', () => {
      socket.write(JSON.stringify({ id: 'ping', method: 'ping', params: {} }) + '\n')
    })

    socket.on('data', (chunk) => {
      const text = chunk.toString('utf-8')
      if (text.includes('"ok":true')) {
        clearTimeout(timer)
        socket.end()
        resolve(true)
      }
    })

    socket.on('error', () => {
      clearTimeout(timer)
      resolve(false)
    })
  })
}

async function ensureDaemon() {
  if (await ping()) return { started: false }

  if (fs.existsSync(PID_PATH)) {
    const pid = Number(fs.readFileSync(PID_PATH, 'utf-8').trim())
    if (!Number.isNaN(pid) && !isPidRunning(pid)) {
      try { fs.unlinkSync(PID_PATH) } catch (_) {}
    }
  }

  if (fs.existsSync(SOCKET_PATH)) {
    try { fs.unlinkSync(SOCKET_PATH) } catch (_) {}
  }

  const child = spawn(process.execPath, [DAEMON_PATH], {
    detached: true,
    stdio: 'ignore'
  })
  child.unref()

  for (let i = 0; i < 40; i++) {
    if (await ping()) return { started: true }
    await sleep(150)
  }

  throw new Error('Keet core daemon failed to start')
}

module.exports = { ensureDaemon, SOCKET_PATH }

if (require.main === module) {
  ensureDaemon()
    .then((res) => {
      if (res.started) console.log('Keet core daemon started')
      else console.log('Keet core daemon already running')
    })
    .catch((err) => {
      console.error(err.message)
      process.exit(1)
    })
}
EOF
chmod +x "${SKILLS_ROOT}/keet-core/ensure_daemon.js"

# ---- keet-core / client.js ---------------------------------------------
cat > "${SKILLS_ROOT}/keet-core/client.js" <<'EOF'
#!/usr/bin/env node

const net = require('net')
const { ensureDaemon, SOCKET_PATH } = require('./ensure_daemon')

async function callRpc(method, params = {}) {
  await ensureDaemon()

  return await new Promise((resolve, reject) => {

    const req = {
      id: String(Date.now()) + '-' + Math.random().toString(16).slice(2),
      method,
      params
    }

    const socket = net.createConnection(SOCKET_PATH)
    let buffer = ''

    socket.on('connect', () => {
      socket.write(JSON.stringify(req) + '\n')
    })

    socket.on('data', (chunk) => {
      buffer += chunk.toString('utf-8')
      const idx = buffer.indexOf('\n')
      if (idx < 0) return

      const line = buffer.slice(0, idx)
      socket.end()

      try {
        const res = JSON.parse(line)
        if (!res.ok) return reject(new Error(res.error || 'RPC error'))
        resolve(res.result)
      } catch (err) {
        reject(err)
      }
    })

    socket.on('error', reject)
  })
}

module.exports = { callRpc }

if (require.main === module) {
  const method = process.argv[2]
  const raw = process.argv[3]

  if (!method) {
    console.error('Usage: client.js <method> [json-params]')
    process.exit(1)
  }

  let params = {}
  if (raw) {
    try {
      params = JSON.parse(raw)
    } catch (err) {
      console.error('Invalid JSON params: ' + err.message)
      process.exit(1)
    }
  }

  callRpc(method, params)
    .then((result) => console.log(JSON.stringify(result, null, 2)))
    .catch((err) => {
      console.error(err.message)
      process.exit(1)
    })
}
EOF
chmod +x "${SKILLS_ROOT}/keet-core/client.js"
log "Shared keet-core generated"

COPAW_CHANNEL_REGISTERED="not-applicable"

# ---- keet-create-room ---------------------------------------------------
cat > "${SKILLS_ROOT}/keet-create-room/SKILL.md" <<'EOF'
---
name: keet-create-room
description: Creates a Keet room and returns roomId, inviteUrl, sessionId, roomName.
---
EOF

cat > "${SKILLS_ROOT}/keet-create-room/create_room.js" <<'EOF'
#!/usr/bin/env node

const { callRpc } = require('../keet-core/client')

async function main() {
  const roomName = process.argv.slice(2).join(' ').trim() || null
  const result = await callRpc('createRoom', { roomName })
  console.log(JSON.stringify(result))
}

main().catch((err) => {
  console.error(err.message)
  process.exit(1)
})
EOF
chmod +x "${SKILLS_ROOT}/keet-create-room/create_room.js"
log "Skill keet-create-room generated"

# ---- keet-join-room -----------------------------------------------------
cat > "${SKILLS_ROOT}/keet-join-room/SKILL.md" <<'EOF'
---
name: keet-join-room
description: Joins a Keet room and keeps an always-on watch loop for inbound messages.
---
EOF

cat > "${SKILLS_ROOT}/keet-join-room/join_room.js" <<'EOF'
#!/usr/bin/env node

const readline = require('readline')
const { callRpc } = require('../keet-core/client')

function parseArgs(raw) {
  if (raw.length < 1) {
    throw new Error('Usage: keet-join-room <pear://keet/...> [--session <session-id>] [--no-watch] [--watch] [--no-stdin]')
  }

  const cfg = {
    url: raw[0],
    sessionId: null,
    watch: true,
    stdin: true,
    timeoutMs: 25000
  }

  for (let i = 1; i < raw.length; i++) {
    const token = raw[i]
    if (token === '--session' && i + 1 < raw.length) {
      cfg.sessionId = raw[i + 1]
      i++
      continue
    }
    if (token === '--no-watch') {
      cfg.watch = false
      continue
    }
    if (token === '--watch') {
      cfg.watch = true
      continue
    }
    if (token === '--no-stdin') {
      cfg.stdin = false
      continue
    }
    if (token === '--timeout-ms' && i + 1 < raw.length) {
      cfg.timeoutMs = Number(raw[i + 1])
      i++
      continue
    }
  }

  return cfg
}

async function main() {
  const cfg = parseArgs(process.argv.slice(2))
  const joined = await callRpc('joinRoom', { url: cfg.url, sessionId: cfg.sessionId })

  console.log('Joined Keet room ' + joined.roomId)
  console.log('(session: ' + joined.sessionId + ')')

  if (cfg.stdin) {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout })
    rl.on('line', async (line) => {
      const message = String(line || '').trim()
      if (!message) return
      try {
        await callRpc('sendMessage', { sessionId: joined.sessionId, message })
        console.log('[you] ' + message)
      } catch (err) {
        console.error('Send error: ' + err.message)
      }
    })
  }

  if (!cfg.watch) return

  let cursor = 0
  while (true) {
    const batch = await callRpc('fetchEvents', {
      since: cursor,
      sessionId: joined.sessionId,
      timeoutMs: cfg.timeoutMs
    })

    for (const evt of batch) {
      cursor = Math.max(cursor, evt.id)
      if (evt.type === 'message') {
        console.log('[peer] ' + evt.message)
      } else if (evt.type === 'error') {
        console.error('[error] ' + evt.message)
      }
    }
  }
}

main().catch((err) => {
  console.error(err.message)
  process.exit(1)
})
EOF
chmod +x "${SKILLS_ROOT}/keet-join-room/join_room.js"
log "Skill keet-join-room generated"

# ---- keet-send-message ---------------------------------------------------
cat > "${SKILLS_ROOT}/keet-send-message/SKILL.md" <<'EOF'
---
name: keet-send-message
description: Sends a message to an active Keet session (or auto-joins via URL + session).
---
EOF

cat > "${SKILLS_ROOT}/keet-send-message/send_message.js" <<'EOF'
#!/usr/bin/env node

const crypto = require('crypto')
const { callRpc } = require('../keet-core/client')

function parse(raw) {
  if (raw.length < 2) {
    throw new Error('Usage: keet-send-message <pear://keet/...> <msg> [--session <session-id>]')
  }

  const url = raw[0]
  let sessionId = null
  const msgParts = []

  for (let i = 1; i < raw.length; i++) {
    const token = raw[i]
    if (token === '--session' && i + 1 < raw.length) {
      sessionId = raw[i + 1]
      i++
      continue
    }
    msgParts.push(token)
  }

  const message = msgParts.join(' ').trim()
  if (!message) throw new Error('Message cannot be empty')

  return {
    url,
    sessionId: sessionId || crypto.randomUUID(),
    message
  }
}

async function main() {
  const cfg = parse(process.argv.slice(2))
  await callRpc('joinRoom', { url: cfg.url, sessionId: cfg.sessionId })
  const result = await callRpc('sendMessage', {
    sessionId: cfg.sessionId,
    message: cfg.message
  })
  console.log('Message sent (session: ' + result.sessionId + ')')
}

main().catch((err) => {
  console.error(err.message)
  process.exit(1)
})
EOF
chmod +x "${SKILLS_ROOT}/keet-send-message/send_message.js"
log "Skill keet-send-message generated"

# ---- keet-leave-room -----------------------------------------------------
cat > "${SKILLS_ROOT}/keet-leave-room/SKILL.md" <<'EOF'
---
name: keet-leave-room
description: Leaves an active Keet session.
---
EOF

cat > "${SKILLS_ROOT}/keet-leave-room/leave_room.js" <<'EOF'
#!/usr/bin/env node

const { callRpc } = require('../keet-core/client')

async function main() {
  const sessionId = process.argv[2]
  if (!sessionId) {
    throw new Error('Usage: keet-leave-room <session-id>')
  }
  const result = await callRpc('leaveRoom', { sessionId })
  console.log(JSON.stringify(result))
}

main().catch((err) => {
  console.error(err.message)
  process.exit(1)
})
EOF
chmod +x "${SKILLS_ROOT}/keet-leave-room/leave_room.js"
log "Skill keet-leave-room generated"

# ---- keet-list-sessions --------------------------------------------------
cat > "${SKILLS_ROOT}/keet-list-sessions/SKILL.md" <<'EOF'
---
name: keet-list-sessions
description: Lists active always-on Keet sessions managed by the shared core daemon.
---
EOF

cat > "${SKILLS_ROOT}/keet-list-sessions/list_sessions.js" <<'EOF'
#!/usr/bin/env node

const { callRpc } = require('../keet-core/client')

async function main() {
  const result = await callRpc('listSessions', {})
  console.log(JSON.stringify(result))
}

main().catch((err) => {
  console.error(err.message)
  process.exit(1)
})
EOF
chmod +x "${SKILLS_ROOT}/keet-list-sessions/list_sessions.js"
log "Skill keet-list-sessions generated"

# -------------------------------------------------------------------------
# 6️⃣ Create platform adapters (equivalent command surface)
# -------------------------------------------------------------------------

# ---- CoPaw (custom_channels) --------------------------------------------
if [[ "$AGENT_TYPE" == "copaw" ]]; then
  mkdir -p "${CHANNEL_ROOT}"

  cat > "${CHANNEL_ROOT}/keet_channel.py" <<EOF
"""
CoPaw/QwenPaw channel adapter for Keet always-on core.

Equivalent commands with other runtimes:
  - create
  - join (always-on watch loop)
  - send
  - leave
  - sessions
"""

import subprocess
from copaw.channels.base import BaseChannel  # type: ignore

NODE_BIN = "${NODE_BIN}"
SKILLS_ROOT = "${SKILLS_ROOT}"

class KeetChannel(BaseChannel):
    name = "keet"
    description = "Keet P2P chat (always-on core)"

    def _run(self, script: str, *args):
        cmd = [NODE_BIN, f"{SKILLS_ROOT}/{script}", *args]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return result.stdout.strip()

    async def create(self, ctx, *room_name_parts):
        out = self._run("keet-create-room/create_room.js", *room_name_parts)
        await ctx.send(out)

    async def join(self, ctx, url: str, *flags):
        proc = subprocess.Popen(
            [
                NODE_BIN,
                f"{SKILLS_ROOT}/keet-join-room/join_room.js",
                url,
                *flags,
                "--watch",
                "--no-stdin"
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        for line in proc.stdout:
            await ctx.send(line.rstrip())

    async def send(self, ctx, url: str, *msg_and_flags):
        out = self._run("keet-send-message/send_message.js", url, *msg_and_flags)
        await ctx.send(out)

    async def leave(self, ctx, session_id: str):
        out = self._run("keet-leave-room/leave_room.js", session_id)
        await ctx.send(out)

    async def sessions(self, ctx):
        out = self._run("keet-list-sessions/list_sessions.js")
        await ctx.send(out)

channel = KeetChannel()
EOF

  if copaw channels add keet >/dev/null 2>&1; then
    COPAW_CHANNEL_REGISTERED="yes"
    log "CoPaw channel 'keet' generated and registered"
  else
    COPAW_CHANNEL_REGISTERED="no"
    warn "CoPaw channel auto-registration failed. Register manually with: copaw channels add keet"
  fi
fi

# ---- Hermes-agent --------------------------------------------------------
if [[ "$AGENT_TYPE" == "hermes" ]]; then
  mkdir -p "${PLUGIN_ROOT}"
  HERMES_PLUGIN_DIR="${PLUGIN_ROOT}/keet-dropin"
  mkdir -p "${HERMES_PLUGIN_DIR}"

  cat > "${HERMES_PLUGIN_DIR}/plugin.yaml" <<'EOF'
name: keet-dropin
version: "0.1"
description: Keet bridge plugin for Hermes-agent using the shared Node keet-core.
EOF

  cat > "${HERMES_PLUGIN_DIR}/__init__.py" <<EOF
"""Hermes plugin: Keet drop-in tools backed by the shared Node keet-core."""

import json
import os
import subprocess
from typing import Any, Dict, List, Optional

NODE_BIN = "${NODE_BIN}"
SKILLS_ROOT = "${SKILLS_ROOT}"


def _run(script_rel: str, *args: str) -> str:
    cmd = [NODE_BIN, os.path.join(SKILLS_ROOT, script_rel), *args]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return result.stdout.strip()


def _schema(name: str, description: str, properties: Dict[str, Any], required: Optional[List[str]] = None) -> Dict[str, Any]:
    return {
        "name": name,
        "description": description,
        "parameters": {
            "type": "object",
            "properties": properties,
            "required": required or [],
        },
    }


def _tool_create(params: Dict[str, Any]) -> Dict[str, Any]:
    room_name = str(params.get("room_name", "")).strip()
    args = [room_name] if room_name else []
    out = _run("keet-create-room/create_room.js", *args)
    return json.loads(out)


def _tool_join(params: Dict[str, Any]) -> Dict[str, Any]:
    url = str(params.get("url", "")).strip()
    if not url:
        raise ValueError("url is required")

    args = [url]
    session_id = str(params.get("session_id", "")).strip()
    if session_id:
        args += ["--session", session_id]

    # Non-blocking by default for tool usage in Hermes.
    args += ["--no-watch", "--no-stdin"]

    out = _run("keet-join-room/join_room.js", *args)
    return {"status": "joined", "detail": out}


def _tool_send(params: Dict[str, Any]) -> Dict[str, Any]:
    url = str(params.get("url", "")).strip()
    message = str(params.get("message", "")).strip()
    if not url:
        raise ValueError("url is required")
    if not message:
        raise ValueError("message is required")

    args = [url, message]
    session_id = str(params.get("session_id", "")).strip()
    if session_id:
        args += ["--session", session_id]

    out = _run("keet-send-message/send_message.js", *args)
    return {"status": "sent", "detail": out}


def _tool_leave(params: Dict[str, Any]) -> Dict[str, Any]:
    session_id = str(params.get("session_id", "")).strip()
    if not session_id:
        raise ValueError("session_id is required")
    out = _run("keet-leave-room/leave_room.js", session_id)
    return json.loads(out)


def _tool_sessions(_params: Dict[str, Any]) -> List[Dict[str, Any]]:
    out = _run("keet-list-sessions/list_sessions.js")
    return json.loads(out)


def register(ctx):
    ctx.register_tool(
        "keet_create_room",
        _schema(
            "keet_create_room",
            "Create a Keet room and return room metadata.",
            {
                "room_name": {
                    "type": "string",
                    "description": "Optional room label.",
                }
            },
            [],
        ),
        _tool_create,
    )

    ctx.register_tool(
        "keet_join_room",
        _schema(
            "keet_join_room",
            "Join a Keet room and keep a persistent session in the shared daemon.",
            {
                "url": {
                    "type": "string",
                    "description": "Keet invite URL (pear://keet/<room-id>).",
                },
                "session_id": {
                    "type": "string",
                    "description": "Optional stable session id.",
                },
            },
            ["url"],
        ),
        _tool_join,
    )

    ctx.register_tool(
        "keet_send_message",
        _schema(
            "keet_send_message",
            "Send a message through Keet using url/message and optional session id.",
            {
                "url": {
                    "type": "string",
                    "description": "Keet invite URL (pear://keet/<room-id>).",
                },
                "message": {
                    "type": "string",
                    "description": "Message to send.",
                },
                "session_id": {
                    "type": "string",
                    "description": "Optional stable session id.",
                },
            },
            ["url", "message"],
        ),
        _tool_send,
    )

    ctx.register_tool(
        "keet_leave_room",
        _schema(
            "keet_leave_room",
            "Leave an active Keet session.",
            {
                "session_id": {
                    "type": "string",
                    "description": "Session identifier to stop.",
                }
            },
            ["session_id"],
        ),
        _tool_leave,
    )

    ctx.register_tool(
        "keet_list_sessions",
        _schema(
            "keet_list_sessions",
            "List active Keet sessions managed by the shared daemon.",
            {},
            [],
        ),
        _tool_sessions,
    )
EOF

  # Backward-compatible helper module for previous installer outputs.
  cat > "${PLUGIN_ROOT}/keet_plugin.py" <<EOF
"""
Hermes-agent plugin for Keet always-on core.

Exports:
  - keet_create(room_name=None)
  - keet_join(url, session_id=None, watch=True)
  - keet_send(url, message, session_id=None)
  - keet_leave(session_id)
  - keet_sessions()
"""

import json
import os
import subprocess

NODE_BIN = "${NODE_BIN}"
SKILLS_ROOT = "${SKILLS_ROOT}"

def _run(script_path: str, *args) -> str:
    cmd = [NODE_BIN, script_path, *args]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return result.stdout.strip()

def keet_create(room_name: str = None) -> dict:
    args = [room_name] if room_name else []
    out = _run(os.path.join(SKILLS_ROOT, "keet-create-room", "create_room.js"), *args)
    return json.loads(out)

def keet_join(url: str, session_id: str = None, watch: bool = True) -> None:
    args = [url]
    if session_id:
      args += ["--session", session_id]
    if watch:
      args += ["--watch", "--no-stdin"]
    else:
      args += ["--no-watch", "--no-stdin"]

    proc = subprocess.Popen(
        [NODE_BIN, os.path.join(SKILLS_ROOT, "keet-join-room", "join_room.js"), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    for line in proc.stdout:
        print(line.rstrip())  # Hermes captures stdout

def keet_send(url: str, message: str, session_id: str = None) -> str:
    args = [url, message]
    if session_id:
      args += ["--session", session_id]
    return _run(os.path.join(SKILLS_ROOT, "keet-send-message", "send_message.js"), *args)

def keet_leave(session_id: str) -> dict:
    out = _run(os.path.join(SKILLS_ROOT, "keet-leave-room", "leave_room.js"), session_id)
    return json.loads(out)

def keet_sessions() -> list:
    out = _run(os.path.join(SKILLS_ROOT, "keet-list-sessions", "list_sessions.js"))
    return json.loads(out)
EOF

  log "Hermes plugin written -> ${HERMES_PLUGIN_DIR}/"
  log "Hermes legacy helper retained -> ${PLUGIN_ROOT}/keet_plugin.py"
fi

# ---- OpenClaw ------------------------------------------------------------
if [[ "$AGENT_TYPE" == "openclaw" ]]; then
  mkdir -p "${PLUGIN_ROOT}"

  cat > "${PLUGIN_ROOT}/keet-channel.ts" <<EOF
import { createChatChannelPlugin } from "openclaw/plugin-sdk/channel-core";
import { spawn, type ChildProcess } from "child_process";
import { randomUUID } from "crypto";
import path from "path";

const NODE_BIN = "${NODE_BIN}";
const SKILLS_ROOT = "${SKILLS_ROOT}";

const watchers = new Map<string, ChildProcess>();

function waitForNoEarlyExit(proc: ChildProcess, timeoutMs = 1200): Promise<void> {
  return new Promise((resolve, reject) => {
    let settled = false;

    const cleanup = () => {
      clearTimeout(timer);
      proc.off("error", onError);
      proc.off("close", onClose);
    };

    const onError = (err: Error) => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(err);
    };

    const onClose = (code: number | null) => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(new Error("joinRoom exited early with code " + String(code)));
    };

    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve();
    }, timeoutMs);

    proc.once("error", onError);
    proc.once("close", onClose);
  });
}

function runScript(script: string, args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    const proc = spawn(NODE_BIN, [path.join(SKILLS_ROOT, script), ...args], {
      stdio: ["ignore", "pipe", "pipe"]
    });

    let output = "";
    let errOut = "";

    proc.stdout.on("data", (data) => { output += data.toString(); });
    proc.stderr.on("data", (data) => { errOut += data.toString(); });

    proc.on("close", (code) => {
      if (code === 0) resolve(output.trim());
      else reject(new Error("Script failed (" + script + "): " + errOut.trim()));
    });
  });
}

export const keetChannel = createChatChannelPlugin({
  name: "keet",
  description: "Keet P2P chat (always-on core)",

  async createRoom(name?: string) {
    const out = await runScript("keet-create-room/create_room.js", name ? [name] : []);
    return out;
  },

  async joinRoom(url: string, sessionId?: string) {
    const sid = sessionId || randomUUID();

    const proc = spawn(
      NODE_BIN,
      [
        path.join(SKILLS_ROOT, "keet-join-room/join_room.js"),
        url,
        "--session",
        sid,
        "--watch",
        "--no-stdin"
      ],
      { stdio: ["ignore", "pipe", "pipe"] }
    );

    proc.stdout.on("data", (data) => {
      console.log("[keet:" + sid + "] " + data.toString().trim());
    });
    proc.stderr.on("data", (data) => {
      console.error("[keet:" + sid + "] " + data.toString().trim());
    });
    proc.on("close", () => {
      watchers.delete(sid);
    });

    await waitForNoEarlyExit(proc);

    watchers.set(sid, proc);
    return JSON.stringify({ status: "joined", sessionId: sid });
  },

  async sendMessage(url: string, message: string, sessionId?: string) {
    const args = [url, message];
    if (sessionId) args.push("--session", sessionId);
    return await runScript("keet-send-message/send_message.js", args);
  },

  async leaveRoom(sessionId: string) {
    const watcher = watchers.get(sessionId);
    if (watcher) {
      watcher.kill("SIGTERM");
      watchers.delete(sessionId);
    }
    return await runScript("keet-leave-room/leave_room.js", [sessionId]);
  },

  async listSessions() {
    return await runScript("keet-list-sessions/list_sessions.js", []);
  }
});

export default keetChannel;
EOF

  log "OpenClaw plugin written -> ${PLUGIN_ROOT}/keet-channel.ts"
fi

# -------------------------------------------------------------------------
# 7️⃣ Print usage guide
# -------------------------------------------------------------------------
echo ""
echo "============================================================================="
echo "              Keet Drop-in Installation Complete (Always-on Core)"
echo "============================================================================="
echo ""
echo "Target installed: $AGENT_TYPE"
echo "Workspace: $WORKSPACE"
echo "Node binary: $NODE_BIN"
echo "Rooms directory: $ROOMS_DIR"
echo "Reset persisted state: $RESET_STATE"
if [[ "$RESET_STATE" == "true" ]]; then
  echo "State backup suffix: ${RESET_BACKUP_SUFFIX}"
fi
if [[ "$AGENT_TYPE" == "hermes" ]]; then
  echo "Hermes plugin: ${PLUGIN_ROOT}/keet_plugin.py"
  echo "Hermes plugin dir: ${PLUGIN_ROOT}/keet-dropin"
fi
echo ""
echo "Generated shared core:"
echo "  - keet-core/daemon.js         (persistent room presence + event stream)"
echo "  - keet-core/client.js         (RPC client)"
echo ""
echo "Generated skills:"
echo "  - keet-create-room            (create room metadata)"
echo "  - keet-join-room              (join + always-on watch loop)"
echo "  - keet-send-message           (send into session)"
echo "  - keet-leave-room             (leave session)"
echo "  - keet-list-sessions          (list active sessions)"
echo ""
echo "Usage examples:"
echo "  # Create a room"
echo "  $NODE_BIN ${SKILLS_ROOT}/keet-create-room/create_room.js 'My Room'"
echo ""
echo "  # Join and stay in the channel"
echo "  $NODE_BIN ${SKILLS_ROOT}/keet-join-room/join_room.js pear://keet/<room-id> --session <session-id> --watch"
echo ""
echo "  # Send to an active session"
echo "  $NODE_BIN ${SKILLS_ROOT}/keet-send-message/send_message.js pear://keet/<room-id> 'Hello!' --session <session-id>"
echo ""
echo "  # Leave the session"
echo "  $NODE_BIN ${SKILLS_ROOT}/keet-leave-room/leave_room.js <session-id>"
echo ""
if [[ "$AGENT_TYPE" == "hermes" ]]; then
  echo "Hermes-focused operational notes:"
  echo "  - Hermes plugins are loaded from ~/.hermes/plugins/<plugin-dir>/ with plugin.yaml + __init__.py."
  echo "  - This installer creates ~/.hermes/plugins/keet-dropin/ and keeps keet_plugin.py as legacy helper."
  echo "  - This installer uses Node deps: blind-pairing-core, hypercore-id-encoding,"
  echo "    hypercore, random-access-file, z32 (not an official 'keet' npm package)."
  echo "  - If dependencies are missing or broken, reinstall with:"
  echo "    $NPM_BIN install blind-pairing-core hypercore-id-encoding hypercore random-access-file z32"
  echo "  - After install, verify plugin discovery with: hermes plugins list"
  echo "  - If Hermes auto-repair rewrites plugin state, restore this directory:"
  echo "    ${PLUGIN_ROOT:-<not-applicable>}/keet-dropin"
fi

if [[ "$AGENT_TYPE" == "nanobot" ]]; then
  echo "NanoBot operational notes:"
  echo "  - Skills were installed under: ${SKILLS_ROOT}"
  echo "  - Rooms state is persisted under: ${ROOMS_DIR}"
  echo "  - Use NanoBot skill invocations such as: nanobot agent -m \"keet-list-sessions\""
fi

if [[ "$AGENT_TYPE" == "copaw" ]]; then
  echo "CoPaw/QwenPaw operational notes:"
  echo "  - Custom channel file: ${CHANNEL_ROOT}/keet_channel.py"
  echo "  - Channel registration status: ${COPAW_CHANNEL_REGISTERED}"
  if [[ "$COPAW_CHANNEL_REGISTERED" == "no" ]]; then
    echo "  - Manual registration command: copaw channels add keet"
  fi
  echo "  - Rooms state is persisted under: ${ROOMS_DIR}"
fi

if [[ "$AGENT_TYPE" == "openclaw" ]]; then
  echo "OpenClaw operational notes:"
  echo "  - Plugin file generated at: ${PLUGIN_ROOT}/keet-channel.ts"
  echo "  - Ensure your OpenClaw runtime loads this plugin according to your plugin registry/import flow."
  echo "  - Rooms state is persisted under: ${ROOMS_DIR}"
fi
echo ""
echo "Persistent storage: $ROOMS_DIR"
echo "============================================================================="
