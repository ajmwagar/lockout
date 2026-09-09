---
name: lockout
description: Queue expensive builds so parallel agents do not thrash the machine. Use before running cargo build/test/check/clippy, or any long compile, when other agents or sessions may be building at the same time - and to check what is already building, wait for it, or cancel it.
---

# lockout

A machine-wide FIFO queue for expensive compilation. Several agents running
`cargo build` at once do not go faster - they fight over the same cores, and
every one of them gets slower. `lockout` admits a set number at a time (default
1) and queues the rest first-come-first-served.

## Use it

Wrap the expensive command. It blocks until a slot is free, then runs the
command and exits with the command's own exit code:

```bash
lockout run -- cargo build --release
lockout run -- cargo test
```

That is the whole workflow. Output streams to your terminal as usual, and a
non-zero exit still means the build failed - not that the queue rejected you.

## Before assuming the machine is idle

```bash
lockout status            # what is running, what is queued, how long it has waited
lockout status --json     # same thing, parseable
```

If something is already building, that is expected. `lockout run` will wait its
turn; you do not need to poll first.

## When you would rather not block

```bash
id=$(lockout submit -q -- cargo test)   # returns immediately with a job id
# ... do other work that does not need the build ...
lockout wait "$id"                      # exits with the job's exit code
lockout logs "$id"                      # its captured output
```

Use `submit` when there is genuinely other work to do. Otherwise prefer
`lockout run` - it is simpler and streams output live.

`lockout wait` with no arguments blocks until the whole queue drains, which is
the right call before benchmarking or anything else timing-sensitive.

## Reading a blocked run

While queued, `lockout run` reports to stderr every 15 seconds:

```
lockout: [000012] queued - position 2, 1 running (limit 1), waiting 0:45
```

That is progress, not an error. A long wait means someone else's build is long.

## Exit codes

| Code | Meaning |
|------|---------|
| the command's own | normal - the build ran and this is its result |
| 130 | the job was cancelled |
| 143 | the job got SIGTERM |
| 254 | the job's owner died and the slot was reclaimed |

## Other commands

```bash
lockout limit          # current concurrency limit
lockout limit 2        # allow two builds at once
lockout cancel 000012  # stop one job
lockout cancel all     # stop everything queued and running
lockout reap           # free slots whose owner died (also runs automatically)
```

## Things worth knowing

- **Nesting is safe.** A command already running under lockout can call
  `lockout run` again in the same scope; the inner call detects the held slot
  and runs inline instead of deadlocking against itself.
- **Scopes are independent queues.** `LOCKOUT_SCOPE=docs lockout run -- ...`
  never blocks on the default scope. The default is machine-wide on purpose:
  the contended resource is the CPU, not one checkout.
- **Do not `submit` and then `wait` on it from inside a job** at limit 1 - the
  outer job holds the only slot while the inner one waits for it.
- **A dead agent does not wedge the queue.** Slots held by processes that no
  longer exist are reclaimed automatically.
- If `shim/cargo` is on PATH ahead of the real cargo, plain `cargo build` is
  already queued and no wrapper is needed.
