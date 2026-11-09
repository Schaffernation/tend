# Changelog

This file lists the changes in each release of Tend. Versions follow
[Semantic Versioning](https://semver.org).

## Unreleased

### Added

- `tend dropped`, `tend recover`, and `tend dismiss`: list the conversations
  a restart dropped, like Remote Control chats after a reboot, and reopen one
  in its own session. The app shows them in a banner.
- `tend config` shows where Tend keeps its files.
- Tests (`python3 -m unittest discover tests`) and a GitHub Actions workflow
  that runs them and builds the app.
- A license (MIT), contributing guide, and security policy.

### Changed

- Tend calls tracked tmux sessions "sessions" everywhere. A new config file is
  named `sessions.json`. An existing `services.json` keeps working.
- tend adds Homebrew and `~/.local/bin` to the end of your `PATH` instead of
  replacing it, so your own tools come first.
- The app polls only what changes on its own, and asks `tend folders` for
  folder suggestions.

### Fixed

- Two Tend commands that changed the config at the same time, like the app's
  poll and `tend new`, could lose one of the changes. Changes now happen
  under a lock.
- `tend open` failed for a session whose name had a character outside ASCII,
  like `café`.
- A config file with a JSON error printed a Python traceback. tend now says
  where the error is.
- A tmux session started with a command instead of a shell showed as exited,
  and `tend snapshot` saved it as a plain shell.
- The **Restore sessions after the Mac starts** setting could show the wrong
  value in Settings.
- An app installed after Tend opened showed no icon until Tend restarted.

## 0.1

The first version.

- `tend` command-line tool: track tmux sessions, start, stop, restart, and
  restore them, and attach to or open them in a terminal.
- Menu bar app that shows each session's state and runs `tend` for you.
- Built-in Claude Code support: busy and idle status, reconnecting a restored
  Remote Control session to its last conversation, conversation history with
  `tend history` and `tend resume`, and answering the trust prompt with
  `tend answer`.
- App profiles, so Tend can recognize any program.
- Setup commands and recipes for new folders, like cloning a repository.
- Warnings when another account on the Mac isn't logged in or isn't running
  Tend.
- A Claude Code skill that starts and manages sessions.
