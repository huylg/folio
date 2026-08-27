---
title: Runnable blocks
tags: [demo]
---

# Runnable blocks

Every open file detects a project root: the nearest ancestor folder with a `.git` entry, or the file's own folder outside a repository. This file lives inside the Folio repo, so its root is the repo itself. Two things key off that root.

## Shell blocks run

A fence tagged `bash`, `sh`, `shell`, or `zsh` gets a Run button (▶) in its header, next to Copy. The command executes on a real pseudo-terminal with the project root as its working directory. A console card appears under the block the moment the run starts and shows output live as the command produces it — line by line, like a terminal — then settles into the logged result with its exit status. The Run button never blocks: run again mid-command and each run gets its own console, latest on top. Close any one of them with its own ×; the others stay.

Watch it stream:

```bash
for i in 1 2 3; do echo "tick $i"; sleep 1; done
```

```bash
pwd
```

Pipes and multiple lines work — it is one `/bin/sh -c` invocation:

```sh
echo "markdown files in this repo:"
find sample-vault -name '*.md' | sort
```

Exit status is reported. Both streams arrive together, interleaved where the command wrote them — a terminal has one stream, and this is a real one:

```bash
echo "this went to stdout"
echo "this went to stderr" 1>&2
exit 3
```

Git commands run against the repo this file lives in:

```bash
git log --oneline -5
```

## Colors come through

The console reports itself as `xterm-256color`, so tools color their output the way they would in a terminal, and the escape codes they send are parsed rather than stripped: they become style on the text, never text of their own.

The sixteen named colors, and the attributes that go with them:

```bash
printf '\033[31merror\033[0m  \033[33mwarning\033[0m  \033[32mok\033[0m\n'
printf '\033[1mbold\033[0m  \033[4munderline\033[0m  \033[7mreverse\033[0m  \033[2mdim\033[0m\n'
```

The 256-color cube, and 24-bit color for tools that ask for an exact one:

```bash
for i in 196 202 208 214 220 226; do printf '\033[38;5;%dm██\033[0m' $i; done; echo
for r in 40 80 120 160 200 240; do printf '\033[48;2;%d;80;200m    \033[0m' $r; done; echo
```

A carriage return rewrites its own line, which is how a progress counter stays one row instead of becoming a hundred. Run this and watch the percentage climb in place:

```bash
for i in 0 25 50 75 100; do printf '\rworking… %d%%' $i; sleep 0.3; done; printf '\rdone.\033[K\n'
```

The `\033[K` on the last line is not decoration. A rewrite only covers as many columns as it is long, so `done.` alone would leave the tail of `working… 100%` standing behind it — erase-to-end-of-line is how a tool clears the rest, and it is honoured here.

What is not emulated is the cursor moving *between* lines — the multi-line in-place repainting docker and cargo do. Those frames stack up rather than replacing each other. Color on every run was judged the better trade.

## Other blocks don't

Only sh-family fences are runnable — even `fish` is excluded, since its syntax is not `/bin/sh`-compatible. A `python` block or an unlabelled fence gets a Copy button and nothing else:

```python
print("no Run button here")
```

```
neither here — no language declared
```

## Root-absolute links

A link starting with `/` resolves against the project root instead of the filesystem, so it works no matter how deeply the linking file is nested: [the repo README](/README.md), or [a note elsewhere in this vault](/sample-vault/Method/Kernel%20notes.md). Plain relative links still resolve against this file's folder: [Reading queue](Reading%20queue.md).
