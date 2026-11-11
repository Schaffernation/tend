# Contributing to Tend

Thanks for helping. This page covers how the project is laid out, how to test
a change without disturbing your own sessions, and what a pull request needs.

Before you change the design, read [docs/intent.md](docs/intent.md). It
records why Tend works the way it does, and which parts are still untested.

## How the project is laid out

- `bin/tend` is the command-line tool: one Python file that uses only the
  standard library. It holds all of Tend's behavior.
- `app/Tend.swift` is the menu bar app. It runs its bundled copy of
  `tend ... --json` and shows the result. It has no behavior of its own.
- `app/build.sh` builds the app, and `app/release.sh` builds a signed,
  notarized disk image.
- `skills/tend` is a Claude Code skill that drives the CLI.

Three rules keep the project in shape:

- **Add behavior to the CLI first.** If the app needs it, give the command a
  `--json` option, and then show it in the app.
- **Add a program as data first.** Support for a new program is an app
  profile, like the built-in Claude profile in `bin/tend`. Add code, like a
  new `preflight` check, only when a profile can't express what you need.
- **Keep `bin/tend` to the standard library.** It has to run on any Mac with
  `python3`, over ssh, with nothing to install.

## Set up

1. Install tmux: `brew install tmux`.
2. Clone the repository, and link the CLI so your terminal runs your copy:

   ```
   git clone https://github.com/schaffernation/tend.git
   cd tend
   ln -sfn "$PWD/bin/tend" ~/.local/bin/tend
   ```

3. To build the app without installing it, run `app/build.sh --no-install`.
   Without a Developer ID certificate, the build is signed ad hoc and runs
   only on your Mac.

## Test without touching your real sessions

If you use Tend yourself, your real sessions are running while you work. Test
against a scratch config and a separate tmux server instead.

1. Point tend at a scratch config:

   ```
   export TEND_CONFIG=/tmp/tend-test/config.json
   ```

2. Start a separate tmux server. Inside tmux, `TMUX` points every tmux command
   at your current server, so unset it first. tmux socket paths must be under
   about 100 characters, so use a short folder:

   ```
   unset TMUX
   export TMUX_TMPDIR=/tmp/tend-test
   mkdir -p $TMUX_TMPDIR
   tmux display -p '#{socket_path}'
   ```

   Check that the socket path is in your scratch folder before you go on.

3. Test with throwaway commands like `sleep`:

   ```
   tend add t --dir /tmp --start -- sleep 600
   tend ls
   ```

4. To run a built app against the same setup, run:

   ```
   open -n --env TEND_CONFIG=$TEND_CONFIG --env TMUX_TMPDIR=$TMUX_TMPDIR app/build/Tend.app
   ```

5. When you're done, stop the scratch server with `tmux kill-server`, in the
   same shell.

To test Claude support without starting a real `claude rc`, use a fake
`claude` script. A real one leaves a disconnected entry in your Claude app,
and answering its trust prompt changes `~/.claude.json`. tend matches a
script by its name, so a file named `claude` that prints the trust prompt is
enough to test `tend answer`:

```
#!/bin/sh
printf 'Trust %s? [y/N] ' "$PWD"; read a
```

## Run the tests

From the repository root, run:

```
python3 -m unittest discover tests
```

The tests need only Python. The end-to-end tests also need tmux. They start
their own tmux server in a folder under `/tmp` and stop it when they finish,
so they don't touch your sessions, even if you run them inside tmux. Without
tmux, they're skipped.

Add a test with each change to `bin/tend`. Keep logic that doesn't need tmux,
like parsing or matching, in functions that take plain data, so a unit test
can call them directly.

When you change the config or state, do it inside `edit_config()` or
`edit_state()`. They hold a lock and reload the file, so a change that the
menu bar app's poll saved in the meantime isn't lost.

## Build

After you change `app/` or `bin/tend`, run `app/build.sh --no-install`. The
build treats warnings as errors.

SourceKit reports "'main' attribute cannot be used in a module that contains
top-level code" for `Tend.swift`. It's a false alarm: `build.sh` compiles with
`-parse-as-library`.

If you change how the panel looks, run `app/screenshot/make.sh` to update the
screenshots in the README. It draws the real panel with example sessions, so
your own sessions don't appear.

## Write text the same way

Help text, error messages, tooltips, and docs follow the
[Google developer documentation style guide](https://developers.google.com/style):
second person, active voice, present tense, and no "simply" or "just". An
error message says what went wrong and what to do about it. In the app, hover
text goes in `.help` tooltips.

## Send a pull request

1. Open an issue first for anything bigger than a fix, so we can agree on the
   approach.
2. Keep a pull request to one change.
3. If you change a command that the skill uses, update
   `skills/tend/SKILL.md`. If you change a decision recorded in
   `docs/intent.md`, update it too.
4. Add an entry under **Unreleased** in [CHANGELOG.md](CHANGELOG.md).
5. Run the tests. GitHub Actions runs them, and builds the app, on every
   pull request.
6. In the description, say how you tested the change.

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
