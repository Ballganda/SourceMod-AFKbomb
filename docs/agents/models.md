# Models

Each ticket carries a tier (set by `ticket-gen`), and each subagent task has a model. Skills read this file to pick the model; edit the names to match your harness.

| Tier | Use for | Model |
| --- | --- | --- |
| Mechanical | rename, config, docs, copy of an existing pattern | Sonnet |
| Standard | one module, a clear seam, tests that describe it | Opus |
| Hard | crosses modules, a new seam, concurrency, unclear spec | Fable |

| Subagent task | Model |
| --- | --- |
| Ticket writing | Opus |
| Exploration | the Mechanical model |
| Merging | the Standard model |
| Standards review | the Standard model |
| Spec review | the Hard model |
