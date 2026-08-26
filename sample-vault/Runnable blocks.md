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

Exit status is reported, and stderr is shown separately:

```bash
echo "this went to stdout"
echo "this went to stderr" 1>&2
exit 3
```

Git commands run against the repo this file lives in:

```bash
git log --oneline -5
```

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
