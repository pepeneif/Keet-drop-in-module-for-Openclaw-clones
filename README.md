# 📦 Keet Drop-in Module

**Runtime-agnostic Keet integration for OpenClaw-family agents:** NanoBot, CoPaw/QwenPaw, Hermes-agent, and OpenClaw.

This version installs a **shared always-on Keet core** and now prioritizes **Hermes-first correctness** in mixed environments where multiple OpenClaw-family runtimes may coexist.

---

## 1) Reasons why Keet.io is a good choice for a channel with OpenClaw and OpenClaw clones

1. **Decentralized and secure messaging**: Keet.io is a decentralized messaging platform that allows users to communicate securely and privately without relying on a centralized server. This is especially important for OpenClaw and its clone users, as it enables them to maintain control over their data and communications.

2. **Efficient room management**: Keet's room management is ideal for maintaining multiple active chat sessions simultaneously, each as a separate session for the agent.

3. **Cross-machine collaboration**: With Keet, two or more agents running on separate machines can connect to communicate and collaborate.

4. **Easy‑to‑use clients and increased adoption**: Keet.io has desktop and mobile clients that are very easy to install and use. With a mechanism like this enabling users to interact with agents securely, efficiently, and intuitively, the adoption of Keet.io as a communication platform is likely to increase—both for human‑to‑agent communication and for humans communicating with other humans, preferring Keet.io over Telegram, WhatsApp, Discord, etc.

---
## 2) What this module provides

| Capability | How it works |
|---|---|
| Shared always-on core | Installer generates `skills/keet-core/daemon.js` + `skills/keet-core/client.js` and exposes a JSON-RPC command/event API over a local Unix socket. |
| Long-lived room presence | `joinRoom` creates persistent sessions that remain active in the daemon (not one-shot send only). |
| Bidirectional flow | Inbound room traffic is emitted as events; adapters can watch and relay to their platform channel. |
| Session lifecycle | Create / join / send / leave / list sessions are all first-class commands. |
| Persistent state | Session metadata and storage live under a target-specific rooms path (Hermes uses `~/.hermes/rooms/`) and are restored on daemon restart. |
| Equivalent adapters | NanoBot (skills), CoPaw channel, Hermes plugin, and OpenClaw plugin call the same shared Node core and same command semantics. |

---

## 3) Installer behavior

Recommended run (explicit Hermes target):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pepeneif/Keet-drop-in-module-for-Openclaw-clones/main/install_keet_dropin.sh) --target hermes
```

The installer script [`install_keet_dropin.sh`](install_keet_dropin.sh) does the following:

1. Resolves target explicitly (`--target hermes|nanobot|copaw|openclaw|auto`) or interactive menu (default: Hermes).
2. Uses auto-detection **only** when target is explicitly set to `auto`.
3. Fails fast in non-interactive mode if `--target` is missing.
4. Installs Node `v20.12.0` inside the selected workspace (if absent).
5. Installs npm deps: `blind-pairing-core`, `hypercore-id-encoding`, `hypercore`, `random-access-file`.
5. Creates persistent storage in the selected runtime path (Hermes: `~/.hermes/rooms/` + `~/.hermes/rooms/sessions/`).
6. Generates shared Keet core files:
   - `skills/keet-core/daemon.js`
   - `skills/keet-core/ensure_daemon.js`
   - `skills/keet-core/client.js`
7. Generates common skills:
   - `keet-create-room`
   - `keet-join-room`
   - `keet-send-message`
   - `keet-leave-room`
   - `keet-list-sessions`
8. Generates runtime adapter for CoPaw / Hermes / OpenClaw when relevant.

### Target-selection examples

```bash
# Interactive menu (default selection = Hermes)
bash install_keet_dropin.sh

# Explicit non-interactive Hermes install
bash install_keet_dropin.sh --target hermes

# Explicit non-interactive NanoBot install
bash install_keet_dropin.sh --target nanobot

# Explicit non-interactive CoPaw/QwenPaw install
bash install_keet_dropin.sh --target copaw

# Explicit non-interactive OpenClaw install (from OpenClaw workspace root)
bash install_keet_dropin.sh --target openclaw

# Explicit auto mode (fails if multiple runtimes are detected)
bash install_keet_dropin.sh --target auto

# Piped install (non-interactive): target is required
curl -fsSL https://raw.githubusercontent.com/pepeneif/Keet-drop-in-module-for-Openclaw-clones/main/install_keet_dropin.sh | bash -s -- --target hermes
```

### Hermes plugin output (current)

The installer writes a Hermes plugin directory compatible with Hermes plugin discovery:

```text
~/.hermes/plugins/keet-dropin/
├─ plugin.yaml
└─ __init__.py
```

It also writes `~/.hermes/plugins/keet_plugin.py` as a backward-compatible helper for previous installer outputs.

### Cross-target hardening notes

- **NanoBot**
  - Validates `nanobot` binary presence and warns if CLI help probing fails.
  - Uses `~/.nanobot/workspace/skills/` for skills and `~/.nanobot/rooms/` for persistent rooms.

- **CoPaw/QwenPaw**
  - Requires `copaw channels` command surface.
  - Writes adapter to `~/.copaw/custom_channels/keet_channel.py`.
  - Attempts `copaw channels add keet` and reports explicit registration status.

- **OpenClaw**
  - Requires execution from OpenClaw workspace root (`./src` + `./package.json`).
  - Verifies workspace write access before generating plugin.
  - Warns if `package.json` does not appear to reference OpenClaw.

---

## 4) Command model (same across all runtimes)

### `keet-create-room`

Creates room metadata and returns JSON:

```json
{
  "roomId": "...",
  "inviteUrl": "pear://keet/...",
  "sessionId": "...",
  "roomName": "..."
}
```

### `keet-join-room`

Joins and keeps watching events (always-on behavior):

```bash
keet-join-room <pear://keet/...> [--session <id>] [--watch|--no-watch] [--no-stdin]
```

### `keet-send-message`

Sends to an active session (or joins first if needed):

```bash
keet-send-message <pear://keet/...> <message> [--session <id>]
```

### `keet-leave-room`

Stops one active session:

```bash
keet-leave-room <session-id>
```

### `keet-list-sessions`

Lists active daemon sessions:

```bash
keet-list-sessions
```

---

## 5) Platform usage examples

### NanoBot

```bash
nanobot agent -m "keet-create-room MyRoom"
nanobot agent -m "keet-join-room pear://keet/<id> --session <sid> --watch"
nanobot agent -m "keet-send-message pear://keet/<id> hello --session <sid>"
nanobot agent -m "keet-list-sessions"
nanobot agent -m "keet-leave-room <sid>"
```

### CoPaw / QwenPaw

```bash
copaw channel keet create MyRoom
copaw channel keet join pear://keet/<id> --session <sid>
copaw channel keet send pear://keet/<id> hello --session <sid>
copaw channel keet sessions
copaw channel keet leave <sid>
```

### Hermes-agent

```bash
hermes channel keet create MyRoom
hermes channel keet join pear://keet/<id> --session <sid>
hermes channel keet send pear://keet/<id> hello --session <sid>
hermes channel keet sessions
hermes channel keet leave <sid>
```

### OpenClaw

```bash
openclaw channel keet create MyRoom
openclaw channel keet join pear://keet/<id> --session <sid>
openclaw channel keet send pear://keet/<id> hello --session <sid>
openclaw channel keet list-sessions
openclaw channel keet leave-room <sid>
```

---

## 6) Hermes-first troubleshooting (mixed runtime machines)

If your machine has multiple runtimes (for example Hermes + NanoBot), always use explicit target selection:

```bash
bash install_keet_dropin.sh --target hermes
```

Checklist:

1. Confirm plugin files exist:
   - `~/.hermes/plugins/keet-dropin/plugin.yaml`
   - `~/.hermes/plugins/keet-dropin/__init__.py`
2. Confirm rooms path is Hermes-specific:
   - `~/.hermes/rooms/`
3. Confirm Hermes sees plugins:
   - `hermes plugins list`
4. If dependencies are damaged, reinstall them in Hermes workspace:
   - `~/.hermes/node-v20.12.0-<platform>/bin/npm install blind-pairing-core hypercore-id-encoding hypercore random-access-file`

---

## 7) Architecture summary

Shared core generated by [`install_keet_dropin.sh`](install_keet_dropin.sh):

- **Daemon** (`daemon.js`): owns active session map, room streams, event queue, state persistence.
- **RPC API** (`client.js`): `createRoom`, `joinRoom`, `sendMessage`, `leaveRoom`, `listSessions`, `fetchEvents`.
- **Adapter contract** (all runtimes):
  - create
  - join (watch loop)
  - send
  - leave
  - sessions

This ensures Keet behaves like a real long-lived channel integration rather than a one-message-only transport.

---

## 8) Verification matrix

| Target | Install command | Expected rooms path | Expected adapter output |
|---|---|---|---|
| Hermes-agent | `bash install_keet_dropin.sh --target hermes` | `~/.hermes/rooms/` | `~/.hermes/plugins/keet-dropin/` + legacy `~/.hermes/plugins/keet_plugin.py` |
| NanoBot | `bash install_keet_dropin.sh --target nanobot` | `~/.nanobot/rooms/` | `~/.nanobot/workspace/skills/` |
| CoPaw/QwenPaw | `bash install_keet_dropin.sh --target copaw` | `~/.copaw/rooms/` | `~/.copaw/custom_channels/keet_channel.py` + registration status reported by installer |
| OpenClaw | `bash install_keet_dropin.sh --target openclaw` | `~/.openclaw/rooms/` | `./src/plugins/keet-channel/keet-channel.ts` (run from OpenClaw repo root) |

---

## 9) Repository layout

```text
Keet-drop-in-module-for-Openclaw-clones/
├─ install_keet_dropin.sh
├─ run.sh
├─ package.json
└─ README.md
```

Generated runtime assets are written at install time into the detected workspace.

---

## 10) License

MIT for this repository. Upstream dependencies keep their own licenses.
