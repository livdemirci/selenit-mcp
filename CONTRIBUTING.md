# Contributing to selenit-mcp

Thanks for helping. This project exists because small local models fail at browser automation for
reasons that are fixable in the tool surface — so the most valuable contributions are *measurements*,
not feature volume.

## The most useful things you can do

1. **Run the benchmark on a model we have not measured.** Qwen 3.5 4B, Qwen 3.5 9B, LFM 1.7B,
   Hermes agent models, Phi, Llama 3.2 3B — anything that runs in LM Studio.
   ```bash
   KOSUM=1 ruby kiyas.rb            # 5 live sites, Selenit vs Playwright MCP
   ```
   Open a PR that adds `bench/kiyas-<model>-<date>.json` plus the generated `.md`, and say what
   hardware you used.
2. **Report a real-site failure with evidence.** Run with `BROWSER_MCP_ARTIFACT_DIR` pointed at a
   scratch dir, then attach the failing tool trace and the page's `browser_snapshot` output.
   A failure I can reproduce is worth ten feature requests.
3. **Windows install reports.** Windows is untested (see ROADMAP.md). A PR that makes `npx
   selenit-mcp doctor` pass on Windows is high value.
4. **Generic fixes, not per-site patches.** A fix must work on sites the code has never seen. If your
   patch special-cases one domain's CSS class, it will be rejected.

## Ground rules

- **Every behavioural claim needs a measurement.** If you change the dump ordering, the error text,
  or a wait, include the before/after numbers (steps, seconds, or pass/fail) in the PR body.
- **Keep it small-model-first.** Anything that grows per-call output must justify the token cost with
  a measured success-rate gain.
- **Never hide a failure.** Benchmarks record failing runs; do not filter them out of the JSON.
- **Ruby style:** 2-space indent, no new gems beyond `selenium-webdriver` (and `ws` for the npm
  wrapper), UTF-8, no trailing whitespace.

## Development loop

```bash
gem install selenium-webdriver
python3 testapp/server.py 8765 &
open -a "Google Chrome" --args --remote-debugging-port=19420 \
  --user-data-dir="$PWD/artifacts/chrome-profile-19420"
ruby smoke_test.rb          # 38 checks, no model
ruby replay.rb filter       # model-free replay
```

Add a scenario to `scenarios/<name>.json` and a matching page route in `testapp/server.py` when you
fix a class of failure — the scenario is the regression test.

## Commit messages

`fix(area): what changed — measured effect`, e.g.
`fix(dump): list search box before product cards — n11 search box missing in 40-slot dump`.
