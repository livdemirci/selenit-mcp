# Launch copy — ready to post

Yayın sırası ve metinler. Her metin gerçek ölçümle doldurulacak; `[RAKAM]` yer tutucuları
`bench/kiyas-*.md` çıktısından gelir. **Uydurma sayı yazma.**

---

## 1. Reddit — r/LocalLLaMA

**Flair:** `Resources` veya `Discussion` (sub'ın güncel kurallarına bak; bazı haftalar `Show & Tell`)

**Title:**
```
I benchmarked a small-model-first browser MCP against Playwright MCP on 5 live sites — the tool surface mattered more than the model
```

**Body:**

```markdown
I keep running 4B-ish models locally for browser tasks and kept hitting the same wall: the model is
fine, the **tool output** is what kills it. A 40-element ref list works; a 3000-line accessibility
tree does not — the model burns its context, invents selectors, and loops.

So I built `selenit-mcp` (Selenium + CDP attach) with the tool surface designed *for* small models:
compact `e1`-style dumps (~1–4 KB), a loop guard that stops the third identical call, modal/overlay
detection, and actionable errors ("ref is renewed every snapshot", "element is covered").

Then I ran it head-to-head against the official Playwright MCP, same model, same machine, same task,
same scoring rule (a claimed heading must actually exist in the live page text — invented headings
are counted as failures):

| Tool | Tasks passed | Median steps | Median time | Median tokens (prompt+completion) |
|---|---|---|---|---|
| selenit-mcp | 2/5 | 3.0 | 67.7s | 16,576 |
| Playwright MCP | 0/5 | 3.0 | 100.4s | 18,234 |

Model: `google/gemma-4-e4b` on LM Studio, thinking off, temperature 0. Sites: Wikipedia, npm,
GitHub, Hürriyet, Trendyol. Raw JSON with every step's trace is in `bench/`.

**The honest part:** 2/5 is not a good score. It is not a universal win, and on this run total tokens
are within 10% of each other, so I cannot claim a token win either. Two of Selenit's five "answers"
were fabricated page titles — my scorer caught them and counted them as failures, and they are in the
JSON. My x86 answer: the tool surface buys task completion (2/5 vs 0/5, and the Wikipedia trace is the
cleanest example), it does not yet make live-site search reliable on a 4B model.

Where it does help is the failure mode r/LocalLLaMA knows well: the repetition spiral. Playwright
MCP spent 16 steps / ~300 s on Wikipedia retrying the same `browser_type` target after an error;
Selenit answered in 3 steps because the third identical call gets a directive instead of an execution.

Repo: https://github.com/livdemirci/selenit-mcp
More detail: [Medium article]
If you have Qwen 3.5 4B / LFM 1.7B running, `./run_kiyas.sh` reproduces the whole table — I'd
genuinely like to see numbers from models I haven't tested.
```

**Yayın notu:** İlk yorum olarak benchmark JSON'unu ve `run_kiyas.sh` çıktısını yapıştır. Savunmaya
geçme; "hangi sitede kaybediyor" sorusuna doğrudan JSON linkiyle cevap ver.

---

## 2. Hacker News — Show HN

**Title:**
```
Show HN: Selenit – Browser automation MCP tuned for small local models
```

**First comment (HN'de yazarın kendi yorumu):**

```
Author here. This started from a practical annoyance: I run Gemma E4B locally and wanted it to do
real browser tasks. Every browser MCP I tried is designed around a large-model assumption — big
accessibility trees, verbose output, "you have plenty of context". A 4B model does not, so it burns
steps, repeats calls, and reports things it did not see.

What I changed, and why:

- Compact refs (`e1`, `e2`) renewed per snapshot instead of CSS selectors. Small models hallucinate
  selectors; they handle opaque refs much better.
- A loop guard: the third identical tool call with unchanged page state is not executed. It gets a
  directive instead ("stop and answer", "try another element"). Before that fix Gemma looped on
  browser_snapshot 6x for 128s on n11.com; after it, it answered in 3 steps.
- Dump ordering: form fields, then sort/filter, then primary action, then everything else. Measured
  on n11: 485 interactive elements, 40 slots — the header search box was never in the dump when
  cards came first.
- Deterministic replay: a successful exploration becomes a model-free scenario, then an RSpec spec.
  The model pays once.

It's Selenium-based, attaches to an existing Chrome over CDP, and every tool call is audit-logged.

The benchmark against Playwright MCP is in the repo with full traces. It is small-N on live sites and
I say so in the README; the claim is not "Selenium beats Playwright", it's "the tool surface changes
small-model success rate". Failures are published, not filtered.

Happy to answer anything about the measurement setup, including where it loses.
```

**Yayın notu:** Salı–Perşembe 14:00–16:00 UTC. Yayınladıktan sonra 4 saat boyunca yorumlara cevap ver;
HN'de oy istemek kural ihlali.

---

## 3. X — 4 parçalı thread

```
1/
Small models don't fail browser automation because they're dumb.

They fail because the tool output is written for a model with 200k context.

I measured it. 🧵
```

```
2/
The failure is always the same shape:

→ tool output is huge
→ context fills
→ model repeats a call
→ repeats it again
→ no answer

Playwright MCP on Wikipedia with gemma-4-e4b: 16 steps, ~300 s, same browser_type target retried
9 times, zero answer.
```

```
3/
What I changed in selenit-mcp:

• compact e1-style refs (~1–4 KB dumps, 40 elements)
• third identical call → not executed, gets a *directive*
• form → sort/filter → primary action → rest (dump ordering by fatal-absence)
• modal/overlay/shadow DOM awareness
• actionable errors instead of stack traces
• model-free replay of a successful run
```

```
4/
Head-to-head vs Playwright MCP, same model, same task, 5 live sites:

selenit:     2/5 pass
playwright:  0/5 pass

Raw JSON, every trace, failures included:
github.com/livdemirci/selenit-mcp

Not "Selenium > Playwright". Tool design for small models > tool design for big ones.
```

---

## 4. DEV.to / Medium #2 başlık ve açı

**Başlık:**
```
Can a 4B Local Model Reliably Control a Real Browser? A Measured Answer
```

**Açı (mevcut Medium yazısını tekrarlama):** Tek yazı "ne oldu"; bu yazı "neden oldu ve neyi
düzelttim" olacak. İçerik:

1. Ölçüm protokolü: aynı sistem promptu, aynı görev metni, iki taraf da kendi yerleşik araç listesiyle,
   2.000 karakter tool-output tavanı, ölçüt = başlık gerçekten sayfada mı.
2. Token muhasebesi: `usage.prompt_tokens` / `usage.completion_tokens`, adım başına.
3. Hata anatomisi: model hangi tool parametresini yanlış kuruyor (gerçek trace'ler).
4. Düzeltmelerin ölçülmüş etkisi: her düzeltme öncesi/sonrası adım sayısı.
5. Nerede kaybediyor: yüksek token/adım vakaları ve neden.

---

## 5. Katalog başvuruları — sıra

1. **Official MCP Registry** — `server.json` + `mcp-publisher publish` (npm paketi yayında olmalı)
2. **Glama** — repo URL'i ile ekle; `glama.json` ekle (aşağıda)
3. **Smithery** — `smithery.yaml` gerekir; STDIO + npx için uygun
4. **Awesome MCP Servers** — PR: `Browser Automation` bölümüne tek satır
5. **MCP.so / LobeHub MCP** — başvuru formu

### `glama.json` (repo köküne)

```json
{
  "$schema": "https://glama.ai/mcp/schemas/server.json",
  "maintainers": ["livdemirci"]
}
```

---

## 6. GitHub repo ayarları (elle, tek seferlik)

- **Description:** `Browser automation MCP built for small local models (1B–8B): compact e1-style snapshots, loop guard, CDP attach, deterministic replay. Selenium-based.`
- **Topics:** `mcp`, `model-context-protocol`, `browser-automation`, `selenium`, `local-llm`, `small-language-models`, `gemma`, `lm-studio`, `ai-agents`, `web-automation`, `playwright-alternative`, `cdp`
- **Social preview:** 1280×640 PNG. Metin: `Selenit MCP — browser automation for small models`, arka planda kompakt bir `e1 … e12` liste görüntüsü + Chrome penceresi.
- **Releases:** v0.4.1 → v0.5.0 (bu değişikliklerle), CHANGELOG'dan notlar.
- **Discussions:** enabled (Announcements, Q&A, Show your benchmark).