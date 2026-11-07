---
name: tend
description: Start or manage long-running Claude Code sessions with the `tend` CLI. Use when the user wants a new session in a project folder (existing or new), or wants to list, open, stop, or restart the sessions tend keeps alive.
argument-hint: "[help | new [FOLDER] | ls | open NAME | stop NAME | restart NAME | resume NAME]"
---

# Tend sessions

`tend` runs each session in its own tmux session, so it outlives the terminal
and comes back after a restart. A session is a folder plus a command, usually
Claude Code's Remote Control (`claude remote-control`). For every command and
flag, run `tend --help`.

Route by the request. With arguments, the first word picks the branch: `new`
starts a session, `help` shows the menu, and any other `tend` command (`ls`,
`open`, `stop`, `restart`, `start`, `history`, `resume`, `snapshot`,
`autostart`, `rm`) runs under
**Manage sessions**. With no arguments and no request, or when the user asks
what this can do, show the menu.

## Menu

Show this, then ask what they'd like to do:

> **Tend keeps Claude Code sessions running in tmux, and brings them back
> after a restart.** Ask in your own words, or use a command:
>
> | Command | What it does |
> |---|---|
> | `/tend new [FOLDER]` | Start a Claude session in a project folder, or in a new folder |
> | `/tend ls` | List your sessions, and whether each Claude is busy or idle |
> | `/tend open NAME` | Open a session in a terminal window |
> | `/tend stop NAME`, `/tend restart NAME` | Stop or restart a session (asks you first) |
> | `/tend resume NAME` | Bring back a conversation that a restart didn't reconnect |
> | `/tend help` | Show this menu |
>
> For example: "start a session in a new folder called recipe-box", "which
> sessions are busy?", or "restart recipe-box with a fresh conversation".

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
4. **Set it up, if needed.** If the user names a repository to work on, add
   `--recipe clone --input URL` (the folder must be new or empty). For any
   other one-time step, like `git init`, add `--setup CMD`. `tend recipes`
   lists saved setups. Setup runs once, before the app starts.
5. **Pick the app.** Use Claude unless the user asks for another app or gives
   a command.
6. **Start the session:**

   ```
   tend new claude --dir FOLDER [--mkdir] [--name NAME] [--recipe ID --input TEXT | --setup CMD]
   ```

   Add `--mkdir` for a new folder. Add `--name` only if the user chose a
   name; tend otherwise names the session after the folder. For a custom
   command, drop the app and put the command after `--`. The step is done
   when the output says `Started 'NAME'`. If it fails, show the user tend's
   error, which says what to fix.
7. **Wait for it to settle.** Run `tend wait NAME`. It returns when the
   session is ready, is waiting on a question, or has exited, and its exit
   status says which:
   - **0, ready.** For Claude, Remote Control has connected. Go to step 8.
   - **2, waiting on a question,** like "Trust FOLDER?". The same question
     also has buttons in the Tend menu, and the first answer wins. Ask the
     user with AskUserQuestion, using the answers tend lists: for trust,
     **Trust** and **Don't trust**. Say that trusting lets the folder's
     project settings (hooks, MCP servers, permission rules) apply to its
     sessions. Then run `tend answer NAME yes` (or `no`). If it says the
     session `isn't waiting on a question`, the user already answered in
     the menu. That's fine; don't treat it as an error. Either way, run
     `tend wait NAME` again.
   - **1, exited.** The command stopped, for example because the user
     didn't trust the folder. Say so, and offer `tend open NAME` to see why.
   - **3, timed out.** Say it's still starting, and offer `tend open NAME`.
   Report a session as ready only after `tend wait` returns 0.
8. **Report** the session name and folder, and how to reach it:
   - A Claude Remote Control session appears in the Claude app and at
     claude.ai/code.
   - `tend open NAME` opens it in a new terminal window. Offer to run it.

## Manage sessions

- `tend ls` lists tracked sessions and untracked tmux sessions (marked `*`),
  with each one's state and, for Claude, whether it's `busy` or `idle`. Use
  `tend ls --json` when you need fields.
- When `tend ls` says a session is waiting on a question (like Claude's
  trust prompt), ask the user, then run `tend answer NAME ANSWER`, and
  `tend wait NAME` to confirm it carried on.
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

`tend restart NAME` restarts Remote Control in server mode, which reconnects
its last conversation if Remote Control still remembers it, and lets the
Claude app start new sessions there. `tend restart NAME --fresh` starts a new
conversation. Restarting the session you run in works too: tend hands the
restart to the tmux server, and this conversation reconnects after it. A
restart from single-session mode waits 45 seconds first; tell the user.

`tend history NAME` lists the conversations a session has run, newest first.
When a restart started a new conversation instead of reconnecting (Remote
Control forgets after a while), `tend resume NAME [ID]` brings back the
latest one, or the given ID, in single-session mode. A later
`tend restart NAME` returns it to server mode and keeps the conversation.

`tend rm NAME` stops tracking a session and leaves it running.
