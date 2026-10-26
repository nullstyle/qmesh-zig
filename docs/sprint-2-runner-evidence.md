# Sprint 2 runner qualification — 2026-10-26

`Runner.run()` now parks on mesh/control readability and the earliest core,
server, owned-dial or application deadline. The default maximum park is 50 ms
so an atomic shutdown flag does not require network activity. POSIX poll
timeouts round future deadlines up to whole milliseconds; EINTR returns to
the shutdown check. Callback-generated output is drained before parking, and
fresh dials request immediate service.

`Options.next_deadline(ctx, *const Runner, now_us) ?u64` shares
`on_iteration_ctx` and uses `Runner.clockUs()` absolute microseconds. A
supplied callback returning null opts out of the legacy 2 ms callback cadence.
Without that callback, existing `on_iteration` users retain `step_sleep_ms`.
The node binary supplies telemetry/publication deadlines and mDNS's Engine
plus receive-drain cadence, so its normal idle path realizes the benefit.

Normal successful parking contributes at most its planned duration as
Lifeguard credit. Work, oversleep, injected freeze/slow delays and callback
stalls remain observed delay. During freeze/slow, `run()` polls control only;
queued mesh traffic cannot cause a readiness spin. Control and shutdown stay
responsive through the configured wait cap.

`readableSockets()` returns borrowed handle **inventory**, valid until
deinit. External owners combine `nextDeadline(now_us)` with messaging/pool
deadlines, select their admissible read interests and call nonblocking
`step()`. Step drains controls before protocol work; crash uses the existing
exit path, and loss/blackhole changes apply immediately. It owns no pacing:
foreign pause policies mask mesh readability and use their resume deadline
instead of overdue protocol timers while paused. Step retains raw-gap
Lifeguard accounting. The public-stack composition guide uses actual run
threads: [sprint-2-composition.md](sprint-2-composition.md).

## Measurements

The immutable baseline was rebuilt from Sprint 1 commit
`128c8dcbd5f69310f71e099fffa64e1785ec2129` before runner edits, using stock
mise Zig 0.17.0, ReleaseSafe, `-j2`. Baseline binary SHA-256:
`eef0ab484d73d8a84ce79a4410d4bf16096b893052a380c081e4595b05b64e1f`.
Final Mac binary: `736c61a3881a75169e69bd61713490f782d2af9c46ed933a23dcea7a33a8eac7`.

Three 5-second idle runs per binary used one node with the test PKI, no
peers, no mDNS/publication, and a 3600-second telemetry interval. Environment
`QMESH_*` overrides were removed. CPU covers process startup/shutdown;
macOS interrupt wakeups use `proc_pid_rusage` v0 after a 100 ms warmup.

| Local ARM64 Mac measure | Fixed 2 ms polling | Final deadline runner |
| --- | ---: | ---: |
| Median interrupt wakeups / 5 s | 2034 | 101 |
| Median total CPU / run | 36.093 ms | 15.310 ms |
| SIGTERM exit, three samples | 1.88–2.12 ms | 2.20–4.55 ms |

That is about 95% fewer interrupt wakeups and 58% less CPU in this workload.
These are host/workload-specific observations. The general latency tradeoff
is the configured atomic-shutdown observation cap; socket readability and
signal interruption wake the loop earlier. mDNS retains its own receive
poll cadence rather than adopting the idle 50 ms cap.

Repeat with `tools/runner-idle-bench.py --binary <exact executable> --output
.zig-cache/sprint-2-evidence/<name>.json`. The report records binary and
runtime-source hashes, commands, CPU, wakeups/context switches and shutdown.
A final Linux CLI sample exited cleanly after 5 s, with 9.682 ms total CPU,
97 voluntary context switches and 2.01 ms SIGTERM exit; no Linux baseline or
equivalent interrupt-wakeup measurement is claimed.

## Gates

All four fresh full-suite runs passed **138/138 executed tests**, **27/27
steps**, with zero cached test runs, failures or skips:

| Runtime | Debug | ReleaseSafe |
| --- | --- | --- |
| Native ARM64 macOS | 138/138 | 138/138 |
| Native ARM64 Linux under OrbStack | 138/138 | 138/138 |

Both ReleaseSafe CLI builds passed 14/14 steps. Stock Zig 0.17.0 compiler
SHA-256 is `1c5f706db0ed6d55451940f31dc05a6177d05696bc1fa5d853696d04c718b523`
on Mac and `5165c9a2d17938a8173839b3adf81d025b558d38d9e9711237a6fa5b8d8bb3f7`
on Linux. Linux used cached image `quic-zig-sprint1-builder:local`, image ID
`sha256:97711185ccd951b04ca293caa83c7b88832ef61c0422439ae82903b7a1f6f969`,
with `/opt/zig/zig`; this is local container execution, not hosted CI.

The ten runner regressions cover deadline rounding/minimum selection,
fresh-dial immediacy, nonblocking step, normal-wait health, legacy callback
cadence, queued traffic during freeze, visible freeze/slow/callback stalls,
readiness wake, callback-generated broadcast, control unfreeze and bounded
shutdown. The full suite retains the real twelve-node bootstrap, broadcast,
mass crash/heal tests and deterministic pause/recovery scenarios.

Independent review found a control-interest defect: the new borrowed-fd
contract exposed a control socket but step did not drain it. A real datagram
regression went red with `expected 10000, found 0`, then green after the
bounded control drain was added. It also asserts that readiness clears.
An initial test-side zero-time poll raced delivery; it was corrected to wait
for readiness before exercising step. The initial CLI benchmark rejected
port zero and the initial test helper used signed division; those fixture
failures and all pre-correction runs remain separate raw logs.

Raw commands, logs, identities and metric JSON are ignored under
`.zig-cache/sprint-2-evidence/`; `summary.json` indexes final qualification.
Use `zig build runner-test -j2` for the focused suite and `zig build test
-j2 --summary all` (plus `-Doptimize=ReleaseSafe`) for full gates. Public
package versions/pins are unchanged. Sprint 2 remains uncommitted and unpushed.
