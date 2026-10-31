## Head-to-head: Selenit MCP vs Playwright MCP

- model: `google/gemma-4-e4b` (temperature 0, thinking off, max_tokens 1200)
- runs per site: 1, step budget: 16, tool-output cap per call: 2,000 chars
- date: 2026-10-30T18:55:46Z
- task (identical for both): open the site, search for a term, report the first result heading as `title | url`

| Tool | Tasks passed | Median steps | Median time | Median tool-output chars | Median tokens (prompt+completion) | Tokens / step |
|---|---|---|---|---|---|---|
| selenit | 1/5 | 1.0 | 0.0s | 0 | 0 | 0 |
| playwright | 0/5 | 1.0 | 0.0s | 0 | 0 | 0 |

### Per task

| Site | Tool | Result | Reason | Steps | Time |
|---|---|---|---|---|---|
| wikipedia | selenit | PASS | verified | 3 | 55.1s |
| wikipedia | playwright | FAIL | empty_answer | 15 | 283.5s |
| npm | selenit | FAIL | empty_answer | 1 | 0.0s |
| npm | playwright | FAIL | empty_answer | 1 | 0.0s |
| github | selenit | FAIL | empty_answer | 1 | 0.0s |
| github | playwright | FAIL | empty_answer | 1 | 0.0s |
| hurriyet | selenit | FAIL | empty_answer | 1 | 0.0s |
| hurriyet | playwright | FAIL | empty_answer | 1 | 0.0s |
| trendyol | selenit | FAIL | empty_answer | 1 | 0.0s |
| trendyol | playwright | FAIL | empty_answer | 1 | 0.0s |

Failures are reported, not hidden: every row above is a real headless run on a live site.
Single-run numbers are noisy; use `KOSUM=3` for medians you would quote publicly.