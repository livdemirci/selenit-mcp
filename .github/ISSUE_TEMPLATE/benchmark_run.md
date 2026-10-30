---
name: Benchmark run
about: You ran kiyas.rb on a model we have not measured — post the numbers
labels: benchmark
---

## Model

- Model id (as LM Studio reports it):
- Quantisation:
- Runtime + version (LM Studio / llama.cpp / ollama):
- Thinking: on / off
- Hardware (chip, RAM):

## Command

```bash
KOSUM=1 BENCH_MODEL=... ./run_kiyas.sh
```

## Results

Attach the generated `bench/kiyas-<model>-<date>.json` (it contains the per-step traces) and paste
the summary table from the `.md` next to it:

```
paste summary table here
```

## Notes

Anything surprising: bot walls, rate limits, sites that behaved differently from your expectation,
sites that should be added to or removed from the site set.
