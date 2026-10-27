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

### 4. Per-Profile IPv4 / IPv6 (`--ipv4`, `--ipv6`)

Each profile can use its own outbound address per IP family:

```bash
agent-sandbox claude --profile work --ipv6 new                 # reserve an address via the net hook
agent-sandbox claude --profile work --ipv6 2404:4400:4172:e900:ffff:ffff:ffff:ff00
agent-sandbox claude --profile work --ipv4 none                # no IPv4 for this profile
agent-sandbox claude --profile work --ipv6 host                # pin the host's own address
agent-sandbox claude --profile work --ipv6 default             # forget the saved choice, use the default policy
```

| Value | Meaning |
| :--- | :--- |
| `<address>` | Bind outbound traffic of that family to the address. It must exist on the host. |
| `host` | No binding: the host's own address, as without any feature. |
| `none` / `null` | Disable that family for the profile. |
| `new` | Ask the net hook to reserve an address, then use it. Safe to repeat: the hook gives the same profile the same address. |
| `default` | Forget the saved choice and apply the default policy (below). |

**One command, no flags.** Set the default policy and every profile gets its own address automatically:

```bash
export AGENT_SANDBOX_DEFAULT_IPV6=new     # or put ipv6=new in <sandbox_base>/.net/defaults.conf
agent-sandbox claude --profile work       # first launch: reserves an address and saves it
agent-sandbox claude --profile work       # later launches: reuses it
```

The policy applies to a profile with no flag and nothing saved. It can be `new`, `none`, an address or `host` (the default when unset). Only a reserved `new` address is saved, so changing the policy later does not move profiles that already have one. The environment variable overrides `defaults.conf`. `--ipv6 default` on a profile re-applies the policy: with `new`, the hook returns the profile's existing address.

- **Saved per profile.** An explicit flag is stored in `<sandbox_base>/.net/<agent>/<profile>.conf` and used on later launches. If a saved address is no longer available (and the hook cannot restore it), the profile falls back to the host address for that family and logs a warning. The saved value is kept.
- **Every launch logs what it uses**, to stderr: `[agent-sandbox] net claude/work: ipv4=172.16.2.26 (default) ipv6=2404:…:ff00 (saved)`. The source is `flag`, `saved`, `auto` (from the default policy), `default` (host address) or `fallback`.
- **Resolution order:** flag, then saved, then the default policy. With both families on `host`, nothing changes: the agent shares the host network.
- `--list-profile` shows saved choices under the table. Inside the sandbox the config is read-only (`/opt` is mounted read-only).
- The sandbox sees `AGENT_SANDBOX_IPV4` and `AGENT_SANDBOX_IPV6` (`host`, `none` or the address).

**How it works.** A non-default choice starts the agent under [`pasta`](https://passt.top) (userspace network namespace) with `-o <address>` binding outbound sockets, `-4`/`-6` for a disabled family, and `--unshare-net` when both are `none`. Outbound only: nothing listens on the dedicated address.

**Requirements:** `pasta` (`apt install passt`) and a writable `/dev/net/tun`. On a Proxmox LXC, enable it on the host and restart the container:

```bash
pct set <ctid> --dev0 /dev/net/tun,mode=0666
```

With `--ipv4 none`, name resolution only works if `/etc/resolv.conf` lists an IPv6 nameserver.

#### Net hook (reserving addresses)

The script does not know how to allocate addresses. It calls an executable, `$AGENT_SANDBOX_NET_HOOK` or `<sandbox_base>/net-hook`:

```text
net-hook reserve <ipv4|ipv6> <agent> <profile>        print an address; the same profile gets the same one
net-hook ensure  <ipv4|ipv6> <addr> [<agent> <profile>]   make the address usable now; exit 0 = usable
```

`ensure` runs on launch when a saved or requested address is not on the host (for example after a reboot).

[`examples/net-hook-lxc.sh`](examples/net-hook-lxc.sh) handles IPv6 for a host or LXC with a SLAAC `/64`. It allocates interface IDs from a range inside that `/64`, adds each address to the interface as a deprecated `/128` (so the kernel never uses it as a default source), and records profile to ID in `<sandbox_base>/.net/ipv6.registry`. The default range is the 128 addresses `…:ff00` to `…:ff7f` at the top of the `/64`; the top 128 IDs of a `/64` are reserved anycast and are never used. To grow the pool, lower the start, for example `AGENT_SANDBOX_V6_POOL=ffff:ffff:fff0:0000-ffff:ffff:ffff:ff7f`. Existing assignments do not move. It needs no router change because the addresses are on-link. IPv4 is not handled by the example: pass an address that already exists on the host.

Tests: `bash tests/net.sh`, `bash tests/hook.sh` and `bash tests/clean.sh` (no root or network needed).

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
| `AGENT_SANDBOX_SKILLS` | Skills directory linked into new profiles | `/opt/config/.agents/skills`, else `~/.agents/skills` |
| `AGENT_SANDBOX_NET_ENV` | File that may set `SANDBOX_IPV6` (see below) | `<base>/net.env` |
| `AGENT_SANDBOX_NET_HOOK` | Executable that reserves/ensures addresses (see Per-Profile IPv4 / IPv6) | `<sandbox_base>/net-hook` |
| `AGENT_SANDBOX_DEFAULT_IPV4` / `AGENT_SANDBOX_DEFAULT_IPV6` | Default policy for profiles with no flag and nothing saved: `new`, `none`, an address or `host` | `host` |
| `AGENT_SANDBOX_DRY_RUN` | `1` prints the final command instead of running it | `0` |
| `AGENT_SANDBOX_V6_POOL` | Interface-ID range for `examples/net-hook-lxc.sh` | `ffff:ffff:ffff:ff00-ffff:ffff:ffff:ff7f` |

A multi-user host sets the base and skills per user, for example in `/etc/profile.d/agent-sandbox.sh`:

```bash
export AGENT_SANDBOX_BASE="$HOME/.local/share/agent-sandbox" AGENT_SANDBOX_SKILLS="$HOME/.agents/skills"
```

### Dedicated IPv6 (optional)

If `net.env` (in the base directory, or the file named by `AGENT_SANDBOX_NET_ENV`) sets `SANDBOX_IPV6=<address>`, `agent-sandbox` runs `bwrap` under `pasta` (package `passt`) so outbound sockets bind to that address and only the sandbox uses it. The sandbox then no longer shares the host's `localhost`. It fails with a clear error if `pasta` is missing. It is a fallback: a profile with its own `--ipv4`/`--ipv6` setting (see Per-Profile IPv4 / IPv6) takes precedence. Without `net.env` nothing changes.

---

## Cleaning up profiles

```bash
agent-sandbox --auto-clean --dry-run          # list what would be removed
agent-sandbox --auto-clean                    # list, ask, then remove
agent-sandbox --auto-clean codex --days 30    # one agent, unused for 30+ days
agent-sandbox --auto-clean --yes              # no question (for cron)
agent-sandbox --auto-clean -i                 # pick profiles by number (also --interactive)
```

`--auto-clean` removes a profile only when both are true:

- **Not authenticated.** Its status in `--list-profile` is `New` or `Initialized` (no credentials). `Authenticated`, `Active` and `Configured` profiles are never touched.
- **Unused.** Nothing in it changed in the last `--days` days (default 7; `0` means any age).

**Interactive mode** (`-i`) shows every profile, authenticated or not, in a numbered list. `*` marks what plain `--auto-clean` would remove. Answer with numbers or ranges (`1,3-5`), `a` for all `*` rows, or `q` to quit, then confirm. Picking a profile that has credentials needs the word `delete` typed. `--dry-run` shows the selection without removing anything; `<agent>` limits the list. Input is read from stdin.

Removing a profile also deletes its saved network choice (`.net/<agent>/<profile>.conf`) and calls `net-hook release <agent> <profile>`, which the example hook uses to free the reserved address. Without a terminal, `--yes` is required.

---

## Versions and updating

`agent-sandbox --version` prints the version. Releases are tagged without a `v` (for example `0.0.1`) and carry the single file `agent-sandbox` as an asset. `update.sh` installs the latest release only when it is newer than the installed one:

```bash
./update.sh --check            # exit 0 up to date, 10 newer release exists
./update.sh                    # install it over the agent-sandbox on PATH
./update.sh /opt/tools/agent-sandbox/agent-sandbox
```

A copy that is a symlink into a git clone is updated with `git pull` instead.

---

## License

MIT License. Copyright (c) 2026 Derek. See [LICENSE](LICENSE) for details.
