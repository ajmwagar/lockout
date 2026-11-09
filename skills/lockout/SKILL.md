---
name: lockout
description: Queue expensive builds so parallel agents do not thrash the machine. Use before running cargo build/test/check/clippy, or any long compile, when other agents or sessions may be building at the same time - and to check what is already building, wait for it, or cancel it.
---

# lockout

A machine-wide FIFO queue and build budget for expensive compilation. Several
agents running `cargo build` at once do not go faster - they fight over the
same cores, and every one of them gets slower. `lockout` admits a set number at
a time (default 1) and queues the rest first-come-first-served; it also caps what
a running job may consume.

## Use it

Wrap the expensive command. It blocks until a slot is free, then runs the
command and exits with the command's own exit code:

```bash
lockout run -- cargo build --release
lockout run -- cargo test
```

That is the whole workflow. Output streams to your terminal as usual, and a
non-zero exit still means the build failed - not that the queue rejected you.

For a build that can fan out, add a budget. It stops a runaway instead of
letting it eat the machine:

```bash
lockout run --cpu-quota 4 --mem-cap 8G --children 32 --timeout 30m -- cargo test
lockout budget          # show caps + kernel-task headroom
```

CPU quota is enforced by duty cycling the job's process group; memory,
children, and wall time are hard stops. The kernel-task gate refuses to spawn
when the table has no headroom (exit 253).

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
| 124 | wall-clock timeout |
| 125 | children cap exceeded |
| 130 | the job was cancelled |
| 137 | memory cap exceeded |
| 143 | the job got SIGTERM |
| 253 | the kernel-task gate refused to spawn |
| 254 | the job's owner died and the slot was reclaimed |

## Other commands

```bash
lockout limit          # current concurrency limit
lockout limit 2        # allow two builds at once
lockout cancel 000012  # stop one job
lockout cancel all     # stop everything queued and running
lockout reap           # free slots whose owner died (also runs automatically)
lockout budget         # effective budget and kernel-task headroom
lockout self-test      # prove a 20s runaway is contained under half nproc
```

## bob decides *where*, lockout decides *how many*

`lockout` admits a build **on this machine**. If the build can run somewhere
else, route it first and there is nothing to admit:

```bash
fpl bob remote --pool bob -- cargo build --release   # fleet
lockout run -- cargo build --release                 # this machine only
```

The two compose and neither replaces the other: bob's per-agent `CARGO_HOME`
fixes *which lock* a build takes, lockout fixes *how many* builds share the CPU.
Wrapping a fleet build in `lockout` only makes local dispatch wait for a slot it
does not need.

## Bus stop, not uber

A queue is cheap; a dispatcher is not. Prefer batching work into one admitted
job over hailing the queue once per command:

```bash
lockout run -- sh -c 'cargo fmt --check && cargo clippy --all-targets && cargo test'
```

Three separate `lockout run`s pay the queue, the spawn, and often a cold
incremental state three times, and they interleave with everyone else's builds.
One job keeps the machine busy in a straight line.

When every build is offloaded, the limit can be loosened: the queue stops being
a CPU shield and becomes a fairness and batching mechanism. Keep it tight for the
lane that actually runs here — the serialized native macOS lane is one slot by
construction.

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
