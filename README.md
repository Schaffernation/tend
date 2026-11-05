# Tend

Tend keeps a list of long-running terminal sessions and brings them back. Each
session runs in tmux, so it keeps running after you close your terminal or
disconnect from ssh. After a reboot, `tend restore` starts them again.

Tend recognizes the programs running in each session from a list of apps.
Claude Code is built in: Tend shows whether Claude is busy or idle, and a
restore reattaches to the same Claude conversation instead of starting a new
one. You can add any other program as an app.

Tend has two parts:

- `tend`, a command-line tool. It works over ssh.
- Tend.app, a menu bar app that shows your sessions and runs `tend` for you.

## Requirements

- macOS 14 or later, on Apple silicon or Intel.
- tmux. To install it, run `brew install tmux`.
- Python 3. If you have Homebrew or the Xcode Command Line Tools, you already
  have it.

## Install

1. Download `Tend-VERSION.dmg` from
   [Releases](https://github.com/Schaffernation/tend/releases), open it, and
   drag Tend to **Applications**.
2. Open Tend. It appears in the menu bar.
3. In the Tend panel, turn on **Open Tend at login**. The first time Tend
   opens after your Mac starts, it restores your sessions. If you quit Tend
   or it crashes, your sessions keep running, and opening Tend again doesn't
   start or stop anything.
4. To use `tend` in a terminal, click **Install command-line tool**. It links
   `tend` into `~/.local/bin`, which needs to be on your `PATH`.

To build from source instead:

```
git clone https://github.com/Schaffernation/tend.git
tend/app/build.sh
ln -sfn "$PWD/tend/bin/tend" ~/.local/bin/tend
```

`build.sh` installs the app in `~/Applications` and opens it.

## Open sessions with iTerm2's tmux integration

The open button attaches to a session in a new terminal window. To use iTerm2's
tmux integration instead, which shows each tmux window as a native iTerm2
window or tab, open the **Terminal** section in the Tend panel and set
**Attach with** to **iTerm2 tmux integration (tmux -CC)**. Or run:

```
tend terminal --app iTerm --attach control
```

To run your own command, pass it to `--attach`. In the command, `{tmux}` is
the path to tmux, `{target}` is the session's tmux target, and `{name}` is
the session name:

```
tend terminal --attach '{tmux} -CC attach -d -t {target}'
```

## Use

To track every tmux session that's running now:

```
tend snapshot
```

To start a new Claude Remote Control session in the current folder:

```
tend new claude
```

To see everything, including sessions you haven't tracked:

```
tend ls
```

For all commands, run `tend --help`. Your sessions and apps are stored in
`~/.config/tend/services.json`.

## Release

To build a signed, notarized disk image, run `app/release.sh`. The script
explains the one-time notarization setup in its header.

For the design and the reasons behind it, see [docs/intent.md](docs/intent.md).
