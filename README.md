# lockout

A mutex / job queue for expensive compilation.

Several agents running `cargo build` at once do not finish sooner — they fight
over the same cores and every one of them gets slower. `lockout` admits a set
number of builds at a time (default: one) and queues the rest
first-come-first-served, so a machine with four agents on it behaves like a
machine with one build on it.

One bash script, no dependencies, no daemon. Runs on macOS and Linux, on bash
3.2 (macOS stock `/bin/bash`) through bash 5.

```console
$ lockout run -- cargo build --release
lockout: [000012] queued - position 1, 1 running (limit 1), waiting 0:15
   Compiling myapp v0.1.0
    Finished `release` profile [optimized] target(s) in 41.02s
```

## Install

```bash
./install.sh                 # links bin/lockout -> ~/.local/bin, skill -> ~/.claude/skills
./install.sh --prefix /usr/local/bin
./install.sh --uninstall
```

Or just put `bin/lockout` on your PATH — it is self-contained.

To queue plain `cargo build` with no wrapper at all, put the shim first on PATH:

```bash
export PATH="/path/to/lockout/shim:$PATH"
```

The shim queues the subcommands that actually compile (`build`, `test`,
`check`, `clippy`, `bench`, `doc`, `rustc`, `nextest`, `miri`) and passes
everything else — `cargo add`, `cargo fmt`, `cargo metadata` — straight
through, so interactive work stays responsive while a build holds the slot.
`cargo run` is deliberately not queued: it compiles and then runs your program,
often for a long time, and holding a build slot for that is wrong.

## Use

```bash
lockout run -- cargo test          # block for a slot, run, exit with cargo's code
lockout status                     # what is running, what is waiting, for how long
lockout status --json              # the same, parseable
lockout wait                       # block until the queue drains
lockout limit 2                    # allow two builds at once
```

Blocking is the normal mode: `lockout run` behaves exactly like the command it
wraps, including its exit code and its output, it just may start later. While
queued it reports to stderr every 15 seconds so a blocked agent — or a human
watching a log — can see it is alive and where it is in line.

When there is genuinely other work to do, detach instead:

```bash
id=$(lockout submit -q -- cargo test)
# ...
lockout wait "$id"    # exits with the job's exit code
lockout logs "$id"    # its captured output
lockout cancel "$id"
```

### Exit codes

`lockout run` exits with the wrapped command's own code, so a non-zero exit
still means the build failed rather than the queue rejecting you. Its own
failures are distinguishable: `130` cancelled, `143` SIGTERM, `254` the job's
owner died and the slot was reclaimed.

### Scopes

`LOCKOUT_SCOPE` names an independent queue. The default is machine-wide on
purpose — the contended resource is the CPU, not one checkout — but a queue
that should not block builds can have its own:

```bash
LOCKOUT_SCOPE=docs lockout run -- cargo doc
```

### Environment

| Variable | Default | Meaning |
|---|---|---|
| `LOCKOUT_LIMIT` | `1` | Concurrency limit; overrides the stored one |
| `LOCKOUT_SCOPE` | `default` | Queue name |
| `LOCKOUT_HOME` | `$XDG_STATE_HOME/lockout` or `~/.local/state/lockout` | State directory |
| `LOCKOUT_RETENTION` | `3600` | Seconds to keep finished jobs in `status` |

## How it works

State is a directory per scope, holding a directory per job, holding one small
file per field. There is no daemon and no database: a job record *is* the
filesystem.

- **Mutual exclusion** is `mkdir(2)`, which is atomic on every filesystem worth
  using. `flock(1)` does not exist on macOS, so it is not an option here. The
  control lock is held only for the microseconds it takes to inspect and update
  the queue — never while a build runs.
- **Fairness** is a ticket. Enqueueing increments a counter under the control
  lock; a job is admitted only when it is the oldest queued job *and* the
  running count is below the limit. That is FIFO, and it means no job can be
  starved by a stream of newer arrivals.
- **A dead agent cannot wedge the queue.** Every job records the pid that owns
  it. Any process entering the critical section first reaps jobs whose owner no
  longer exists, marking them `254` and freeing their slot. A control lock left
  behind by a killed process is reclaimed the same way.
- **Re-entrancy.** A command running under lockout can call `lockout run` again
  in the same scope; the inner call sees the held slot in the environment and
  runs inline rather than deadlocking against its own parent. This is what makes
  the cargo shim safe to leave on PATH — a `build.rs` that shells out to cargo
  will not hang.
- **Cancelling stops the whole tree.** A build spawns compilers; signalling
  only the process lockout launched would leave those running, which is exactly
  the CPU burn the queue exists to prevent. Cancel and SIGTERM walk the process
  tree and signal leaves first.
- **Polling backs off.** 50ms while a slot is likely to free up soon, then
  250ms, then 1s once it is clear the wait is long. Reads in the poll loop use
  bash builtins rather than `cat`, so waiting costs approximately nothing.

Finished jobs stay visible for an hour (`LOCKOUT_RETENTION`) so you can see what
just ran, then are pruned.

## Tests

```bash
./tests/run_tests.sh                            # 33 tests, ~30s
LOCKOUT_BIN=/path/to/copy ./tests/run_tests.sh  # run against another bash
```

Plain bash, no framework, no interpreter beyond bash itself, throwaway state
directory per run. Covers exclusion
at limit 1 and limit 3 (by reconstructing the actual overlap from a trace each
job writes), FIFO admission order, scope isolation, exit-code propagation,
argument passing, re-entrancy, recovery from a killed holder and from a stale
control lock, cancel of both queued and running jobs, signal handling, submit /
wait / logs, retention pruning, and that `--json` stays well formed when the
queue is empty.

The suite passes on bash 3.2.57 and 5.3.9.

## Agent skill

`skills/lockout/SKILL.md` teaches an agent to reach for `lockout run` before an
expensive build, to read `lockout status` instead of assuming the machine is
idle, and to tell a queue wait apart from a hang. `install.sh` links it into
`~/.claude/skills/`.

## Known edge

Cargo takes its own global lock on `~/.cargo` while resolving and downloading.
If an unrelated build already holds it, your queued build will print `Blocking
waiting for file lock on package cache` *after* lockout admits it. That wait is
cargo's, not lockout's — `lockout status` will show the job as running, because
it is.
