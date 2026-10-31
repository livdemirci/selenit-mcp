## Head-to-head: Selenit MCP vs Playwright MCP

- model: `google/gemma-4-e4b` (temperature 0, thinking off, max_tokens 1200)
- runs per site: 1, step budget: 16, tool-output cap per call: 2,000 chars
- date: 2026-10-31T08:00:18Z
- task (identical for both): open the site, search for a term, report the first result heading as `title | url`

| Tool | Tasks passed | Median steps | Median time | Median tool-output chars | Median tokens (prompt+completion) | Tokens / step |
|---|---|---|---|---|---|---|
| selenit | 2/2 | 8.0 | 86.9s | 9933 | 41112 | 5115 |
| playwright | 1/2 | 4.5 | 74.6s | 1669 | 25179 | 5599 |

### Per task

| Site | Tool | Result | Reason | Steps | Time |
|---|---|---|---|---|---|
| github | selenit | PASS | verified_url | 10 | 130.8s |
| github | playwright | FAIL | not_completed | 3 | 52.3s |
| hurriyet | selenit | PASS | verified_url | 6 | 42.9s |
| hurriyet | playwright | PASS | verified_url | 6 | 96.8s |

Failures are reported, not hidden: every row above is a real headless run on a live site.
Single-run numbers are noisy; use `KOSUM=3` for medians you would quote publicly.