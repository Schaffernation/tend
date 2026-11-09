# Changelog

This file lists the changes in each release of Tend. Versions follow
[Semantic Versioning](https://semver.org).

## Unreleased

- Added a license (MIT), contributing guide, and security policy.

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
