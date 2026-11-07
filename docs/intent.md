# Tend: intent, design, and open threads

This file records why Tend exists, what was decided while building it, and
what's still open. It's the handoff from the session that built Tend in
a personal automation project (November 4, 2026).

## Why Tend exists

the user runs several Claude Code sessions as `claude rc` (Remote Control) inside
detached tmux sessions, started with `rc-spawn`, so they can drive them from
claude.ai/code or a phone. After a reboot, or when a session dies, they want
them back: same folders, and ideally the same conversations.

The requirements grew in this order:

1. A script that restores every Claude tmux session.
2. Maybe a Mac menu bar app that manages them.
3. Generic: a manager for background processes and restoring them, which also
   knows about Claude in particular.
4. Generic app recognition: pick Claude from a list of apps, where an app can
   be any program, recognized by process parentage.
5. A plus button that starts a new session, a generic `rc-spawn`.
6. Tend as its own project (this folder).

The direction: a general tool for long-running, restorable terminal processes,
with first-class support for programs (like Claude) that can tell Tend how to
resume them.

## Architecture

Two parts. All behavior lives in the CLI; the app is a thin client.

- **`bin/tend`** is a single-file Python 3 script that uses only the standard
  library. It owns the config, tmux, process detection, and start, stop, and
  restore. It must keep working over ssh, with no GUI.
- **`app/Tend.swift`** is a SwiftUI `MenuBarExtra` app, built with plain
  `swiftc` (no Xcode project). It runs its bundled copy of `tend ... --json` and
  renders the result. It polls `tend ls --json` and `tend apps --json` every
  5 seconds.

Keep this split: new behavior goes in the CLI first, and then the app exposes
it.

### Core concepts

- **Service**: a tracked tmux session. Fields: `name`, `dir`, `command` (what
  a fresh start types), `resume` (what a restore types, saved automatically),
  and `autostart`. Stored in `~/.config/tend/services.json`.
- **App**: a profile that tells Tend how to recognize a program and,
  optionally, how to read its state and resume it. Claude is the only built-in
  app (`BUILTIN_APPS` in `bin/tend`). The comment block above
  `BUILTIN_APPS` documents every field. Entries in the config's `apps` list
  override built-in apps by `id`, or add new ones.
- **Runner**: the engine that keeps processes alive in the background. Today
  this is always tmux. See [Is tmux core?](#is-tmux-core).

### How starting works

Tend creates a detached tmux session with a login shell in `dir`, then types
the command with `send-keys`. The shell loads the user's normal environment,
and it stays open when the command exits, so the error stays readable. Tend
shows that case as `exited`. This copies `rc-spawn`'s approach on purpose.

Before Tend starts a session, it makes sure that the tmux server runs inside
the `com.example.tmux-server` launch agent (the config's `tmux_launch_agent`), so
that sessions created over ssh can still read the login keychain. That
agent's source is in `~/Library/LaunchAgents/`.

### Restoring once per boot

The app runs `tend restore --once` when it opens. tend records the boot time
in `state.json`, next to the config, and restores only on the first run after
the Mac starts. The tmux server doesn't depend on the app, so a crash or
relaunch of the app must not touch sessions: a session you stopped on purpose
stays stopped. `tend restore` without `--once` always restores.

### Other accounts

Each account runs its own Tend, and each Tend keeps only its own account's
sessions alive. We considered running another account's sessions from this
one, as a system launch daemon with that account's user. We chose not to:
that account's login keychain stays locked without a login, so Claude Code
needs a separate token. Background processes can't get macOS privacy
permissions. Apps that need a desktop, like Photos, can't run at all.

Instead, `tend accounts` watches other accounts and warns when one isn't
logged in or isn't running Tend. macOS can't log a second account in on its
own, so a person still logs it in after a restart. The check uses only the
process list (`pgrep -u USER loginwindow` and `Tend`), so it needs no shared
files and no access to the other account.

### How detection works

Each status check (`tend ls`) combines three sources:

1. `tmux list-panes -a` gives each session's panes, folder, and shell PID.
2. `ps -ax -o pid,ppid,command`, plus `proc_pidpath` from libproc (through
   ctypes) for real executable paths, gives the process tree. Tend walks down
   from each pane's shell. The highest process that matches an app wins, so
   programs that start copies of themselves, like Claude, show up once.
3. App metadata files. Claude writes `~/.claude/sessions/<pid>.json`. Tend
   links a file to a session when the file's `pid` is a process inside that
   session's panes. From that file, Tend reads `status` (busy or idle), `name`,
   and the IDs that its resume templates need.

`tend ls` also saves the current resume command for each running tracked
service, so a restore uses the latest conversation. That side effect is
deliberate.

### Claude specifics

- Remote Control resume: the same command, like `claude rc`. When Remote
  Control stops, it keeps its environment, and a plain restart reconnects the
  last conversation in server mode, where the Claude app's plus button starts
  new sessions in that folder. Tend used `--session-id {bridgeSessionId}`
  before, and `--continue` is the other option. Both reconnect in
  single-session mode, which grays out the plus button, and `--continue` only
  works for about 4 hours.
- Remote Control forgets an environment after a while, and then a plain
  restart starts a new conversation. So tend records every conversation ID it
  sees in `state.json` (`history`, the last 20 per service), and
  `tend resume` brings one back with `--session-id`, in single-session mode.
  A later plain restart returns to server mode and keeps the conversation.
- After a single-session process stops, Remote Control needs about 45
  seconds to release the folder; starting sooner fails with "already
  served". The profile's `release_wait` covers it.
- Restarting the session tend runs in: tend hands the command to the tmux
  server with `run-shell -b`, marked with `TEND_HANDED_OFF`, because
  `run-shell` sets `TMUX` and `TMUX_PANE` and the handed-off command would
  otherwise hand off again forever.
- Interactive resume: `claude --resume {sessionId}`.
- `strip_flags` removes `--continue`, `--session-id`, and `--resume` from the
  saved `command`, so **Start fresh** really is fresh.
- Trust: in a folder that isn't trusted (itself or a parent, in
  `~/.claude.json`), `claude rc` prints `Trust FOLDER? [y/N]` and waits.
  `y` connects, and Claude records the trust itself. `n` exits with "is not
  trusted". (Tested with 2.1.318. Older versions exited right away, which is
  why `preflight: "claude-trust"` first refused to start there.) Now the
  profile's `questions` entry recognizes the prompt, the app shows Trust and
  Don't trust buttons on the row, and `tend answer NAME yes|no` types the
  reply. The preflight only prints a note saying where to answer.

## Decisions and why

- **Python standard library only** for the CLI, so it runs anywhere the user has
  `python3`, including over ssh, with no install step.
- **Typing the command into a shell** instead of `tmux new-session <cmd>`, for
  the user's environment and readable errors.
- **Tooltips, not a hint line.** One version showed hover help in a line at
  the bottom of the panel. the user preferred standard `.help` tooltips. Keep the
  descriptive tooltip text.
- **Apps are data, not code.** Claude's support is a profile in the same
  format that users write. A new program's support should be a profile first,
  and code (like a `preflight` check) only when data can't express it.
- **App icons come from installed apps, not favicons.** A profile's `icon` is
  a bundle ID or a path, and the app asks macOS for that app's icon. This
  works offline and matches what's in the Dock. Claude's profile uses the
  Claude desktop app's icon, even though the program is Claude Code.
- **Answer Claude's own trust prompt; don't write `~/.claude.json`.** Setting
  `hasTrustDialogAccepted` ourselves would be simpler, but that file is
  Claude's, and running Claude processes rewrite it often. `tend answer`
  checks that the question is still on screen before it types, so it never
  types `y` into a shell.
- **Setup runs once, outside the session.** `tend new --setup CMD` (or
  `--recipe ID --input TEXT`) runs in the folder before tend tracks the
  session, with the login shell's environment, so a failed clone shows its
  error in the form and starts nothing. It's never saved as the command, so
  restarts don't repeat it. `claude rc` takes no starting prompt, so a recipe
  that copies in a `CLAUDE.md` is the way to give new folders instructions.
  Recipes are data (`recipes` in the config); `clone` is built in.
- **Scripts match by their own name.** A script run by an interpreter (like
  `sh tailscale-keepalive`) looks like `sh` to the process table, so matching
  also checks the script's name and path. Without that, no profile could
  recognize a shell script.
- **`tend new --command STRING`** passes a raw shell string, because the app
  can't split a command into arguments safely.
- **The app's new-session form lives in the model**, not view state, because
  the menu bar panel can close while a folder picker is open.

## Is tmux core?

Discussed and settled for now: yes, tmux stays the engine. It provides a
terminal for interactive programs, attaching from anywhere (including ssh),
and processes that outlive both the terminal and Tend itself. An app that
owned the processes directly would kill them on every rebuild, unless it
grew a daemon, which would amount to rebuilding tmux.

tmux doesn't restart crashed commands, keep logs, or survive reboots. Restore
covers reboots.

The agreed shape for the future: treat tmux as one **runner** behind a
narrow boundary (start, stop, attach, and "what's the root PID"). A `launchd`
runner could suit headless services that should restart on a crash and log to
files, like dev servers. Detection, apps, and the UI would carry over
unchanged, because they only need a root PID. Build that runner when a real
headless service needs it, not before. Until then, keep tmux calls together
in `bin/tend`.

## Open threads

Untested, in rough order of risk:

1. **How long Remote Control keeps its environment.** A plain `claude rc`
   restart reconnected the last conversation a minute later. Whether it still
   does after a night, or after a reboot, isn't confirmed. If the environment
   has expired, the restart starts a new conversation, and the old one stays
   in the app's history.
2. **The plus button** starting a real `claude rc` session.
3. **The app's UI** hasn't been seen by an agent: the panel, the Apps section,
   the new-session form, and the folder pickers (`NSOpenPanel` from a menu bar
   panel can appear behind other windows).
4. **Open in terminal** (iTerm through AppleScript). The first use will
   probably ask for Automation permission.
5. **Open at login** through `SMAppService` with an ad hoc signed app.

Ideas raised but not built:

- A `launchd` runner (see above).
- UI for app metadata and resume templates. Today, only the config file can
  set them for custom apps.
- `rc-spawn` (in the automation project) could become a thin wrapper around
  `tend new claude`. Today it starts the session itself and then registers it
  with `tend add`.
