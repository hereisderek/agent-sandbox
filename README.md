# agent-sandbox

**Generic Bubblewrap sandbox runner for multi-account AI coding agents.**

Isolate credentials, configuration, and session state across multiple profiles and accounts for **Antigravity CLI**, **Claude Code**, **OpenAI Codex**, **OpenCode**, **Pi**, and **Orca** using lightweight Linux namespaces (`bwrap`).

---

## The Problem

Modern AI coding agents store authentication tokens, project trust lists, and session databases in hardcoded global directories (e.g., `~/.claude`, `~/.codex`, `~/.gemini`, `~/.config/opencode`).

This creates significant friction when you need to:
- Switch between personal, work, and client accounts.
- Run multiple agent sessions concurrently without race conditions or token collisions.
- Test new plugins, prompts, or MCP configurations in a throwaway environment.

`agent-sandbox` solves this by wrapping each agent invocation in an isolated [Bubblewrap](https://github.com/containers/bubblewrap) mount namespace. Your selected profile directory is dynamically bound over the agent's target configuration path, while keeping your `/workspace` read-write and preserving access to system developer tools (`git`, `wt`, compilers, runtimes).

---

## Supported Agents

| Agent | CLI Commands & Aliases | Real Binary Lookup | Isolated Paths | Isolation Model |
| :--- | :--- | :--- | :--- | :--- |
| **Antigravity** | `antigravity`, `agy` | `agy`, `antigravity` | `/opt/config/antigravity`<br>`~/.gemini`, `~/.antigravity` | Single-Folder |
| **Claude Code** | `claude`, `claude-code` | `claude`, `claude-code` | `/opt/config/claude`<br>`~/.claude` | Single-Folder |
| **OpenAI Codex** | `codex` | `codex` | `/opt/config/codex`<br>`~/.codex` | Single-Folder |
| **OpenCode** | `opencode` | `opencode` | `/opt/config/opencode` (config)<br>`~/.local/share/opencode` (data) | Multi-Folder |
| **OpenCode 2** | `opencode2`, `opencode-v2` | `opencode2`, `opencode-v2` | `/opt/config/opencode2`<br>`~/.config/opencode2` | Single-Folder |
| **Pi** | `pi` | `pi` | `/opt/config/pi`<br>`~/.pi/agent` | Single-Folder |
| **Orca** | `orca` | `orca` | `/opt/config/orca` (user data)<br>`~/.orca` (home data) | Multi-Folder |

---

## Prerequisites

`agent-sandbox` requires `bwrap` (Bubblewrap):

```bash
# Debian / Ubuntu / Linux Mint
sudo apt install -y bubblewrap

# Fedora / RHEL
sudo dnf install -y bubblewrap

# Arch Linux
sudo pacman -S bubblewrap

# Alpine Linux
sudo apk add bubblewrap
```

---

## Installation

### Quick Install

```bash
git clone https://github.com/hereisderek/agent-sandbox.git
cd agent-sandbox
./install.sh
```

By default, `install.sh` links `agent-sandbox` into `/opt/config/bin`, `~/.local/bin`, or `/usr/local/bin` (whichever is writable and in your `$PATH`). It also creates an `agy-sandbox` compatibility wrapper.

### Manual Setup

Add the repository's `bin/` directory to your `$PATH`, or symlink `bin/agent-sandbox` directly into your preferred binary directory:

```bash
ln -s /path/to/agent-sandbox/bin/agent-sandbox ~/.local/bin/agent-sandbox
```

---

## Usage

### 1. Listing Profiles (`--list-profile`)

Inspect existing profiles across all agents, including disk size, last modified timestamp, and authentication status:

```bash
# List all profiles across all agents
agent-sandbox --list-profile

# List profiles for a specific agent
agent-sandbox claude --list-profile
agent-sandbox agy --list-profile
```

**Sample Output:**
```text
+-------------+----------------------+----------+-------------------+----------------+-------------------------------------------------------------+
| Agent       | Profile              | Size     | Last Modified     | Status         | Directory                                                   |
+-------------+----------------------+----------+-------------------+----------------+-------------------------------------------------------------+
| antigravity | hereisderek          | 11M      | 2026-10-16 08:25  | Authenticated  | /opt/config/agent-sandbox/antigravity/hereisderek           |
| antigravity | 1and1get2            | 1.5M     | 2026-10-16 09:19  | Initialized    | /opt/config/agent-sandbox/antigravity/1and1get2             |
| claude      | work                 | 4.2M     | 2026-10-18 11:30  | Authenticated  | /opt/config/agent-sandbox/claude/work                       |
| codex       | client-a             | 520K     | 2026-10-17 16:45  | Configured     | /opt/config/agent-sandbox/codex/client-a                    |
+-------------+----------------------+----------+-------------------+----------------+-------------------------------------------------------------+
```

### 2. Running in an Isolated Profile (`--profile`)

To run an agent within an isolated profile, specify `--profile <name>`:

```bash
# Launch Claude Code with your "work" account
agent-sandbox claude --profile work

# Launch Antigravity CLI with a dedicated profile in non-interactive print mode
agent-sandbox agy --profile client-b -p "Run test suite and summarize results"

# Launch OpenAI Codex in an isolated client workspace
agent-sandbox codex --profile client-a
```

- If the profile directory does not exist, `agent-sandbox` automatically creates it and seeds standard skills and configuration templates.
- You can specify an absolute path instead of a simple name: `--profile /path/to/custom/profile`.

### 3. Direct Host Execution (Fallback)

If `--profile` is omitted, `agent-sandbox` runs the agent command directly on the host without sandboxing:

```bash
# Runs the real binary directly
agent-sandbox agy --version
agent-sandbox claude --help
```

---

## Key Architecture & Features

### Read-Write Workspace
Your active project working tree (`/workspace`, or the current directory `$PWD`) is preserved with full read-write permissions. You can build, edit, test, and commit code without filesystem restrictions.

### Full Worktrunk (`wt`) Integration
`agent-sandbox` preserves access to Worktrunk (`wt`), keeping `/opt/config/worktrunk` and `~/.config/worktrunk` read-write. Worktree lock files, hook approvals, and branching workflows work seamlessly from inside the sandbox.

### Subtree Relative Paths Fix
When switching between directories in a terminal, running `agent-sandbox` from within a masked config subtree (e.g. `~/.antigravity/antigravity-cli`) will automatically create matching relative subdirectories inside the active profile, eliminating Bubblewrap `Can't chdir` errors.

### Universal Skills & Rules
If global agent skills (`/opt/config/.agents/skills`) or rules (`~/.agents/rules`) exist on the host, `agent-sandbox` automatically symlinks them into newly created profile folders so your skills remain accessible.

---

## Configuration

Customize behavior using environment variables:

| Variable | Description | Default |
| :--- | :--- | :--- |
| `AGENT_SANDBOX_BASE` | Directory where profile data is stored | `/opt/config/agent-sandbox` or `~/.local/share/agent-sandbox` |
| `AGENT_SANDBOX_OWNER` | User identity for file permissions | Current user (`$USER`) |

---

## License

MIT License. Copyright (c) 2026 Derek. See [LICENSE](LICENSE) for details.
