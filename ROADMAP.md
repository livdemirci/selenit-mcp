# Roadmap

Ordered by what most improves task success for small local models. Nothing here is a promise of a
date; it is a priority order so contributors know where a PR lands best.

## v0.5 — make the evidence reproducible

- [x] `kiyas.rb` — external-reproducible head-to-head driver (Selenit vs Playwright MCP), writes raw
      JSON with per-step traces and token counts
- [x] GitHub Actions smoke job (Ubuntu + macOS, Ruby 3.2/3.3, headless Chrome, no model needed)
- [ ] Benchmark runs published for: Qwen 3.5 4B, Qwen 3.5 9B, LFM 1.7B
- [ ] `KOSUM=5` median table with per-site variance, committed to `bench/`
- [ ] Short demo recording (LM Studio + Gemma E4B, live site, on-screen token counter)

## v0.6 — reduce token cost per task

The measured weakness: on some sites Selenit's *per-step* output is larger than Playwright's, so a
task that needs fewer steps can still burn more total tokens.

- [ ] Snapshot diffing: return only elements that changed since the previous snapshot
- [ ] Budget-aware dump: caller passes a token budget, dump trims by priority
- [ ] `browser_read` summarisation by structure (headings + first N items) instead of raw text
- [ ] Measure each change with `kiyas.rb` and record the token delta in the PR

## v0.7 — broader model support

- [ ] Model profiles: per-model system prompt + `MAX_ELEMENTS` preset (`BENCH_PROFILE=gemma-e4b|qwen-4b|lfm`)
- [ ] Tool-surface trimming: `SELENIT_MINIMAL=1` exposes ~10 tools instead of 23 (measured: fewer
      tools, fewer wrong-tool calls on small models)
- [ ] Structured tool-call repair for models that emit malformed JSON arguments

## v0.8 — platform reach

- [ ] Windows support (path handling, Chrome discovery, `install.sh` equivalent)
- [ ] Firefox via geckodriver (Selenium already supports it; ref resolution needs testing)
- [ ] Publish to the official MCP registry + Glama/Smithery catalogue metadata (`glama.json`)

## Not planned

- Trace viewer / video artifacts (Playwright MCP does this better; use it there)
- Request mocking beyond the read-only BiDi monitor
- A hosted SaaS. This is a local-first tool.
