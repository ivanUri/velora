# One-shot fetch worker pool

`koko` keeps one V8 isolate per process and the `fetch` command is one-shot.
For bounded parallel crawling, use the supervisor:

```sh
node scripts/koko-pool.mjs \
  --urls scripts/urls-100.txt \
  --concurrency 2 \
  --timeout-ms 30000 \
  --output-dir exports/pool
```

Each slot runs one child at a time. Jobs receive a separate
`worker-N/job-M` profile and SQLite path, so cookies, local storage and the
database are not shared accidentally. A hard timeout sends `SIGTERM`, then
`SIGKILL` after the configured grace periods. Results remain in input order;
the command exits non-zero if any job fails.

This is deliberately a process supervisor rather than multi-page V8 reuse.
It gives isolation and failure containment first. Increase concurrency only
after measuring RSS and target-site rate limits; a worker is not a license to
send unlimited requests.
