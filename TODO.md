# To do

## Trust prompt: ask once, wherever the user is

When `tend new` starts Claude in a folder that hasn't been trusted yet, there
are two places to answer the trust question: buttons in the Tend menu, and the
tend skill, which asks in chat and runs `tend answer NAME yes`. The first
answer wins.

- [x] Before the skill asks its question, have it check `app.question` in
      `tend ls --json` and skip the question if the session isn't waiting
      anymore, so the user doesn't get asked something they already answered
      in the menu. Right now the skill asks anyway, and `tend answer` replies
      `'NAME' isn't waiting on a question.`
      Done: the skill asks only when `tend wait NAME` returns 2 (waiting on a
      question), and treats `isn't waiting on a question` from `tend answer`
      as "already answered in the menu", not an error.
- [x] After either answer, have the skill confirm the session connected, for
      example by checking for `Connected` in Remote Control's output, before
      it reports the session as ready.
      Done: the skill runs `tend wait NAME` again and reports the session as
      ready only when it returns 0. For Claude, that's when the session file
      reports a status, not when the pane says `Connected`.
