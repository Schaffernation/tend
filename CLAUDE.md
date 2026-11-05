# Tend

Tend restores and manages long-running tmux sessions, with app-aware support
for programs like Claude Code. `bin/tend` (Python, standard library only) holds
all behavior; `app/Tend.swift` is a menu bar client that runs `tend ... --json`.
Tend ships outside the Mac App Store, as a Developer ID signed, notarized disk
image. It can't run in the App Sandbox, because it drives tmux and other apps.

Before changing the design, or when you need to know why something is the way
it is, read `docs/intent.md`. It holds the original intent, the decisions and
their reasons, the tmux-as-runner question, and the open threads (including
what's untested).

## Working here

- Add behavior to the CLI first, with `--json` output if the app needs it.
  Then expose it in the app.
- Support for a new program is an app profile (data) first. Add code, like a
  new `preflight` check, only when a profile can't express it.
- the user's real sessions are live on this machine. Test with a scratch config and
  throwaway commands like `sleep`:

  ```
  TEND_CONFIG=/path/to/scratch.json tend add t --dir /tmp --start -- sleep 600
  ```

  Ask the user before you restart, stop, or restore any real session, or start a
  real `claude rc`.
- After changing `app/` or `bin/tend`, run `app/build.sh`. It builds a
  universal app, copies `bin/tend` into `Contents/Resources`, installs to
  `/Applications/Tend.app` (shared by every account), and reopens the user's
  copy. Build warnings count as failures. Opening the app runs `tend restore --once`, which starts
  stopped sessions on the first launch after the Mac starts, so ask the user
  before you install.
- To test with a tmux server separate from the user's, run `unset TMUX` and set
  `TMUX_TMPDIR` to a short folder path. Inside a tmux session, `TMUX` points
  every tmux command at the user's real server, whatever `TMUX_TMPDIR` says. tmux
  socket paths must be under about 100 characters, so a deep scratch folder
  fails. Check with `tmux display -p '#{socket_path}'` before you change
  anything. `open -n --env TEND_CONFIG=... --env TMUX_TMPDIR=...
  app/build/Tend.app` runs a built app against that setup.
- The app runs its bundled copy of `tend`, not `~/.local/bin/tend`. On the user's
  Mac, `~/.local/bin/tend` links to `bin/tend` for the terminal.
- `app/release.sh` builds, signs, notarizes, and packages a disk image.
  `app/make-icon.swift` draws the icon; rerun it after changing the design.
- Use `.help` tooltips for hover text in the app.
- `skills/tend/SKILL.md` is a Claude Code skill that drives the CLI, linked
  from `~/.claude/skills/tend`. When you change a command it uses, update the
  skill too.

## Gotchas

- In zsh, quote tmux targets that start with `=`: `tmux has-session -t '=name'`.
  An unquoted `=name` expands to a command path and aborts the command line.
- SourceKit reports "'main' attribute cannot be used in a module that contains
  top-level code" for `Tend.swift`. It's a false alarm: `build.sh` compiles
  with `-parse-as-library`.
- tmux session names can't contain `.` or `:`. `session_name()` replaces them.
- The running app polls its bundled `tend ls`, which saves resume commands.
  After you change how `bin/tend` computes them, rebuild the app, or its old
  copy writes the old commands back within 5 seconds.
- `tend ls` saves resume commands as a side effect. Use `status(cfg, sync=False)`
  when you need a read-only scan.
