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
~/.local/bin/claude          ← now a 5-line wrapper (made by `add` / `list`):
        │                       exec /usr/local/bin/ai-sandbox run claude "$@"
        ▼
ai-sandbox <tool> [args]        reads ~/.config/ai-sandbox/tools.conf
        │
        ▼
[aisup policy] ─► bwrap … ─► ~/.local/bin/.ai-real-claude   (the real program)
```

Root install: `/usr/local/bin/ai-sandbox`. User install: `~/.local/bin/ai-sandbox`.

- Inside the sandbox the original path is the real program again, so a tool can still call itself by name.
- **A tool calling another sandboxed tool** (e.g. `code` runs `copilot`, or a CLI runs a GUI app): no second sandbox. Every other tool in your `tools.conf` has its real program mounted read-only at its original path (`~/.local/bin/copilot` is a symlink to the real program inside, as on the host; a script in your home also gets its own folder, read-only). So calling it just runs the original program, behind the **caller's** walls. To give it its files too, list it in the caller's **`runs =`** (see [`tools.conf`](#toolsconf)); otherwise it may need to log in again or get a token through `env-pass` (e.g. `GH_TOKEN`). If a wrapper is still reached somehow, the launcher sees it is already inside (marker `/run/.ai-sandbox` + pid 1 is `bwrap`) and runs the real program directly. `$AI_SANDBOX` names the outer tool.
- **Updates:** run the real one outside the sandbox, e.g. `~/.local/bin/.ai-real-claude update`. If an update writes a new program over the wrapper (e.g. `npm install -g` of a newer version), the shell hook (at every shell start) moves it aside and wraps it again.
- **Root-owned folders** (e.g. `/usr/share/cursor`): `add`/`list` use `sudo`. A file owned by a Debian package is moved with `dpkg-divert`, so `apt upgrade` installs new versions to `.ai-real-<tool>` and **never touches the wrapper**. See [Updates, packages and secrets](#updates-packages-and-secrets).
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
| `install.sh` / `uninstall.sh` | — | — | `install.sh` installs (see above; it runs the source copy of `ai-sandbox-admin`). `uninstall.sh` is a shortcut for `ai-sandbox-admin uninstall`. |
| `Makefile` | — | — | Builds `./aisup` locally, for development only. |

Per user, always in your home:

| Path | What |
|---|---|
| `~/.config/ai-sandbox/tools.conf` | **Your AI tools** and what each may see. |
| `~/.config/ai-sandbox/policy.conf` | Your aisup exec rules. |
| `<dir>/<tool>` (the original path, e.g. `~/.local/bin/claude`) | The wrapper. |
| `<dir>/.ai-real-<tool>` | The real program, moved aside. `remove` / `remove --all` put it back. |
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
ai-sandbox-admin list     # creates ~/.config/ai-sandbox/, asks before wrapping each tool
```

**Alternative: as your normal user** (no root needed):
```sh
cd ~/Workspace/sh-scripts/ai-isolation-setup
bash install.sh           # → ~/.local, hook in ~/.zshrc + ~/.bashrc, wraps your tools
```
User install refuses to run if a root install already exists. In that case, just run `ai-sandbox-admin list`.

> This folder is inside `~/Workspace`, which Cursor can write to. Review its changes before installing, especially as root.

**Then** open a **new terminal** and check:
```sh
head -5 ~/.local/bin/claude   # → "# ai-sandbox wrapper …"
cd ~/Workspace/some-project
ai-sandbox-admin check   # all PASS?
claude                   # sandboxed
```

---

## Commands

### `ai-sandbox`

| Command | What it does |
|---|---|
| `ai-sandbox <tool> [args…]` | Start a tool from your `tools.conf` sandboxed. The wrappers call this (as `ai-sandbox run <tool>`, same thing). |
| `ai-sandbox shell` | Built-in test profile: bash with only the common rules. |

That is its only job. Everything else is in `ai-sandbox-admin`.

| Variable (per run) | Effect |
|---|---|
| `AI_PROJECT=/path` | Use this project dir instead of the one in `tools.conf`. |
| `AISUP=1` | Force the exec supervisor on. |
| `AI_NEW_SESSION=0` | Don't detach from the terminal (see TIOCSTI below). |
| `AI_DEBUG=1` | Print the final command before running it. |

### `ai-sandbox-admin`

| Command | Run as | What it does |
|---|---|---|
| `uninstall` | root → system install; user → user install | Remove the programs. A user uninstall also runs `remove --all` and asks before deleting `~/.config/ai-sandbox`. Before a root uninstall, users should run `remove --all`. |
| `add [name]` | you | Interactive add (see below). |
| `remove <name>` | you | Put the real program back (and remove a dpkg diversion), then delete the tool's section. Logged, so `ai-sandbox-undo last` brings it back. Its data is kept. |
| `remove --all` | you | Put every real program back. The config is kept. |
| `list` | you | Shows every tool, what it may see (project, `rw`, `ro`, `runs`, aisup) and its status: `boxed` (sandboxed), `not-synced` (in `tools.conf`, not wrapped yet: runs unsandboxed), `replaced` (an update wrote over the wrapper), `orphan` (real program gone), `missing` (not installed), `removed` (taken out with `remove`; shows the `ai-sandbox-undo` id to bring it back). Then offers to wrap the `not-synced`/`replaced` ones (sudo for root-owned folders). Changes nothing unless you say yes. Run it after editing `tools.conf` by hand. |
| `check` | you | Run the wall tests from the current directory (`AISUP=1` for the supervisor). |

The shell hook does the re-wrap part of `list` silently at every shell start (never with sudo).

`add`, `remove` and `list` refuse to run as root, because the config is per user.

### What `add` asks

1. **Which program.** It searches `/usr/bin`, `/usr/sbin`, `/usr/local/bin`, `/usr/games`, `/opt`, `/usr/share`, `/usr/lib`, `/snap/bin`, plus your `~/.local/bin`, `~/.local/share`, `~/Applications`, `~/bin`, and the npm/bun/cargo/deno bin dirs. You pick one or more results by number (`4`, or `4 3` / `4,3`), or type one or more paths. **The first one is the main program.** Pick several when one tool has several programs, e.g. Devin's CLI script `/usr/share/devin-desktop/bin/devin-desktop` and its app binary `/usr/share/devin-desktop/devin-desktop`: each one gets its own wrapper and all of them run in the same `[section]`. If you pick a symlink and also its target (`/usr/bin/devin-desktop` → `…/bin/devin-desktop`), only the target is wrapped: the symlink already leads to that wrapper. `.desktop` files are not listed as programs.
2. **Profile name** (its `[section]`), plus **type**: `cli` or `gui`. It guesses `gui` if a menu launcher matches or the app is Electron.
3. **Project folder:** `cwd` for CLIs, `~/Workspace` for GUIs by default.
4. **Its files in your home, rated.** First it asks for **other names** its files may use (VS Code: `code` → also `vscode`, `Code`; a hint is pre-filled for known tools). It looks directly inside `~`, `~/.config`, `~/.local/share`, `~/.local/state` and `~/.cache` and shows every match as a table, most important first:
   ```
      #  type  importance   path
      1  dir   ##### 5/5    ~/.copilot/
                              main config: settings, login, extensions  -> suggested: read-write
      2  file  ####. 4/5    ~/.copilot.json
                              config file: settings/login (lost each run if skipped)  -> suggested: read-write file
      3  dir   ###.. 3/5    ~/.local/state/copilot/
                              state/logs: works without, forgets between runs  -> suggested: read-write
      4  dir   ..... 0/5    ~/.config/github-copilot/
                              SECRET (~/.config/github-copilot) - never visible inside  -> suggested: BLOCKED
   ```
   Importance: **5** main config dir (`~/.<name>`, `~/.config/<Name>`), **4** config file or `~/.local/share/<name>`, **3** `~/.local/state`, **2** cache (rebuilt each run if skipped) or a plain non-dot folder, **1** the name only *contains* the term (probably another program), **0** blocked (a secret). Anything you skip is gone after each run, because `$HOME` inside is an empty tmpfs. **Blocked** entries can't be picked: a known secret (the same list the launcher uses). A path another tool already uses **can** be picked: it shows `hint: SHARED with [tool], both will see it`. Answer **Enter** to take all suggestions, or **n** to decide each one (folder: `w` read-write / `r` read-only / `n` skip; file: `w` / `n`). Then you can **add paths by hand** (e.g. a folder nested elsewhere). Those are checked the same way, and a path that doesn't exist yet is created at the first run.
5. **The move.** Prefix for the real program (default `.ai-real-`), then a confirmation: `<path>` → `<dir>/.ai-real-<name>`, wrapper at `<path>`, for each picked program. How it moves:
   - a file **owned by a Debian package** → `dpkg-divert --rename` (with sudo), so package upgrades go to `.ai-real-<name>`;
   - any other file in a folder you can't write → `sudo mv`;
   - your own files → plain `mv`.
5b. **Program folder (home installs only).** If the program lives in your home, it offers read-only access to its folder. For an npm package it offers the whole package folder (`…/node_modules/<pkg>`). If the program is a symlink into a `versions/` folder (Claude Code style: `~/.local/bin/claude` → `~/.local/share/claude/versions/<ver>`), or sits in one, it also adds `exec-newest = <that folder>/*`.
6. **Extra arguments, environment variables, and the tools it runs.** `Tools it may run, with their files` lists your other tools; the names you give become `runs =`. Menu launchers need nothing: they start the original path, which is now the wrapper. For Electron apps the suggested arguments are `--ozone-platform=wayland --password-store=basic`.
7. **aisup:** yes or no. For a GUI app outside your home, `exec-allow = <app dir>/*` is added automatically.
8. **Save.** It shows the new `[section]` and runs the same checks as the launcher (files shared with another tool only print a hint). If you confirm, it appends the section to your `tools.conf` and does the move(s).

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
runs = copilot                    # other sandboxed tools it starts (see below)
```

- `#` starts a comment anywhere on a line.
- `shell` is a reserved name.
- A section without `wrapped =` is skipped by `list` with a warning (nothing would start it sandboxed).
- **Several programs in one tool:** repeat `exec =` + `wrapped =` as pairs, in order (the Nth `exec` is the real program behind the Nth `wrapped`). The first pair is the main program; `exec-newest` only applies to it. The numbers must match, or the section is refused.
  ```ini
  [devin]
  exec = /usr/share/devin-desktop/.ai-real-devin-desktop        # main: the app binary
  wrapped = /usr/share/devin-desktop/devin-desktop
  exec = /usr/share/devin-desktop/bin/.ai-real-devin-desktop    # its CLI script
  wrapped = /usr/share/devin-desktop/bin/devin-desktop
  ```
  An extra program's wrapper runs `ai-sandbox run --via <its path> <tool>`, and the launcher only accepts a `--via` path listed in that section. Inside the sandbox every `wrapped` path is its real program again, so the programs can call each other (the CLI script runs the app binary, not a second sandbox). `list`, `remove` and the shell hook handle every pair.
- **`runs = B C …`**: this tool starts those sandboxed tools (an editor runs `copilot`, a CLI runs a GUI app). They run inside *this* tool's sandbox, so it also gets their `rw`, `rw-file`, `ro`, `env-set`, `env-pass` and `exec-allow`, all through the same secret checks. If one of them is `type = gui`, a `cli` tool also gets the GUI parts (Wayland socket, GPU, `/sys` read-only, runtime dir; its `/tmp` stays fresh). With no Wayland session it warns and starts anyway, without them. An unknown name is ignored with a warning.
  ```ini
  [code]
  wrapped = /usr/bin/code
  exec = /usr/bin/.ai-real-code
  type = gui
  rw = ~/.config/Code
  runs = copilot          # copilot inside VS Code finds its login in ~/.copilot
  ```
- **Several tools may use the same files** (`[code]` and `[copilot]` both `rw = ~/.copilot`). That is allowed. `add` and `list` print `hint: [x] '~/.copilot' is shared with [y]: both tools see it`; the launcher says nothing.
- `desktop =` (old design) is ignored.

The default tools:

| Tool | Program | Read-write | Read-only | Notes |
|---|---|---|---|---|
| `claude` | `~/.local/bin/claude` | `~/.claude`, `~/.claude.json` | `~/.local/share/claude` | `DISABLE_AUTOUPDATER=1`; passes `ANTHROPIC_API_KEY` |
| `copilot` | `~/.local/bin/copilot` | `~/.copilot` | — | passes `GH_TOKEN`, `GITHUB_TOKEN`, `COPILOT_GITHUB_TOKEN` |
| `cursor` | `/usr/share/cursor/cursor` | `~/.config/Cursor`, `~/.cursor`, project `~/Workspace` | — | gui; Wayland, no keyring; root-owned folder → `list` uses sudo |

---

## Updates, packages and secrets

- **Tools that update into a `versions/` folder** (Claude Code). Tested with the real updater (2.1.311 → 2.1.325): it sees that `~/.local/bin/claude` is not its symlink, prints *"auto-update leaves it untouched"*, and only adds the new version under `versions/`. The wrapper stays byte-identical, also when you re-run the official installer.
  - **Old versions pile up.** Because of the wrapper, the updater says it *"cannot tell which version your launcher needs, so it keeps them all"*. Delete old folders in `~/.local/share/claude/versions/` yourself now and then; `exec-newest` always runs the highest one.
  - **This is what those versions do, not a promise.** Anthropic can change the updater. `../vm-test` installs *today's* stable and latest each run, so re-run `tests/run-all.sh 00 60 97` after a big Claude update. If a future updater does overwrite the wrapper, the fallback still works (tested by `global-test.sh` #6): the shell hook (every new terminal) sees the wrapper is gone and wraps the new program again. In between, `claude` from an **already open** terminal runs unsandboxed. Check with `ai-sandbox-admin list`.
- **`exec-newest = GLOB`** handles that: at every start the launcher runs the **highest version** among the *executable files* matching GLOB, compared with `sort -V` (so `1.10` > `1.9`; names, not file times). `.ai-real-<tool>` stays a **symlink**; the shell hook (a new terminal) re-points it to that newest version, so running `.ai-real-<tool>` directly and undo use the newest too. If your `tools.conf` predates this, add `exec-newest = ~/.local/share/claude/versions/*` under `[claude]`.
- **Files owned by a Debian package** (e.g. Cursor in `/usr/share/cursor`) are moved with `dpkg-divert --rename`, not `mv`. Tested with a real apt repo: `apt upgrade` and `apt install --reinstall` install the new version to `.ai-real-<tool>`, the wrapper stays byte-identical and `dpkg -V` stays clean. `remove` and undo remove the diversion again.
  - **`apt remove` of a wrapped package** deletes the real program but not our wrapper (dpkg doesn't know it). The wrapper is then an orphan: running it says *"its Debian package was probably removed; clean up with: ai-sandbox-admin remove <tool>"*, and a new terminal warns the same. Run that command.
- **npm tools in your home:** `add` gives read-only access to the whole package folder (`…/node_modules/<pkg>`), not only its `bin/`.
- **Known secrets are never exposed**, whatever `tools.conf` says. No project, `rw` or `ro` may be, contain or sit inside one of them. Symlinks are resolved first. The built-in list covers:
  - keys and credentials: `~/.ssh`, `~/.gnupg`, `~/.password-store`, `~/.pki`, `~/.netrc`, `~/.git-credentials`, `~/.local/share/keyrings`, 1Password (`~/.config/op`), Bitwarden;
  - cloud: `~/.aws`, `~/.azure`, `~/.config/gcloud`, `~/.oci`, `~/.kube`, `~/.docker`, doctl, hcloud, `~/.terraform.d`, `~/.vault-token`, rclone;
  - developer tokens: `~/.config/gh`, hub, glab, `~/.config/github-copilot`, `~/.npmrc`, `~/.yarnrc.yml`, `~/.pypirc`, cargo and gem credentials;
  - browsers and mail: `~/.mozilla`, `~/.thunderbird`, Chrome, Chromium, Brave, Edge, Vivaldi, Opera — and **all of `~/snap` and `~/.var/app`** (snap and Flatpak apps, which keep their browser profiles there).
- **The list is a data file: `secrets.list`**, installed next to `lib.sh` (root install: `/usr/local/lib/ai-sandbox/secrets.list`, root-owned `644`, so `cat` it, and change it only with `sudo`). One `deny PATH` per line. A reinstall replaces it, so put your own changes in a **`secrets.conf`**, which no reinstall ever touches. Both are created for you, with comments and no rules:
  - **`/etc/ai-sandbox/secrets.conf`**: the admin's rules, created by a root install (root-owned `644`). Takes `deny ~/.config/mytool` and `allow ~/.pki` (un-hide a built-in entry), one per line. It is read last, so it has the final word.
  - **`~/.config/ai-sandbox/secrets.conf`**: your own rules, created on first use (mode `600`, never visible inside the sandbox). In a **root install it takes only `deny`**: it is your file, so a rule there may add secrets but never remove one (an `allow` line stops every tool from starting, with a message). In a user install it takes `deny` and `allow`.
- **It fails closed.** No tool starts if `secrets.list` is missing, has no `deny` line, has a line it doesn't understand, or isn't a full path, or if it or any folder above it is writable by group/others (a sticky root folder like `/tmp` is fine). In a root install it must also be owned by root. The same goes for `/etc/ai-sandbox/secrets.conf` if it exists: it must be root-owned and not group/world-writable, otherwise nothing starts (before, it was only ignored with a warning). A missing or tampered list never means "no secrets". `ai-sandbox-admin add` uses the same list to mark paths as BLOCKED.
- **The list is not complete.** It names known locations. A tool that stores its token somewhere else is not protected, so keep `rw`/`ro` narrow.
- **AI tool data is per tool by default, and shared only where you say so.** A tool sees only the paths in its own section (and those of the tools in its `runs =`). If its `rw`, `rw-file`, `ro` or fixed `project` is, contains or sits inside a path another tool lists, that is allowed, and `add`/`list` show a **hint** (`… is shared with [tool]: both tools see it`), so a shared login (e.g. `~/.copilot` for `[code]` and `[copilot]`) is always a visible choice. Symlinks are resolved first. A `cwd` project inside another tool's data is not refused either. Editor data such as `~/.config/Code` is not on the secrets list: give the editor its own entry (`[code]` with `rw = ~/.config/Code`), and any other tool that lists it shows up with a hint. **Nothing guards `~/.config/Code` against a tool you give it to**, and it can hold tokens (VS Code started with `--password-store=basic` keeps them there in an easily decrypted file).
- **The list protects you only in a root install.** In a user install `secrets.list` is in `~/.local/lib/ai-sandbox`, owned by you, and so is the launcher that reads it, so any program running as you can edit either one (tested: removing `~/.ssh` made the key readable).

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
  - A user install makes the programs just as editable as the config — including `secrets.list`.
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
| `claude` still unsandboxed | Run `ai-sandbox-admin list` and answer `y`. `head -2 ~/.local/bin/claude` must show `# ai-sandbox wrapper`. |
| `… must belong to you and not be group/world-writable` | `chmod 600 ~/.config/ai-sandbox/*.conf` |
| `… would be writable inside and contains …` | A `rw`/`project` path covers the sandbox's own files. Use a narrower path. |
| `refusing to expose '…'` | `cd` into a project folder first, or set `AI_PROJECT=`. |
| `run this as your normal user` | `add`, `remove` and `list` manage *your* config. Leave the root shell first. |
| `root already installed it system-wide` | No user install is needed. Just run `ai-sandbox-admin list`. |
| `aisup is not installed` | `apt install libseccomp-dev gcc`, then run `bash install.sh` again. |
| Cursor: *SUID sandbox helper … not configured* | Not needed on Debian 12: Chromium's sandbox works inside bwrap (tested). If your kernel blocks it anyway, add `--no-sandbox` to `args` in `[cursor]` and run `ai-sandbox-admin list`; bwrap is still the wall. |
| `cursor .` opens `cli.js` as a file | Your installed `ai-sandbox` is older than the Electron CLI fix. Re-run the install. |
| Cursor shows no window | `AI_DEBUG=1 ai-sandbox cursor` in a terminal and read the errors. |
| Claude: config not saved | Replace `rw-file = ~/.claude.json` with `env-set = CLAUDE_CONFIG_DIR=~/.claude`. |
| Copilot asks to log in every time | There's no keyring inside. Export `GH_TOKEN` before starting it. |
| Too many aisup prompts | Read `~/.local/state/aisup.log` and add `allow` lines above `default ask` in your `policy.conf`. |
| CLI doesn't redraw on resize | Use `AISUP=1 AI_NEW_SESSION=0`. |
| `make`: `missing separator` | `Makefile` recipe lines must start with a TAB. |

## Log and undo

Every change on disk is logged by `ai-sandbox-admin` (install, add, remove, list, uninstall, the shell hook's re-wraps) and by `ai-sandbox` (folders and files it creates for a tool). Anything overwritten or deleted is copied to `backups/` first.

| Who | Log | Backups |
|---|---|---|
| root | `/var/lib/ai-sandbox/actions.log` | `/var/lib/ai-sandbox/backups/` |
| you | `~/.local/state/ai-sandbox/actions.log` | `~/.local/state/ai-sandbox/backups/` |

A command that changes nothing writes nothing. Changes made with `sudo` (e.g. wrapping Cursor) are in *your* log, marked `sudo`, and their undo uses sudo too.

```sh
ai-sandbox-undo                 # runs that can still be undone, newest first, with their changes
ai-sandbox-undo last            # undo the newest run (asks first; -y = don't ask, -n = dry run)
ai-sandbox-undo <RUN-ID>        # undo one run
ai-sandbox-undo all             # undo everything → back to before the install
ai-sandbox-undo purge           # after `all`: delete the log, backups, this tool, aisup.log
                                # and the empty folders it created.
                                # Before `all`: only frees space (backups of undone runs)
```

- **It can stop anywhere.** Every change is logged *before* it is made, so a Ctrl-C, a crash, a power cut or a failing command never leaves a change the log doesn't know about. Undo recognises logged changes that never happened and skips them quietly. An undo that stopped half-way continues where it left off when you run it again. `../vm-test` (test 98) kills install, list, uninstall and undo with SIGKILL at **every single step**, for a user install, a root install, and a `dpkg-divert` of a package file. Each time, `undo all` + `purge` gives back the home and the system **byte for byte** as before, except for the tool data and newer versions listed under *What stays* below.
- **Which undo to run.** The very first thing `install` does is put the undo tool next to the log, so even an install that stopped at its first step can be undone with `~/.local/state/ai-sandbox/ai-sandbox-undo all` (root: `/var/lib/ai-sandbox/ai-sandbox-undo all`).
- **Shell rc files** (`~/.bashrc`, `~/.zshrc`, `/etc/bash.bashrc`, `/etc/zsh/zshrc`): undo removes exactly the 2 lines the install added. Your own later edits stay. A leftover hook line is harmless anyway: it only runs if its script exists.

- **Safe by default.** Before reversing a change, it checks that the thing still looks the way the log says. The check compares content (a sha256 hash), not mtime: rewriting the same content does not count as a change. If you or an update changed it since (e.g. you edited `tools.conf` by hand), that step is skipped and reported. `-f` forces it, after saving the current version to `backups/forced-*`.
- **Non-empty folders are never deleted**, even with `-f` (e.g. `~/.claude` once the tool has saved data in it).
- **Undoing the install or an uninstall** removes or restores `ai-sandbox-undo` itself. For that case, use the copy next to the log, which always stays: `~/.local/state/ai-sandbox/ai-sandbox-undo` (root: `/var/lib/ai-sandbox/ai-sandbox-undo`).
- **Re-wraps after an update** are logged as notes, not as changes: undoing the install leaves the *newest* version of the tool in place. The obsolete old version is dropped, not backed up.
- **Backups** hold every file the setup overwrote or deleted. `ai-sandbox-undo purge` frees the ones no longer needed.

## Uninstall

```sh
ai-sandbox-admin remove --all   # each user: put the real programs back (config kept)
su -; ai-sandbox-admin uninstall   # root install
ai-sandbox-admin uninstall      # or, for a user install (also removes all; asks about config)
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

### Remove everything

Run these to remove every file, folder and edit that ai-sandbox made, and go back to the state before the install. First **close every sandboxed tool** (claude, copilot, VS Code, Cursor…).

**User install** (`~/.local`):

```sh
U=~/.local/state/ai-sandbox/ai-sandbox-undo   # the copy next to the log: it survives uninstall

$U list                 # what can still be undone
$U -n all               # dry run: shows every step, changes nothing
$U all                  # undo everything: wrappers -> real programs, rc-file hooks,
                        # programs in ~/.local/bin + ~/.local/lib/ai-sandbox, your config
$U purge                # delete the log, backups, this undo tool, ~/.local/state/aisup.log
                        # and every EMPTY folder the sandbox created
```

If `all` reports **skipped** steps, the file was changed after it was made (typically `~/.config/ai-sandbox/tools.conf` that you edited by hand, or added tools to with `add`). Look at what it says, then force those steps:

```sh
$U -f all               # saves the current version to backups/forced-* first
cp -r ~/.local/state/ai-sandbox/backups/forced-* ~/somewhere/   # keep them? purge deletes backups
$U purge
```

**Root install** (`/usr/local`): every user first runs the user steps above (their wrappers, and `dpkg-divert`s made with sudo, are in *their* log). Then as root:

```sh
su -
/var/lib/ai-sandbox/ai-sandbox-undo all
/var/lib/ai-sandbox/ai-sandbox-undo purge
rm -r /etc/ai-sandbox   # only if it is still there: uninstall keeps secrets.conf once you edited it
```

**Check that nothing is left.** Each command should print nothing:

```sh
ls -d ~/.config/ai-sandbox ~/.local/lib/ai-sandbox ~/.local/state/ai-sandbox \
      ~/.local/state/aisup.log ~/.local/bin/ai-sandbox* "$XDG_RUNTIME_DIR/ai-sandbox" \
      /usr/local/lib/ai-sandbox /usr/local/bin/ai-sandbox* /var/lib/ai-sandbox /etc/ai-sandbox 2>/dev/null
grep -n 'ai-sandbox' ~/.bashrc ~/.zshrc /etc/bash.bashrc /etc/zsh/zshrc 2>/dev/null   # hook lines
find ~/.local/bin ~/.local/share /usr/local /usr/share /opt -maxdepth 3 -name '.ai-real-*' 2>/dev/null   # moved programs
grep -rlI 'ai-sandbox wrapper' ~/.local/bin /usr/local/bin /usr/share /opt 2>/dev/null   # wrappers left
dpkg-divert --list 2>/dev/null | grep ai-real                                            # package diversions
```

If something still shows up:

| Left over | Why | Remove with |
|---|---|---|
| `$XDG_RUNTIME_DIR/ai-sandbox/` | runtime folder (sockets, private `/tmp`); it's in RAM and goes away at logout/reboot | `rm -rf "$XDG_RUNTIME_DIR/ai-sandbox"` |
| `~/.config/ai-sandbox/` | skipped because you edited it, and not forced | `rm -r ~/.config/ai-sandbox` |
| a wrapper and its `.ai-real-<x>` | an update replaced something in a way undo couldn't verify | `mv <dir>/.ai-real-<x> <dir>/<x>` (it overwrites the wrapper) |
| a `dpkg-divert` | root-owned program wrapped with sudo | `sudo rm <path> && sudo dpkg-divert --local --rename --divert <dir>/.ai-real-<x> --remove <path>` |
| `/etc/ai-sandbox/secrets.conf` | kept by uninstall because you edited it | `sudo rm -r /etc/ai-sandbox` |

**Never removed, on purpose:** the tools' own data, such as `~/.claude`, `~/.claude.json`, `~/.copilot`, `~/.config/Code`, `~/.vscode`, `~/.config/Cursor` and `~/.cursor`. The tools use these without the sandbox too, and they hold your logins, history and settings. Undo only removes such a folder if the sandbox created it and it is still empty. Delete them yourself only if you want to remove **the tools'** data as well (that logs you out of them).

## Not implemented yet

- **Network allowlist:** a private network namespace (`pasta`) plus a proxy that only allows each tool's API domains. Until then, treat every sandboxed tool as able to upload its project.
