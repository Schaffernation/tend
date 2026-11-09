# Tend

Tend restores and manages long-running tmux sessions, with app-aware support
for programs like Claude Code. `bin/tend` (Python, standard library only) holds
all behavior; `app/Tend.swift` is a menu bar client that runs `tend ... --json`.
Tend ships outside the Mac App Store, as a Developer ID signed, notarized disk
image. It can't run in the App Sandbox, because it drives tmux and other apps.

Before changing the design, or when you need to know why something is the way
it is, read `docs/intent.md`. It holds the original intent, the decisions and
their reasons, the tmux-as-runner question, and the open threads (including
what's untested). `CONTRIBUTING.md` covers setup and the pull request process.

## Working here

- Add behavior to the CLI first, with `--json` output if the app needs it.
  Then expose it in the app.
- Support for a new program is an app profile (data) first. Add code, like a
  new `preflight` check, only when a profile can't express it.
- Assume the machine you're on has real sessions running, possibly including
  the conversation you're in. Test with a scratch config and throwaway
  commands like `sleep`:

  ```
  TEND_CONFIG=/path/to/scratch.json tend add t --dir /tmp --start -- sleep 600
  ```

  Ask the user before you restart, stop, or restore any real session, or
  start a real `claude rc`.
- After changing `app/` or `bin/tend`, run `app/build.sh --no-install` to check
  the build. Build warnings count as failures. Without `--no-install`,
  `build.sh` also installs to `/Applications/Tend.app` (shared by every
  account) and reopens the user's copy. Opening the app runs
  `tend restore --once`, which starts stopped sessions on the first launch
  after the Mac starts, so ask the user before you install.
- To test with a tmux server separate from the user's, run `unset TMUX` and
  set `TMUX_TMPDIR` to a short folder path. Inside a tmux session, `TMUX`
  points every tmux command at the user's real server, whatever `TMUX_TMPDIR`
  says. tmux socket paths must be under about 100 characters, so a deep
  scratch folder fails. Check with `tmux display -p '#{socket_path}'` before
  you change anything. `open -n --env TEND_CONFIG=... --env TMUX_TMPDIR=...
  app/build/Tend.app` runs a built app against that setup.
- The app runs its bundled copy of `tend`, not `~/.local/bin/tend`. A
  developer's `~/.local/bin/tend` usually links to this repo's `bin/tend`, so
  edits to `bin/tend` take effect in the terminal right away.
- `app/release.sh` builds, signs, notarizes, and packages a disk image.
  `app/make-icon.swift` draws the icon; rerun it after changing the design.
- Use `.help` tooltips for hover text in the app.
- `skills/tend/SKILL.md` is a Claude Code skill that drives the CLI, usually
  linked from `~/.claude/skills/tend`. When you change a command it uses,
  update the skill too.
- Write docs, help text, and messages in the style of the Google developer
  documentation style guide: second person, active voice, present tense.

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
- `tend open` fails from inside a tmux session whose server runs under
  launchd, with "Not authorized to send Apple events" (-1743), because macOS
  can't ask for permission for it. Don't reset Automation permissions with
  `tccutil`. Ask the user to run it in iTerm, or to use the app.
- A real `claude rc` test leaves a disconnected entry in the user's Claude
  app, and answering its trust prompt adds the folder to `~/.claude.json`. To
  test `questions` and `tend answer`, use a fake `claude` script on a scratch
  tmux server instead: `printf 'Trust %s? [y/N] ' "$PWD"; read a`. tend
  matches it by the script's name.
- `tend ls` saves resume commands as a side effect, through `sync()`.
  `status()` only reads, so use it alone when you need a read-only scan.
- Change the config or state only inside `edit_config()` or `edit_state()`,
  which hold the lock and reload the file. Saving a config you loaded earlier
  can overwrite another process's change.
- Run the tests with `python3 -m unittest discover tests`. They use their own
  tmux server and config, so they don't touch real sessions.
