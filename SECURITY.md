# Security model

`selenit-mcp` drives a real browser with your cookies and sessions. Treat it as a remote-control
channel: whoever controls the model prompt can control the browser.

## What it can reach

- **Managed mode** (`BROWSER_MODE=managed`): a fresh Chrome profile under `artifacts/`, no personal
  cookies, no logged-in sessions.
- **Existing mode** (`BROWSER_MODE=existing|auto` with a Chrome already listening on
  `--remote-debugging-port`): **your live session**, including every logged-in site. Any local
  process that can reach that port can also drive it, with or without this server.

`auto` (the default) attaches when the port is open and launches a managed Chrome otherwise. If you do
not want an agent touching your own browser, pin `BROWSER_MODE=managed` and use a dedicated port.

## Controls you have

| Control | Variable | Effect |
|---|---|---|
| Host allowlist | `BROWSER_MCP_ALLOWED_HOSTS` | Only these hosts can be navigated to (empty = all) |
| Approval for risky actions | `BROWSER_MCP_REQUIRE_APPROVAL=true` | Buttons labelled delete/pay/send need `confirm=true`, so the model must ask you |
| `data:` URLs | `BROWSER_MCP_ALLOW_DATA` | Off blocks `data:` navigation entirely |
| Audit log | always on | Every tool call → `artifacts/audit-YYYYMMDD.jsonl` |

The audit log masks password/token-like arguments and truncates long text. It records the tool name,
arguments, success flag, duration and URL — enough to reconstruct what an agent did.

## What it does not do

- No network egress of its own: the server talks to Chrome over CDP on localhost and nothing else.
- No credential storage, no telemetry, no "phone home".
- `browser_evaluate` runs arbitrary JS **in the page context** (same origin as the page you are on).
  It cannot read files or spawn processes, but it can read the page's own storage and DOM.

## Reporting a vulnerability

Open a [private security advisory](https://github.com/livdemirci/selenit-mcp/security/advisories/new)
instead of a public issue. Expect an answer within a week. Include the version (`npx selenit-mcp
doctor`), the mode (`managed`/`existing`), and the smallest reproduction you can build.
