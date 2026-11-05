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

## Install

1. Link the command-line tool:

   ```
   ln -sfn ~/src/tend/bin/tend ~/.local/bin/tend
   ```

2. Build and install the menu bar app in `~/Applications`:

   ```
   ~/src/tend/app/build.sh
   ```

3. In the Tend panel, turn on **Open Tend at login**. Tend restores your
   sessions each time it opens.

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

For the design and the reasons behind it, see [docs/intent.md](docs/intent.md).
