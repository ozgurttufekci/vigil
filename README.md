# Vigil

Keeps your Mac awake **while your work is actually running** — then lets it sleep again.

> **Status: early development.** The core engine, the auto-detect engine, and a working menu bar
> app are built and tested. Not yet signed for distribution. The name is provisional.

## Why

Long-running background work — an AI coding agent, a big build, a long upload — gets suspended when
the Mac idle-sleeps. The usual workarounds are both bad:

- Running `caffeinate` by hand: a manual chore, easy to forget.
- Raising the global sleep timeout: blunt, and it wrecks battery life.

A fixed "keep awake for N minutes" timer doesn't really solve it either, because it forces you to
guess. Guess short and the Mac sleeps mid-task. Guess long and the battery drains while you're doing
nothing.

Vigil's core primitive is instead **stay awake until the work is finished**: it watches for the
process you care about, holds the Mac awake while that process is genuinely busy, and releases as
soon as it goes quiet. A manual duration picker is still there when you want one.

## Install

Requires macOS 14 or later.

```sh
./Scripts/build-app.sh release
open build/Vigil.app
```

Vigil lives in the menu bar with no Dock icon. Click it to pick a duration, toggle automatic
detection, or choose which tools to watch.

## Design

### Detection: CPU is the wrong signal for AI agents

The obvious way to tell whether a program is working is to watch its CPU usage. For compilers,
encoders, and container builds that is correct, and it is what Vigil does.

**It does not work for AI coding agents**, and the measurements are not close. Sampling a live
Copilot session through the kernel's own counters, the agent process used **0.03–0.09% CPU while
actively working**, peaking at 1.4%. Its whole process tree measured 0%, because the subprocesses it
runs are not even its descendants. An agent spends nearly all of its time waiting on model
responses; the real work happens on remote servers. A CPU threshold would simply never fire.

(`ps` reports 111–168% for the same process. That is a decaying average and is misleading — the
cumulative CPU counter shows the truth.)

So agents are detected by **file activity** instead: an active session continuously appends to its
session log. That signal is bursty — nothing is written while a single long tool call runs, with
measured gaps of 30 seconds and more — which is exactly what the grace period is for. Agent rules
use a much longer one (5 minutes) than CPU rules.

A rule always requires a **matching process to exist**, even when it triggers on file activity.
Without that, a leftover log file touched by something else could pin the Mac awake with the tool
not even running.

### Holds stack

Every reason to stay awake is a `Hold` — a manual toggle, a matched auto-detect rule, a CLI lease.
The coordinator keeps the Mac awake while *any* hold is live and derives a single desired power
state from the whole set, rather than mapping holds onto assertions one-to-one.

### The Mac can never get stranded awake

This is the property the whole design rests on. Every power assertion is created through
`IOPMAssertionCreateWithProperties` with an OS-enforced timeout and `TimeoutActionRelease`. A healthy
app re-arms well before that lapses; if the app crashes, hangs, or is force-killed, `powerd` releases
the assertion on its own and normal sleep behaviour returns.

Two details make that guarantee real, and both are covered by tests:

- The re-arm interval is always clamped to **at most one third** of the assertion timeout. At a
  half, a single missed tick would land the next attempt exactly on the timeout deadline, where
  scheduling latency could still leave a gap.
- Re-arming **creates the replacement assertion before releasing the old one**. Releasing first
  would leave a window, however brief, in which the Mac is unprotected and could begin idle sleep.

Reconciling and re-arming are a single operation rather than two. When they were separate, a
reconcile that ran after the OS had already timed out an assertion would see a stale tracking entry,
assume protection was still in place, and skip creating a replacement.

### Battery first

By default Vigil prevents idle *system* sleep and **lets the display sleep**. The display is the
dominant power draw, and background work keeps running fine with the screen off. Keeping the display
awake is opt-in.

### Durations use a monotonic clock that counts sleep

Hold deadlines are measured against `CLOCK_MONOTONIC_RAW`, not wall-clock `Date` and not
`ProcessInfo.systemUptime`.

Wall-clock time can jump backwards or forwards (NTP correction, manual clock changes, daylight
saving), which would make a "30 minutes" hold expire early or late. But `systemUptime` is wrong too,
because it *stops* while the Mac is asleep: a 30-minute hold started before an overnight suspend
would still have 25 minutes left the next morning and would immediately refuse to let the Mac sleep
again. On the development machine, `systemUptime` trailed `CLOCK_MONOTONIC_RAW` by 87 hours of
accumulated sleep.

### Secrets never leave the process

Auto-detection has to read process command lines, which routinely contain API keys and tokens. Raw
arguments are never persisted, never transmitted, and never displayed — the UI shows only the matched
rule name and process name.

## Known limitation: closed lid

Power assertions **cannot** keep an Apple Silicon MacBook awake with the lid closed. Apple's
`IOPMLib.h` is explicit that the system may still sleep on lid close. The only mechanism is
`pmset -a disablesleep 1`, which requires root. Vigil does not do this, and no keep-awake app can do
it without a privileged helper.

## Building

Requires Swift 6. Everything here builds with the Command Line Tools alone — `Scripts/build-app.sh`
assembles the `.app` bundle by hand. Full Xcode is needed only for the Control Center extension and
for signed distribution.

```sh
swift build
./Scripts/test.sh
```

`Scripts/test.sh` exists because swift-testing is only fully wired up under Xcode; the script adds
the necessary search paths when running with just the Command Line Tools, and is a plain
`swift test` once Xcode is present.

## Layout

| Path | Purpose |
|---|---|
| `Sources/MonotonicTime` | The shared clock |
| `Sources/PowerAssertions` | Thin, testable wrapper over IOKit power management |
| `Sources/KeepAwakeCore` | Hold model, desired-state derivation, watchdog reconciler |
| `Sources/ProcessWatch` | Process discovery, CPU and file-activity signals, rule engine |
| `Sources/VigilApp` | Menu bar app |
| `Tests/` | Unit tests against fakes, plus integration tests against real system power state |

The test suite includes an integration test that creates a real assertion, confirms it appears in
`pmset -g assertions`, and verifies the OS releases it on timeout — the safety guarantee is proven
against the real system, not just mocked.
