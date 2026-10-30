# Good places to help right now

These are open invitations, not tickets assigned to anyone. Comment on the issue before starting so
two people do not build the same thing.

## Benchmark

- **Add Qwen 3.5 4B to the head-to-head** — run `./run_kiyas.sh` with `MODEL=<id>`, post the JSON.
- **Add Qwen 3.5 9B to the head-to-head** — same, larger model; useful to see whether the gap narrows.
- **Add LFM 1.7B compatibility tests** — smallest model in the target range; expect more malformed
  tool calls, which is exactly the interesting data.
- **Add a reproducible benchmark suite** — `KOSUM=5` medians committed to `bench/` with a runner that
  reports variance per site.

## Reliability

- **Improve Windows installation** — `npx selenit-mcp doctor` on Windows 11, report what breaks.
- **Add browser automation examples** — one `.json` scenario per class of failure (cookie wall,
  infinite scroll, multi-step checkout) with the matching route in `testapp/server.py`.
- **Snapshot diffing** — return only elements that changed since the previous snapshot; measure the
  token delta with `kiyas.rb`.

## Docs

- **Zero-to-running walkthrough** — a 5-minute path from nothing to a passing task with a local model.
- **Failure gallery** — real traces of tool-call mistakes small models make, with what the error text
  should have said.
