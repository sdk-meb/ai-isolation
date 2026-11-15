# ai-isolation-setup 
##### [العربية](./README.ar.md)
A sandbox for AI coding tools on Debian/Wayland. It covers CLIs and desktop apps: Claude Code, Copilot CLI, Cursor, and anything you add later.

- **Root setup is preferred, not required.**
  - As root (`su -`): programs go to `/usr/local`, root-owned, so nothing running as you can modify them.
  - As a normal user: programs go to `~/.local`. This works, with a warning.
- **The config lives in your home.** `~/.config/ai-sandbox/tools.conf` lists *your* sandboxed tools. It's created from the defaults on first use, private (`600`), and **never visible inside the sandbox**.
- **Interactive add.** `ai-sandbox-admin add <name>` searches the system and your home for the tool by name and asks a few questions.
- **Nothing changes for you.** The real program is moved aside (`claude` → `.ai-real-claude`) and a tiny wrapper takes its place. Typing `claude`, clicking Cursor in the menu, an IDE or a script calling the absolute path: every caller gets the sandbox. No extra bin folder, no PATH tricks.

> **bubblewrap decides what the AI can see; seccomp user notification decides what it may run.**

| Layer | Program | Job | When it decides |
|---|---|---|---|
| Walls | `bwrap` (bubblewrap) | Which files, processes and devices exist for the tool | Once, at start |
| Guard (optional) | `aisup` (seccomp `USER_NOTIF`) | Which programs the tool may **exec**: allow, deny, or ask you | On every `execve`/`execveat` |

---

## How a tool gets started

```
shell `claude` · IDE · script · menu launcher (Exec=/usr/share/cursor/cursor)
        │
        ▼
~/.local/bin/claude          ← now a 5-line wrapper (made by `sync` / `add`):
        │                       exec /usr/local/bin/ai-sandbox run claude "$@"
        ▼
ai-sandbox run <tool> [args]    reads ~/.config/ai-sandbox/tools.conf
        │
        ▼
[aisup policy] ─► bwrap … ─► ~/.local/bin/.ai-real-claude   (the real program)
```

Root install: `/usr/local/bin/ai-sandbox`. User install: `~/.local/bin/ai-sandbox`.

- Inside the sandbox the original path is the real program again, so a tool can still call itself by name.
- **Updates:** run the real one outside the sandbox, e.g. `~/.local/bin/.ai-real-claude update`. If an update writes a new program over the wrapper (e.g. `npm install -g` of a newer version), the shell hook (`ai-sandbox-admin verify -q`, at every shell start) moves it aside and wraps it again.
- **Root-owned folders** (e.g. `/usr/share/cursor`): `sync`/`add` use `sudo`. A file owned by a Debian package is moved with `dpkg-divert`, so `apt upgrade` installs new versions to `.ai-real-<tool>` and **never touches the wrapper**. See [Updates, packages and secrets](#updates-packages-and-secrets).
- Arguments pass through unchanged (`claude --resume`, `cursor .`).

---

## Files

This folder is the source. `install` copies the programs from it.

| Source file | Root install (preferred) | User install | Purpose |
|---|---|---|---|
| `ai-sandbox.sh` | `/usr/local/bin/ai-sandbox` | `~/.local/bin/ai-sandbox` | Launcher. Reads your `tools.conf` and builds the bwrap (+ aisup) command. |
| `ai-sandbox-admin.sh` | `/usr/local/bin/ai-sandbox-admin` | `~/.local/bin/ai-sandbox-admin` | Install, plus managing your tools. |
| `undo.sh` | `/usr/local/bin/ai-sandbox-undo` (+ copy in `/var/lib/ai-sandbox/`) | `~/.local/bin/ai-sandbox-undo` (+ copy in `~/.local/state/ai-sandbox/`) | Reverses logged changes. Self-contained. |
| `lib.sh`, `check.sh`, `shell-hook.sh` | `/usr/local/lib/ai-sandbox/` | `~/.local/lib/ai-sandbox/` | Config parser, wall tests, re-wrap-after-update hook. |
| `aisup.c` | `/usr/local/lib/ai-sandbox/aisup` | `~/.local/lib/ai-sandbox/aisup` | seccomp exec supervisor. Compiled if `libseccomp-dev` + `cc` are present. |
| `tools.conf`, `policy.conf` | `/usr/local/lib/ai-sandbox/` | `~/.local/lib/ai-sandbox/` | **Defaults**, copied into each user's config on first use. |
| `install.sh` / `uninstall.sh` | — | — | Shortcuts for `ai-sandbox-admin install` / `uninstall`. |
| `Makefile` | — | — | Builds `./aisup` locally, for development only. |

Per user, always in your home:

| Path | What |
|---|---|
| `~/.config/ai-sandbox/tools.conf` | **Your AI tools** and what each may see. |
| `~/.config/ai-sandbox/policy.conf` | Your aisup exec rules. |
| `<dir>/<tool>` (the original path, e.g. `~/.local/bin/claude`) | The wrapper. |
| `<dir>/.ai-real-<tool>` | The real program, moved aside. `reset` / `remove` put it back. |
| `~/.local/state/ai-sandbox/` | Action log, backups, and a copy of `ai-sandbox-undo` (root: `/var/lib/ai-sandbox/`). Never visible inside the sandbox. |

**How your config is protected:**
- The launcher only starts if your config files belong to you and aren't group/world-writable.
- It **refuses to start** a tool whose project or `rw` paths would make any of these writable inside the sandbox: the config, any tool's wrapper, the user-install programs, `~/.zshrc` or `~/.bashrc`.

---

## Install

**Preferred: as root.**
```sh
su -
apt install bubblewrap                    # required
apt install libseccomp-dev gcc zenity     # optional: aisup + its dialog
cd /home/<you>/Workspace/sh-scripts/ai-isolation-setup
bash install.sh
exit
```
Root install:
- copies the programs and default configs into `/usr/local`
- builds `aisup`
- adds the re-wrap hook to `/etc/zsh/zshrc` and `/etc/bash.bashrc`

It **doesn't touch any home**. Each user then runs this once, as themselves:
```sh
ai-sandbox-admin sync     # creates ~/.config/ai-sandbox/, asks before wrapping each tool
```

**Alternative: as your normal user** (no root needed):
```sh
cd ~/Workspace/sh-scripts/ai-isolation-setup
bash install.sh           # → ~/.local, hook in ~/.zshrc + ~/.bashrc, runs sync
```
User install refuses to run if a root install already exists. In that case, just run `sync`.

> This folder is inside `~/Workspace`, which Cursor can write to. Review its changes before installing, especially as root.

**Then** open a **new terminal** and check:
```sh
head -5 ~/.local/bin/claude   # → "# ai-sandbox wrapper …"
cd ~/Workspace/some-project
ai-sandbox check         # all PASS?
claude                   # sandboxed
```

---

## Commands

### `ai-sandbox`

| Command | What it does |
|---|---|
| `ai-sandbox run <tool> [args…]` | Start a tool from your `tools.conf` sandboxed. The wrappers call this. |
| `ai-sandbox run shell` | Built-in test profile: bash with only the common rules. |
| `ai-sandbox list` | Show your tools. |
| `ai-sandbox check` | Run the wall tests from the current directory. |

| Variable (per run) | Effect |
|---|---|
| `AI_PROJECT=/path` | Use this project dir instead of the one in `tools.conf`. |
| `AISUP=1` | Force the exec supervisor on. |
| `AI_NEW_SESSION=0` | Don't detach from the terminal (see TIOCSTI below). |
| `AI_DEBUG=1` | Print the final command before running it. |

### `ai-sandbox-admin`

| Command | Run as | What it does |
|---|---|---|
| `install` | root (preferred) or user | Install the programs (see above). |
| `uninstall` | root → system install; user → user install | Remove the programs. A user uninstall also runs `reset` and asks before deleting `~/.config/ai-sandbox`. Before a root uninstall, users should run `reset`. |
| `search <name>` | you | List programs and menu launchers whose name contains `<name>`. Changes nothing. |
| `add [name]` | you | Interactive add (see below). |
| `remove <name>` | you | Put the real program back (and remove a dpkg diversion), then delete the tool's section. Logged, so `ai-sandbox-undo last` brings it back. Its data is kept. |
| `list` | you | Show your tools. |
| `sync` | you | Wrap every tool in `tools.conf` (asks before each first move; sudo for root-owned folders). Run it after editing by hand. |
| `verify [-q]` | you | Re-wrap tools an update replaced, point `exec-newest` tools at their newest version, and warn about orphan wrappers (real program gone). `-q` (shell hook): silent unless something needs you, never sudo. |
| `reset` | you | Put every real program back. The config is kept. |

`search`, `add`, `remove`, `sync` and `reset` refuse to run as root, because the config is per user.

### What `add` asks

1. **Which program.** It searches `/usr/bin`, `/usr/sbin`, `/usr/local/bin`, `/usr/games`, `/opt`, `/usr/share`, `/usr/lib`, `/snap/bin`, plus your `~/.local/bin`, `~/.local/share`, `~/Applications`, `~/bin`, and the npm/bun/cargo/deno bin dirs. You pick one or more results by number (`4`, or `4 3` / `4,3`), or type one or more paths. **The first one is the main program.** Pick several when one tool has several programs, e.g. Devin's CLI script `/usr/share/devin-desktop/bin/devin-desktop` and its app binary `/usr/share/devin-desktop/devin-desktop`: each one gets its own wrapper and all of them run in the same `[section]`. If you pick a symlink and also its target (`/usr/bin/devin-desktop` → `…/bin/devin-desktop`), only the target is wrapped: the symlink already leads to that wrapper. `.desktop` files are not listed as programs.
2. **Profile name** (its `[section]`), plus **type**: `cli` or `gui`. It guesses `gui` if a menu launcher matches or the app is Electron.
3. **Project folder:** `cwd` for CLIs, `~/Workspace` for GUIs by default.
4. **Your entries whose name contains the search term.** It looks directly inside `~`, `~/.config`, `~/.local/share` and `~/.cache`. For each folder: read-write, read-only, or skip. For each file: read-write or skip.
5. **The move.** Prefix for the real program (default `.ai-real-`), then a confirmation: `<path>` → `<dir>/.ai-real-<name>`, wrapper at `<path>`, for each picked program. How it moves:
   - a file **owned by a Debian package** → `dpkg-divert --rename` (with sudo), so package upgrades go to `.ai-real-<name>`;
   - any other file in a folder you can't write → `sudo mv`;
   - your own files → plain `mv`.
5b. **Program folder (home installs only).** If the program lives in your home, it offers read-only access to its folder. For an npm package it offers the whole package folder (`…/node_modules/<pkg>`). If the program is a symlink into a `versions/` folder (Claude Code style: `~/.local/bin/claude` → `~/.local/share/claude/versions/<ver>`), or sits in one, it also adds `exec-newest = <that folder>/*`.
6. **Extra arguments and environment variables to pass in.** Menu launchers need nothing: they start the original path, which is now the wrapper. For Electron apps the suggested arguments are `--ozone-platform=wayland --password-store=basic`.
7. **aisup:** yes or no. For a GUI app outside your home, `exec-allow = <app dir>/*` is added automatically.
8. **Save.** It shows the new `[section]` and runs the same checks as the launcher (so a section that would see another tool's data is refused before anything is saved). If you confirm, it appends the section to your `tools.conf` and does the move(s).

---

## `tools.conf`

```ini
[claude]                          # profile name: the wrapper runs `ai-sandbox run claude`
wrapped = ~/.local/bin/claude     # ORIGINAL path → becomes the wrapper
exec = ~/.local/bin/.ai-real-claude   # where the real program is moved (absolute or ~/…)
type = cli                        # cli | gui
project = cwd                     # cwd | /dir   (read-write work area)
rw = ~/.claude                    # read-write dir, created if missing   (repeatable)
rw-file = ~/.claude.json          # read-write file, created if missing  (repeatable)
ro = ~/.local/share/claude        # read-only dir, skipped if missing    (repeatable)
args = --flag                     # always passed to the program
env-set = DISABLE_AUTOUPDATER=1   # set inside                            (repeatable)
env-pass = ANTHROPIC_API_KEY      # copied in from your environment
exec-allow = /usr/share/x/*       # extra aisup allow rule                (repeatable)
exec-newest = ~/.local/share/claude/versions/*   # run the newest version found there
aisup = no                        # yes = run under the exec supervisor
```

- `#` starts a comment anywhere on a line.
- `shell` is a reserved name.
- A section without `wrapped =` is skipped by `sync` with a warning (nothing would start it sandboxed).
- **Several programs in one tool:** repeat `exec =` + `wrapped =` as pairs, in order (the Nth `exec` is the real program behind the Nth `wrapped`). The first pair is the main program; `exec-newest` only applies to it. The numbers must match, or the section is refused.
  ```ini
  [devin]
  exec = /usr/share/devin-desktop/.ai-real-devin-desktop        # main: the app binary
  wrapped = /usr/share/devin-desktop/devin-desktop
  exec = /usr/share/devin-desktop/bin/.ai-real-devin-desktop    # its CLI script
  wrapped = /usr/share/devin-desktop/bin/devin-desktop
  ```
  An extra program's wrapper runs `ai-sandbox run --via <its path> <tool>`, and the launcher only accepts a `--via` path listed in that section. Inside the sandbox every `wrapped` path is its real program again, so the programs can call each other (the CLI script runs the app binary, not a second sandbox). `sync`, `verify`, `remove` and `reset` handle every pair.
- `desktop =` (old design) is ignored.

The default tools:

| Tool | Program | Read-write | Read-only | Notes |
|---|---|---|---|---|
| `claude` | `~/.local/bin/claude` | `~/.claude`, `~/.claude.json` | `~/.local/share/claude` | `DISABLE_AUTOUPDATER=1`; passes `ANTHROPIC_API_KEY` |
| `copilot` | `~/.local/bin/copilot` | `~/.copilot` | — | passes `GH_TOKEN`, `GITHUB_TOKEN`, `COPILOT_GITHUB_TOKEN` |
| `cursor` | `/usr/share/cursor/cursor` | `~/.config/Cursor`, `~/.cursor`, project `~/Workspace` | — | gui; Wayland, no keyring; root-owned folder → `sync` uses sudo |

---

## Updates, packages and secrets

- **Tools that update into a `versions/` folder** (Claude Code). Tested with the real updater (2.1.311 → 2.1.325): it sees that `~/.local/bin/claude` is not its symlink, prints *"auto-update leaves it untouched"*, and only adds the new version under `versions/`. The wrapper stays byte-identical, also when you re-run the official installer.
  - **Old versions pile up.** Because of the wrapper, the updater says it *"cannot tell which version your launcher needs, so it keeps them all"*. Delete old folders in `~/.local/share/claude/versions/` yourself now and then; `exec-newest` always runs the highest one.
  - **This is what those versions do, not a promise.** Anthropic can change the updater. `../vm-test` installs *today's* stable and latest each run, so re-run `tests/run-all.sh 00 60 97` after a big Claude update. If a future updater does overwrite the wrapper, the fallback still works (tested by `global-test.sh` #6): `verify` (every new terminal) sees the wrapper is gone and wraps the new program again. In between, `claude` from an **already open** terminal runs unsandboxed. Check with `ai-sandbox-admin verify`.
- **`exec-newest = GLOB`** handles that: at every start the launcher runs the **highest version** among the *executable files* matching GLOB, compared with `sort -V` (so `1.10` > `1.9`; names, not file times). `.ai-real-<tool>` stays a **symlink**; the shell hook (a new terminal) re-points it to that newest version, so running `.ai-real-<tool>` directly and undo use the newest too. If your `tools.conf` predates this, add `exec-newest = ~/.local/share/claude/versions/*` under `[claude]`.
- **Files owned by a Debian package** (e.g. Cursor in `/usr/share/cursor`) are moved with `dpkg-divert --rename`, not `mv`. Tested with a real apt repo: `apt upgrade` and `apt install --reinstall` install the new version to `.ai-real-<tool>`, the wrapper stays byte-identical and `dpkg -V` stays clean. `reset`, `remove` and undo remove the diversion again.
  - **`apt remove` of a wrapped package** deletes the real program but not our wrapper (dpkg doesn't know it). The wrapper is then an orphan: running it says *"its Debian package was probably removed; clean up with: ai-sandbox-admin remove <tool>"*, and a new terminal warns the same. Run that command.
- **npm tools in your home:** `add` gives read-only access to the whole package folder (`…/node_modules/<pkg>`), not only its `bin/`.
- **Known secrets are never exposed**, whatever `tools.conf` says. No project, `rw` or `ro` may be, contain or sit inside one of them. Symlinks are resolved first. The built-in list covers:
  - keys and credentials: `~/.ssh`, `~/.gnupg`, `~/.password-store`, `~/.pki`, `~/.netrc`, `~/.git-credentials`, `~/.local/share/keyrings`, 1Password (`~/.config/op`), Bitwarden;
  - cloud: `~/.aws`, `~/.azure`, `~/.config/gcloud`, `~/.oci`, `~/.kube`, `~/.docker`, doctl, hcloud, `~/.terraform.d`, `~/.vault-token`, rclone;
  - developer tokens: `~/.config/gh`, hub, glab, `~/.config/github-copilot`, `~/.npmrc`, `~/.yarnrc.yml`, `~/.pypirc`, cargo and gem credentials;
  - browsers and mail: `~/.mozilla`, `~/.thunderbird`, Chrome, Chromium, Brave, Edge, Vivaldi, Opera — and **all of `~/snap` and `~/.var/app`** (snap and Flatpak apps, which keep their browser profiles there).
- **The list is not complete.** It names known locations. A tool that stores its token somewhere else is not protected, so keep `rw`/`ro` narrow. An admin can add or remove entries in **`/etc/ai-sandbox/secrets.conf`** (`deny ~/.config/mytool` / `allow ~/.pki`, one per line). The launcher only reads it if it is root-owned and not group/world-writable.
- **AI tool data is isolated per tool. A tool may only see its own data dir.** If a tool's `rw`, `rw-file`, `ro` or `project` (fixed, or the folder you start a `cwd` tool in) is, contains or sits inside a path another tool lists as `rw`, `rw-file` or `ro`, it is refused. For example, `[claude]` with `rw = ~/.copilot` is refused. Symlinks are resolved first. The check runs in the launcher and in `ai-sandbox-admin add`/`sync`. Unlike the secrets list it has no exceptions: `/etc/ai-sandbox/secrets.conf` cannot `allow` it. Editor data such as `~/.config/Code` is protected this way, not by the secrets list: give the editor its own entry (`[code]` with `rw = ~/.config/Code`) and no other tool can get it. **Without such an entry nothing guards `~/.config/Code`**, and it can hold tokens (VS Code started with `--password-store=basic` keeps them there in an easily decrypted file).
- **The list protects you only in a root install.** It lives in the program. In a user install the program is in `~/.local/bin`, owned by you, so any program running as you can edit the list (tested: removing `~/.ssh` from it made the key readable).

## What every tool gets

| | |
|---|---|
| Read-only | `/usr` (plus `/bin`, `/sbin`, `/lib`, `/lib64` symlinks), `/etc`, `~/.gitconfig`, `~/.config/git`, DNS dirs in `/run` |
| Read-write | the project dir (and the tool's `rw` / `rw-file` entries) |
| Fresh / private | `/proc`, `/dev`, `/dev/shm`, `/tmp`; **`$HOME` is an empty tmpfs** |
| Namespaces | everything unshared **except network**; `--die-with-parent` (except a GUI app's CLI, below), `--cap-drop ALL`, `no_new_privs` (sudo/setuid don't work) |
| Environment | cleared, then only `HOME USER LOGNAME PATH SHELL TERM COLORTERM LANG LANGUAGE LC_ALL EDITOR VISUAL` (+ `env-set` / `env-pass`) |
| Session | `--new-session` (blocks TIOCSTI) unless `AI_NEW_SESSION=0` |

The launcher refuses to use `/`, `/home`, `/usr`, `/etc`, `/tmp` or `$HOME` as the project dir. When started from a subfolder of the project, the tool starts in that subfolder.

**`gui` tools also get:**
- The Wayland socket and `/dev/dri` (GPU), plus read-only `/sys`.
- A shared runtime dir and `/tmp` under `$XDG_RUNTIME_DIR/ai-sandbox/<tool>/`. A second launch, such as the browser login callback, reaches the running window that way.
- **No X11** and **no D-Bus or keyring**.
- **The app's own CLI works** (`cursor .`, `cursor file.py`, `cursor --version`, `cursor --install-extension …`). `/usr/bin/cursor` is a script that runs the wrapped binary with `ELECTRON_RUN_AS_NODE=1` and `cli.js`. The launcher keeps that variable (and skips `args`, which are Electron flags). Then:
  - The window that `cli.js` opens keeps running after `cli.js` exits, in the same sandbox. That sandbox ends when its last process ends.
  - The terminal gets `cli.js`'s output and exit code right away. `$(cursor --version)` and `cursor . | cat` return too.
  - A second `cursor file` goes to the running window.
  - Windows opened this way don't get `args`. Electron picks Wayland by itself, and with no keyring inside it stores secrets the basic way.

**Never visible:** `~/.ssh`, `~/.gnupg`, `~/.aws`, browser profiles, shell history, other tools' tokens, `SSH_AUTH_SOCK`, and **the sandbox config**. So `git push` and `ssh` must be done outside the sandbox.

---

## Exec supervisor (aisup)

It's turned on per tool with `aisup = yes`, or for one run with `AISUP=1`. If it's required but not built, the tool **refuses to start**.

```
ai-sandbox ─► aisup (outside the sandbox, supervisor)
               └─ fork ─► no_new_privs + seccomp filter ─► exec bwrap ─► tool ─► children
                              execve/execveat ── paused ──► rules
                                                            allow → runs
                                                            deny  → EPERM
                                                            ask   → zenity dialog (60 s → deny)
```

- **Rules for a run.** The launcher puts `allow <bwrap> *`, `allow <tool's exec>*` and the tool's `exec-allow` lines first, then appends `~/.config/ai-sandbox/policy.conf`.
- **Matching.** Each line is `allow|deny|ask <glob>`, matched against `"/abs/path arg1 arg2 …"`. The first match wins, and `default <action>` applies at the end. `*` also matches `/`.
- **Default `policy.conf`:**
  - Allows `/proc/self/exe` (Electron helpers) and normal system programs.
  - Denies `sudo`, `su` and `pkexec`.
  - Asks for network tools, `rm -r…`, `git push`, `npm publish`, `python3 -c` and `perl -e`.
  - `default ask`.
- **Missing programs.** An exec of a path that doesn't exist fails with `ENOENT`, without a prompt or log entry.
- **Log.** Decisions go to `~/.local/state/aisup.log` (or `$AISUP_LOG`). Lowercase entries came from the policy; UPPERCASE entries came from you.
- **TIOCSTI.** It's blocked by the filter, so `AISUP=1 AI_NEW_SESSION=0` is safe.
- **Fails closed.** If aisup dies, the sandbox gets SIGKILL and pending execs fail with `ENOSYS`.
- **TOCTOU.** The notification ID is checked with `SECCOMP_IOCTL_NOTIF_ID_VALID` after the arguments are read and again after a dialog.
- **One dialog at a time.**

---

## Limits

- **Root install vs user install:**
  - A root install makes the *programs* tamper-proof.
  - Your *config* is in your home either way. It's safe from the AI (invisible inside the sandbox), but not from other programs running as you outside it.
  - A user install makes the programs just as editable as the config — including the built-in secrets list.
- **Bypass is still possible on purpose.** Running `.ai-real-<tool>` directly is not sandboxed, and a tool that bundles its own copy elsewhere (e.g. an IDE extension shipping its own `claude`) needs its own entry.
- **Exec rules are a guard rail.**
  - `python3 -c …` is one exec, so only the interpreter is checked.
  - Another thread can rewrite the path after aisup reads it (the TOCTOU race).
  - The hard wall is the bwrap mounts.
- **The network is not filtered.** This is the biggest open hole: a tool sees only its project, but can send that project anywhere. See [Not implemented yet](#not-implemented-yet).
- **Not covered:**
  - Sandboxing Flatpak and Snap apps themselves.
  - Launchers whose `Exec=` starts with `env …`.
- **Tested in VMs, not on many machines.**
  - **CLI tools:** `../vm-test/` runs the whole suite on a fresh Debian 12 VM with the real Claude Code and Codex CLI (install, real updates, real `apt upgrade`, undo). All checks pass; the open network and the config weaknesses above are reported as warnings.
  - **Real Cursor, Wayland:** a second VM (`vagrant up gui`) runs the real Cursor from its official apt repo on sway. Tested: start from the menu and from `cursor .`; every Cursor process is sandboxed; it can't see `~/.ssh` and friends; Chromium's own sandbox still works inside (no `--no-sandbox`); `apt --reinstall` and an upgrade keep the wrapper; `remove` undoes it.
  - **Cursor, not tested:** logging in, the integrated terminal and Cursor's own agent sandbox. Its agent sandbox is the `cursorsandbox` helper; it wants AppArmor and capabilities, which nothing inside bwrap has, so expect it to be unavailable. bwrap is the wall either way. All three need a real account and clicks; `../vm-test/README.md` has the manual steps.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `claude` still unsandboxed | Run `ai-sandbox-admin sync` and answer `y`. `head -2 ~/.local/bin/claude` must show `# ai-sandbox wrapper`. |
| `… must belong to you and not be group/world-writable` | `chmod 600 ~/.config/ai-sandbox/*.conf` |
| `… would be writable inside and contains …` | A `rw`/`project` path covers the sandbox's own files. Use a narrower path. |
| `refusing to expose '…'` | `cd` into a project folder first, or set `AI_PROJECT=`. |
| `run this as your normal user` | `search`, `add`, `remove`, `sync` and `reset` manage *your* config. Leave the root shell first. |
| `root already installed it system-wide` | No user install is needed. Just run `ai-sandbox-admin sync`. |
| `aisup is not installed` | `apt install libseccomp-dev gcc`, then run `install` again. |
| Cursor: *SUID sandbox helper … not configured* | Not needed on Debian 12: Chromium's sandbox works inside bwrap (tested). If your kernel blocks it anyway, add `--no-sandbox` to `args` in `[cursor]` and run `sync`; bwrap is still the wall. |
| `cursor .` opens `cli.js` as a file | Your installed `ai-sandbox` is older than the Electron CLI fix. Re-run the install. |
| Cursor shows no window | `AI_DEBUG=1 ai-sandbox run cursor` in a terminal and read the errors. |
| Claude: config not saved | Replace `rw-file = ~/.claude.json` with `env-set = CLAUDE_CONFIG_DIR=~/.claude`. |
| Copilot asks to log in every time | There's no keyring inside. Export `GH_TOKEN` before starting it. |
| Too many aisup prompts | Read `~/.local/state/aisup.log` and add `allow` lines above `default ask` in your `policy.conf`. |
| CLI doesn't redraw on resize | Use `AISUP=1 AI_NEW_SESSION=0`. |
| `make`: `missing separator` | `Makefile` recipe lines must start with a TAB. |

## Log and undo

Every change on disk is logged by `ai-sandbox-admin` (install, sync, add, remove, reset, uninstall, the shell hook's re-wraps) and by `ai-sandbox` (folders and files it creates for a tool). Anything overwritten or deleted is copied to `backups/` first.

| Who | Log | Backups |
|---|---|---|
| root | `/var/lib/ai-sandbox/actions.log` | `/var/lib/ai-sandbox/backups/` |
| you | `~/.local/state/ai-sandbox/actions.log` | `~/.local/state/ai-sandbox/backups/` |

A command that changes nothing writes nothing. Changes made with `sudo` (e.g. wrapping Cursor) are in *your* log, marked `sudo`, and their undo uses sudo too.

```sh
ai-sandbox-undo list            # runs that can still be undone, newest first
ai-sandbox-undo show last       # what the newest run changed
ai-sandbox-undo -n last         # dry run
ai-sandbox-undo last            # undo the newest run (asks first; -y = don't ask)
ai-sandbox-undo run <RUN-ID>    # undo one run
ai-sandbox-undo all             # undo everything → back to before the install
ai-sandbox-undo purge           # the very last step, after `all`: delete the log, backups,
                                # this tool, aisup.log and the empty folders it created
ai-sandbox-undo prune [DAYS]    # free space: drop backups of undone runs (+ older than DAYS)
```

- **It can stop anywhere.** Every change is logged *before* it is made, so a Ctrl-C, a crash, a power cut or a failing command never leaves a change the log doesn't know about. Undo recognises logged changes that never happened and skips them quietly. An undo that stopped half-way continues where it left off when you run it again. `../vm-test` (test 98) kills install, sync, uninstall and undo with SIGKILL at **every single step**, for a user install, a root install, and a `dpkg-divert` of a package file. Each time, `undo all` + `purge` gives back the home and the system **byte for byte** as before, except for the tool data and newer versions listed under *What stays* below.
- **Which undo to run.** The very first thing `install` does is put the undo tool next to the log, so even an install that stopped at its first step can be undone with `~/.local/state/ai-sandbox/ai-sandbox-undo all` (root: `/var/lib/ai-sandbox/ai-sandbox-undo all`).
- **Shell rc files** (`~/.bashrc`, `~/.zshrc`, `/etc/bash.bashrc`, `/etc/zsh/zshrc`): undo removes exactly the 2 lines the install added. Your own later edits stay. A leftover hook line is harmless anyway: it only runs if its script exists.

- **Safe by default.** Before reversing a change, it checks that the thing still looks the way the log says. The check compares content (a sha256 hash), not mtime: rewriting the same content does not count as a change. If you or an update changed it since (e.g. you edited `tools.conf` by hand), that step is skipped and reported. `-f` forces it, after saving the current version to `backups/forced-*`.
- **Non-empty folders are never deleted**, even with `-f` (e.g. `~/.claude` once the tool has saved data in it).
- **Undoing the install or an uninstall** removes or restores `ai-sandbox-undo` itself. For that case, use the copy next to the log, which always stays: `~/.local/state/ai-sandbox/ai-sandbox-undo` (root: `/var/lib/ai-sandbox/ai-sandbox-undo`).
- **Re-wraps after an update** are logged as notes, not as changes: undoing the install leaves the *newest* version of the tool in place. The obsolete old version is dropped, not backed up.
- **Backups** hold every file the setup overwrote or deleted. Run `prune 30` now and then.

## Uninstall

```sh
ai-sandbox-admin reset          # each user: put the real programs back (config kept)
su -; ai-sandbox-admin uninstall   # root install
ai-sandbox-admin uninstall      # or, for a user install (also resets; asks about config)
```

The tools' own data (`~/.claude`, `~/.config/Cursor`, …) is never touched.

**Two ways out:**
- **`uninstall`** removes the programs, the wrappers and the hooks, and keeps the log, so you can still undo the uninstall.
- **`undo all` then `purge`** returns to *exactly* the state before the install, including the log itself. That's the one to use after a trial:

```sh
~/.local/state/ai-sandbox/ai-sandbox-undo all     # user install (root: /var/lib/ai-sandbox/ai-sandbox-undo all)
~/.local/state/ai-sandbox/ai-sandbox-undo purge
```

What stays after `undo all` + `purge`, on purpose:
- the data a tool saved while it ran (`~/.claude/…`), exactly as if it had run without the sandbox;
- a newer tool version an updater installed meanwhile.

## Not implemented yet

- **Network allowlist:** a private network namespace (`pasta`) plus a proxy that only allows each tool's API domains. Until then, treat every sandboxed tool as able to upload its project.
