# bufferbloat-probe

A single-file bash test for bufferbloat: ping at rest -> saturate the link ->
ping under load -> delta, an A..F grade, and what to do about it.

The problem: an "idle-looking" link guarantees nothing. The moment the channel
saturates, oversized FIFO buffers in network devices add hundreds of
milliseconds of latency. The fix is active queue management (CoDel / fq_codel),
not a "gaming" router with RGB lighting.

## Method

1. `N` pings at rest -> baseline min/avg/max/p95
2. Load on the link:
   - **iperf3** (if `--iperf host` is given) — 4 parallel streams
   - otherwise **curl** — 6 parallel downloads against a Cloudflare speed endpoint
3. Ping while the load runs -> same stats
4. avg/p95 delta -> grade:

| avg delta | Grade |
|---|---|
| < 5 ms | A |
| < 30 ms | B |
| < 60 ms | C |
| < 200 ms | D |
| < 400 ms | E |
| >= 400 ms | F |

Exit codes: `0` — A/B/C, `1` — D or worse (easy to hook into cron/monitoring), `2` — no data.

## Usage

```bash
./bufferbloat.sh                        # quick test (~25 s), curl-based load
./bufferbloat.sh --host 8.8.8.8         # different ping target
./bufferbloat.sh --iperf 192.168.1.1    # proper load test via a local iperf3
```

Sample output:

```
[3/3] Verdict
  delta avg : +312.4 ms  (avg under load - avg at rest)
  delta p95 : +480.1 ms
  grade     : D — bad, queues are clearly overflowing
```

## Requirements

- bash, ping, curl (or iperf3 for a precise test)
- nothing to install: the curl mode works out of the box

## License

MIT
