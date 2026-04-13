# 📦 Keet Drop‑in Module

**A self‑contained, “zero‑touch” plug‑in that adds full Keet P2P chat support to any OpenClaw‑family agent (Nanobot, CoPaw/QwenPaw, Hermes‑agent, OpenClaw).**

---

## 1. What the module does

| Feature | Description |
|--------|-------------|
| **Single installer script** (`install_keet_dropin.sh`) | Detects the running agent, installs Node v20 (once), pulls the required NPM packages, creates the three Keet skills (`keet‑create‑room`, `keet‑join‑room`, `keet‑send‑message`) and registers the appropriate channel plug‑ins. |
| **`keet‑create‑room`** | It accepts an optional **room name**. If you omit the name a UUID is generated and used as the name (so the script always receives a valid argument). The command returns a JSON with `roomId`, `inviteUrl`, `sessionId` **and** `roomName`. |
| **`keet‑join‑room`** | Lets the agent join a Keet room that is already created. |
| **`keet‑send‑message`** | Sends a message to the room where the Agent is in. |
| **Persistent history** | A permanent folder `~/.nanobot/rooms/` is created. Each room’s history is stored in a file `<roomId>_<sessionId>.dat` using `random‑access‑file`. The history survives agent restarts and is automatically loaded when you re‑join the same `<roomId>` + `<sessionId>`. |
| **Supports every OpenClaw‑derived platform** | <ul><li>**Nanobot** – skills live in `skills/` and are auto‑discovered.</li><li>**CoPaw / QwenPaw** – a Python `custom_channels/keet_channel.py` subclass of `BaseChannel` is generated and registered with `copaw channels add keet`.</li><li>**Hermes‑agent** – a Python plug‑in `~/.hermes/plugins/keet_plugin.py` exposing `keet_create`, `keet_join`, `keet_send`.</li><li>**OpenClaw** – a TypeScript channel plug‑in (`src/plugins/keet-channel/keet-channel.ts`) built on the SDK’s `createChatChannelPlugin` function, automatically loaded by the OpenClaw catalog.</li></ul> |
| **Zero manual configuration** | All files are written to the agent’s workspace, permissions (`chmod +x`) are set, and the appropriate registration commands are run automatically. After the one‑liner the agent is ready to use Keet. |
| **Full‑stack, drop‑in** | The repository contains **only** the installer script and this README – no extra assets, no need to edit the core of the agent. |

---

## 2. Repository layout

```
keet-dropin-module/
├─ install_keet_dropin.sh ← the all‑in‑one installer (the only file you need to run)
├─ run.sh                 ← tiny wrapper that simply calls the installer after a git clone
├─ package.json           ← npm manifest; exposes the installer as a binary (`keet-dropin`)
└─ README.md              ← you are reading it right now
```

All other files (the generated skills, channel plug‑ins, etc.) are created **at install time** inside the agent’s workspace (`~/.nanobot/workspace`, `~/.copaw`, `~/.hermes` or OpenClaw’s `src/` tree).

---

## 3. Installation – one command, no human interaction

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pepeneif/keet-dropin-module/main/install_keet_dropin.sh)
```

*The script will:*  
1. Detect whether it is running under **Nanobot**, **CoPaw**, **Hermes‑agent**, or **OpenClaw**.  
2. Download **Node v20.12.0** into the workspace (if not already present).  
3. `npm install blind-pairing-core hypercore-id-encoding hypercore random-access-memory random-access-file`.  
4. Create `~/.nanobot/rooms/` (always).  
5. Generate the three **Keet skills** with the updated `keet‑create‑room` logic (optional name, auto‑generated `sessionId`).  
6. For CoPaw → write `custom_channels/keet_channel.py` and run `copaw channels add keet`.  
7. For Hermes‑agent → write `~/.hermes/plugins/keet_plugin.py`.  
8. For OpenClaw → create a TypeScript plug‑in under `src/plugins/keet-channel/keet-channel.ts` and add it to the OpenClaw channel catalog.  
9. Print a short “what’s next?” guide.

All of this happens **without any further user input**.

---

## 4. How to use the new Keet commands

### 4.1 Create a room

```bash
nanobot agent -m "keet-create-room MyAwesomeRoom"
# or (no name → UUID will be used as both name and sessionId)
nanobot agent -m "keet-create-room"
```

**Returned JSON example**

```json
{
  "roomId":"nfothw1g5tip9s7x9kiws9yox1xyg3icu5cwthnqsrjn4y5xkpa5yfkkfigce6ox1gtkoy69yn8npriq4jj661y6z4hex38fx5894whoeuuj8k65kfwgwtm7cg7ooxm8qwxtrxtra7yzgee5zazfzym6e8iphyed4ruqojnkambti6c7hqtawtrubbmew",
  "inviteUrl":"pear://keet/nfothw1g5tip9s7x9kiws9yox1xyg3icu5cwthnqsrjn4y5xkpa5yfkkfigce6ox1gtkoy69yn8npriq4jj661y6z4hex38fx5894whoeuuj8k65kfwgwtm7cg7ooxm8qwxtrxtra7yzgee5zazfzym6e8iphyed4ruqojnkambti6c7hqtawtrubbmew",
  "sessionId":"d9b7c4e1-2f73-4b12-a5b1-c3f8e9a6b4d2",
  "roomName":"MyAwesomeRoom"
}
```

*Copy the `inviteUrl` and give it to any Keet client (mobile app, web, another agent, …).*  

### 4.2 Join interactively (keeps the chat alive)

```bash
nanobot agent -m "keet-join-room pear://keet/<roomId> --session <sessionId>"
```

*You will see:*  
```
Joined Keet room <roomId>
(session: <sessionId>)
[peer] …   ← messages from other participants
[you]  …   ← your own messages (type a line and press Enter)
```

The process stays running until you press **Ctrl +C**. All messages are written to `~/.nanobot/rooms/<roomId>_<sessionId>.dat` so the full history is available the next time you join.

### 4.3 Send a single message (no interactive session)

```bash
nanobot agent -m "keet-send-message pear://keet/<roomId> Hello from NanoBot --session <sessionId>"
```

Result:
```
Message sent
```

The message appears instantly in any other client that is connected to the same room.

### 4.4 Same commands on the other platforms

| Platform | Command prefix | Example |
|----------|----------------|---------|
| **CoPaw / QwenPaw** | `copaw channel keet` | `copaw channel keet create MyRoom`<br>`copaw channel keet join pear://keet/<id> --session <sid>` |
| **Hermes‑agent** | `hermes channel keet` | `hermes channel keet create MyRoom`<br>`hermes channel keet join pear://keet/<id> --session <sid>` |
| **OpenClaw** | `openclaw channel keet` | `openclaw channel keet create MyRoom`<br>`openclaw channel keet join pear://keet/<id> --session <sid>` |

All three commands map internally to the same Node scripts generated by the installer, so the behaviour is identical across the whole OpenClaw ecosystem.

---

## 5. Why the **session‑id** matters

* The **session‑id** (a UUID) is used as a **namespace for the persisted history file**.  
* If you create a room without a name, the script automatically uses the generated `sessionId` as the room name, guaranteeing a non‑empty argument and a unique identifier for the chat log.  
* By passing `--session <sessionId>` when you join or send a message you tell the plug‑in which history file to load.  The same `<roomId>` can be reused with different `sessionId`s to start fresh independent chats if you ever need them.

---

## 6. Customising / Extending

* **Changing the storage location** – edit the constant `ROOMS_DIR` near the top of the generated `join_room.js` / `send_message.js` (the installer writes it as `${HOME}/.nanobot/rooms`).
* **Adding extra Node modules** – after the installer finishes you can `cd $WORKSPACE && npm install <module>`; the skills will automatically have access to any additional dependency.
* **Modifying the channel plug‑in** – the generated files (`custom_channels/keet_channel.py`, `~/.hermes/plugins/keet_plugin.py`, `src/plugins/keet-channel/keet-channel.ts`) are normal source files; feel free to edit them as you would any other plug‑in.

---

## 7. License

The installer script and this README are released under the **MIT License**. The underlying Keet libraries (`blind‑pairing‑core`, `hypercore`, …) retain their original licenses.

---

## 8. Contributing

If you discover a bug or want to add support for another OpenClaw‑derived platform:
1. Fork the repository (`https://github.com/pepeneif/keet-dropin-module`).
2. Create a branch, edit `install_keet_dropin.sh` (or add a new plug‑in file).
3. Run the script locally to verify everything works.
4. Open a pull request – the CI will run the installer on a clean workspace for each supported agent type.

---

## 9. Summary – one‑liner again

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pepeneif/keet-dropin-module/main/install_keet_dropin.sh)
```

That’s all you need to give any OpenClaw‑family agent a **full, persistent, interactive Keet chat capability** without touching the core code.

---

### 🎯 What to give the agent

* **Repo URL** – `https://github.com/pepeneif/keet-dropin-module`
* **README URL** – `https://github.com/pepeneif/keet-dropin-module/blob/main/README.md`

If the agent can read the README, it will see the exact one‑liner above and the detailed usage instructions, so the human operator (or the agent itself, if it parses markdown) can install the module without ever needing the raw script URL.

---

*Happy P2P chatting!* 🚀
