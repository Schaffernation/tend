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
  `~/Applications/Tend.app`, and reopens the app. Build warnings count as
  failures. Opening the app runs `tend restore --once`, which starts
  stopped sessions on the first launch after the Mac starts, so ask the user
  before you install.
- To test with a tmux server separate from the user's, also set `TMUX_TMPDIR` to
  a scratch folder. `open -n --env TEND_CONFIG=... --env TMUX_TMPDIR=...
  app/build/Tend.app` runs a built app against that setup.
- The app runs its bundled copy of `tend`, not `~/.local/bin/tend`. On the user's
  Mac, `~/.local/bin/tend` links to `bin/tend` for the terminal.
- `app/release.sh` builds, signs, notarizes, and packages a disk image.
  `app/make-icon.swift` draws the icon; rerun it after changing the design.
- Use `.help` tooltips for hover text in the app.

## Gotchas

- In zsh, quote tmux targets that start with `=`: `tmux has-session -t '=name'`.
  An unquoted `=name` expands to a command path and aborts the command line.
- SourceKit reports "'main' attribute cannot be used in a module that contains
  top-level code" for `Tend.swift`. It's a false alarm: `build.sh` compiles
  with `-parse-as-library`.
- tmux session names can't contain `.` or `:`. `session_name()` replaces them.
- `tend ls` saves resume commands as a side effect. Use `status(cfg, sync=False)`
  when you need a read-only scan.
