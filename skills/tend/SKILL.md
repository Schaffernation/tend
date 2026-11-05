---
name: tend
description: Start or manage long-running Claude Code sessions with the `tend` CLI. Use when the user wants a new session in a project folder (existing or new), or wants to list, open, stop, or restart the sessions tend keeps alive.
---

# Tend sessions

`tend` runs each session in its own tmux session, so it outlives the terminal
and comes back after a restart. A session is a folder plus a command, usually
Claude Code's Remote Control (`claude remote-control`). For every command and
flag, run `tend --help`.

## Start a new session

1. **Gather the choices.** Run `tend folders --json` and `tend apps --json`.
   - `recent`: folders that already have sessions.
   - `nearby`: other folders next to them, most recently changed first.
   - `parents`: where those folders live, most used first. A new folder goes
     in `parents[0]` unless the user names another place.
   - Launchable apps are the ones with `enabled: true` and a `launch`
     command. Claude (`claude`) is built in.
2. **Pick the folder.** If the request already names a folder or project,
   match it against `recent` and `nearby` and use it. Otherwise, show a
   numbered list: every `recent` folder, then the first 10 `nearby` folders,
   then "A new folder". Write paths with `~` for the home folder. Ask which
   one. The step is done when you have one absolute folder path, and you know
   whether it exists.
3. **For a new folder,** get its name from the user, and confirm the full
   path before you create anything.
4. **Pick the app.** Use Claude unless the user asks for another app or gives
   a command.
5. **Start the session:**

   ```
   tend new claude --dir FOLDER [--mkdir] [--name NAME]
   ```

   Add `--mkdir` for a new folder. Add `--name` only if the user chose a
   name; tend otherwise names the session after the folder. For a custom
   command, drop the app and put the command after `--`. The step is done
   when the output says `Started 'NAME'`. If it fails, show the user tend's
   error, which says what to fix.
6. **Report** the session name and folder, and how to reach it:
   - A Claude Remote Control session appears in the Claude app and at
     claude.ai/code within a few seconds.
   - `tend open NAME` opens it in a new terminal window. Offer to run it.

## Manage sessions

- `tend ls` lists tracked sessions and untracked tmux sessions (marked `*`),
  with each one's state and, for Claude, whether it's `busy` or `idle`. Use
  `tend ls --json` when you need fields.
- `tend open NAME` opens a session in a terminal window. `tend start NAME`
  starts a tracked session that's stopped.
- `tend snapshot [NAME]` tracks running tmux sessions, so tend restores them.
- `tend autostart NAME on|off` sets whether a restart brings it back.

Stopping or restarting a session ends the program running in it, and for
Claude, that's a conversation that may be mid-task. Before `tend stop`,
`tend restart`, or `tend rm --stop`, name the session, say whether it's
`busy`, and get the user's yes. Your own conversation runs in a tend session
when `$TMUX` is set: `tmux display -p '#S'` prints its name, and stopping or
restarting that one ends this conversation, so say that too.

`tend restart NAME` reattaches Claude to the same conversation;
`tend restart NAME --fresh` starts a new one. `tend rm NAME` stops tracking a
session and leaves it running.
