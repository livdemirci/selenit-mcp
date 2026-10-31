## Head-to-head: Selenit MCP vs Playwright MCP

- model: `google/gemma-4-e4b` (temperature 0, thinking off, max_tokens 1200)
- runs per site: 1, step budget: 16, tool-output cap per call: 2,000 chars
- date: 2026-10-31T05:59:05Z
- task (identical for both): open the site, search for a term, report the first result heading as `title | url`

| Tool | Tasks passed | Median steps | Median time | Median tool-output chars | Median tokens (prompt+completion) | Tokens / step |
|---|---|---|---|---|---|---|
| selenit | 0/1 | 5.0 | 30.6s | 8177 | 24892 | 4978 |
| playwright | 0/1 | 2.0 | 50.3s | 728 | 12885 | 6443 |

### Per task

| Site | Tool | Result | Reason | Steps | Time |
|---|---|---|---|---|---|
| trendyol | selenit | FAIL | hallucinated | 5 | 30.6s |
| trendyol | playwright | FAIL | not_completed | 2 | 50.3s |

Failures are reported, not hidden: every row above is a real headless run on a live site.
Single-run numbers are noisy; use `KOSUM=3` for medians you would quote publicly.