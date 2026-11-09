# Security

## Report a problem

To report a security problem, use GitHub's
[private vulnerability reporting](https://github.com/Schaffernation/tend/security/advisories/new).
Don't open a public issue. Include what you found, how to reproduce it, and
which version of Tend you used.

## What Tend does by design

These behaviors are intended, and aren't vulnerabilities:

- **Tend runs commands from your config.** A session's command, its resume
  command, setup commands and recipes, and the terminal's attach command are
  shell commands that Tend runs or types into a shell. Anyone who can edit
  your config file can already run commands as you.
- **Tend types into your sessions.** `tend answer` types an app's answer into
  the session's pane, but only after it checks that the question is still on
  the screen.
- **Tend reads Claude Code's files.** It reads `~/.claude/sessions/*.json` and
  `~/.claude.json` to show status and find trusted folders. It never writes
  them.
- **Tend sees other accounts' process names.** `tend accounts` checks whether
  another account runs `loginwindow` and `Tend`, using the process list that
  every account can already see. It reads nothing in that account.
- **The app isn't sandboxed.** It drives tmux and sends Apple events to your
  terminal app, which the App Sandbox doesn't allow.

Tend itself doesn't connect to the network.
