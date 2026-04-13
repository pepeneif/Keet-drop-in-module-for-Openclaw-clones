#!/usr/bin/env bash
# =============================================================================
# install_keet_dropin.sh
# =============================================================================
#   - Detects Nanobot, CoPaw/QwenPaw, Hermes-agent, or OpenClaw.
#   - Installs Node v20 inside the detected workspace (if missing).
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
# 1️⃣ Detect which OpenClaw-family agent is running
# -------------------------------------------------------------------------
AGENT_TYPE="unknown"
if command -v nanobot >/dev/null 2>&1; then AGENT_TYPE="nanobot"; fi
if command -v copaw >/dev/null 2>&1; then AGENT_TYPE="copaw"; fi
if command -v hermes-agent >/dev/null 2>&1; then AGENT_TYPE="hermes"; fi
if [[ -d "$(pwd)/src" && -f "$(pwd)/package.json" ]]; then AGENT_TYPE="openclaw"; fi

if [[ "$AGENT_TYPE" == "unknown" ]]; then
  error "No agent binary found (nanobot / copaw / hermes-agent) nor OpenClaw workspace. Aborting."
fi
log "Agent detected: $AGENT_TYPE"

# -------------------------------------------------------------------------
# 2️⃣ Define workspace paths based on the detected agent
# -------------------------------------------------------------------------
case "$AGENT_TYPE" in
  nanobot)
    WORKSPACE="${HOME}/.nanobot/workspace"
    SKILLS_ROOT="${WORKSPACE}/skills"
    ;;
  copaw)
    WORKSPACE="${HOME}/.copaw"
    SKILLS_ROOT="${WORKSPACE}/skills"
    CHANNEL_ROOT="${WORKSPACE}/custom_channels"
    ;;
  hermes)
    WORKSPACE="${HOME}/.hermes"
    SKILLS_ROOT="${WORKSPACE}/skills"
    PLUGIN_ROOT="${WORKSPACE}/plugins"
    ;;
  openclaw)
    WORKSPACE="$(pwd)"
    SKILLS_ROOT="${WORKSPACE}/skills"
    PLUGIN_ROOT="${WORKSPACE}/src/plugins/keet-channel"
    ;;
esac

mkdir -p "$WORKSPACE"
mkdir -p "$SKILLS_ROOT"
log "Workspace -> $WORKSPACE"

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
"$NPM_BIN" install blind-pairing-core hypercore-id-encoding hypercore random-access-file || error "Failed to install npm dependencies"
log "Dependencies installed"

# -------------------------------------------------------------------------
# 5️⃣ Always create persistent folders under ~/.nanobot/rooms
# -------------------------------------------------------------------------
ROOMS_DIR="${HOME}/.nanobot/rooms"
mkdir -p "$ROOMS_DIR"
mkdir -p "${ROOMS_DIR}/sessions"
log "Persistent rooms folder -> $ROOMS_DIR"

# -------------------------------------------------------------------------
# 6️⃣ Generate shared Keet core + skills (common to all agents)
# -------------------------------------------------------------------------
mkdir -p "${SKILLS_ROOT}/keet-core"
mkdir -p "${SKILLS_ROOT}/keet-create-room"
mkdir -p "${SKILLS_ROOT}/keet-join-room"
mkdir -p "${SKILLS_ROOT}/keet-send-message"
mkdir -p "${SKILLS_ROOT}/keet-leave-room"
mkdir -p "${SKILLS_ROOT}/keet-list-sessions"

# ---- keet-core / daemon.js ---------------------------------------------
cat > "${SKILLS_ROOT}/keet-core/daemon.js" <<'EOF'
#!/usr/bin/env node

const fs = require('fs')
const os = require('os')
const path = require('path')
const net = require('net')
const crypto = require('crypto')
const hypercore = require('hypercore')
const RAF = require('random-access-file')
const { createInvite } = require('blind-pairing-core')
const { encode, decode } = require('hypercore-id-encoding')

const BASE_DIR = path.join(os.homedir(), '.nanobot', 'rooms')
const SOCKET_PATH = path.join(BASE_DIR, 'keet-core.sock')
const PID_PATH = path.join(BASE_DIR, 'keet-core.pid')
const STATE_PATH = path.join(BASE_DIR, 'keet-state.json')
const STORAGE_DIR = path.join(BASE_DIR, 'sessions')

fs.mkdirSync(STORAGE_DIR, { recursive: true })

const sessions = new Map()
let nextEventId = 1
const events = []
const waiters = new Set()

function normalizeInvite(url) {
  const m = String(url || '').trim().match(/^pear:\/\/keet\/([^/\s]+)$/)
  if (!m) throw new Error('Invalid Keet invite URL. Expected pear://keet/<roomId>')
  const roomId = m[1]
  return { roomId, inviteUrl: 'pear://keet/' + roomId }
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
  const discoveryKey = decode(invite.roomId)
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
  const roomName = String(params.roomName || '').trim() || crypto.randomUUID()
  const sessionId = crypto.randomUUID()
  const key = crypto.randomBytes(32)
  const { discoveryKey } = createInvite(key)
  const roomId = encode(discoveryKey)
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
    console.log('Keet core daemon listening on ' + SOCKET_PATH)
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
cat > "${SKILLS_ROOT}/keet-core/ensure_daemon.js" <<'EOF'
#!/usr/bin/env node

const fs = require('fs')
const os = require('os')
const path = require('path')
const net = require('net')
const { spawn } = require('child_process')

const BASE_DIR = path.join(os.homedir(), '.nanobot', 'rooms')
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
# 7️⃣ Create platform adapters (equivalent command surface)
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

  copaw channels add keet >/dev/null 2>&1 || true
  log "CoPaw channel 'keet' generated and registered"
fi

# ---- Hermes-agent --------------------------------------------------------
if [[ "$AGENT_TYPE" == "hermes" ]]; then
  mkdir -p "${PLUGIN_ROOT}"

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

  log "Hermes plugin written -> ${PLUGIN_ROOT}/keet_plugin.py"
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
# 8️⃣ Print usage guide
# -------------------------------------------------------------------------
echo ""
echo "============================================================================="
echo "              Keet Drop-in Installation Complete (Always-on Core)"
echo "============================================================================="
echo ""
echo "Agent detected: $AGENT_TYPE"
echo "Workspace: $WORKSPACE"
echo "Node binary: $NODE_BIN"
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
echo "Persistent storage: $ROOMS_DIR"
echo "============================================================================="
