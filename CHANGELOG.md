# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow semver; the tool
surface (23 tools) and MCP protocol behaviour are the API.

## [Unreleased]

### Added
- `kiyas.rb` — external-reproducible head-to-head benchmark (Selenit vs Playwright MCP) with
  per-step traces, real LM Studio token counts (`usage.prompt_tokens` / `usage.completion_tokens`),
  median summary and a paste-ready Markdown table. Writes `bench/kiyas-<model>-<timestamp>.{json,md}`.
- `run_kiyas.sh` — wrapper that keeps a full run alive independently of the terminal session.
- GitHub Actions smoke job (Ubuntu + macOS × Ruby 3.2/3.3, headless Chrome, local scenario app).
- `CONTRIBUTING.md`, `SECURITY.md`, `ROADMAP.md`.

### Fixed
- `kiyas.rb` cross-run isolation used a bare `chrome-profile-` pkill pattern, which also matched the
  harness's own command line and killed the running benchmark. The pattern is now port-scoped
  (`chrome-profile-<port>`).

### Changed
- README restructured: benchmark table and one-command install are now above the engineering log.

## [0.4.1]

### Added
- ARIA role targeting (`browser_find(role:, name:)`) on top of refs.
- Four measured failure fixes (arabam scenario went 0/2 → 2/2): overlay-gated search input,
  colour/02 tooltip layering, and two snapshot label fixes.

## [0.4.0]

### Added
- Fair-comparison protocol (`kiyas_protokol.rb`): identical system prompt and task text for both
  tool surfaces, tool-surface equality report (12 shared tools, 23 vs 25 total).
- Error audit (`hata_denetimi.rb`): every tool's error path carries a helper hint and a directive.
- Token-cost measurement (`token_maliyeti.rb`) across both MCPs.

### Changed
- `browser_read` prefers the main content container and appends a DURUM (status) line.
- URL-scheme submit fallback validates the destination page, not just the URL.

## [0.3.x]

### Added
- Live-site comparison on four Turkish marketplaces (`kiyas_4site.rb`), one-run and post-fix runs.
- Bot-wall diagnosis (`diagnose_wall.rb`), 4 false negatives + 1 false positive corrected.

## [0.2.x]

### Added
- Loop guard with per-tool directives (measured: n11 `browser_snapshot` loop 6× / 128 s → 3 steps).
- Modal focus, overlay priority, row/card context, shadow DOM, iframe support.
- Model-free replay (`replay.rb`) and RSpec export (`export_rspec.rb`).

## [0.1.0]

- First public release: CDP attach, compact `e1`-style dumps, 23 tools, audit log, npm wrapper.
