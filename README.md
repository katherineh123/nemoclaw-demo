# nemoclaw-demo

Demo assets for the NemoClaw supply chain AI walkthrough.

## Core files

| File | Purpose |
|------|---------|
| `factory-delivery-data.csv` | 24 months of monthly headcount and on-time delivery data for two factories (Germany / Asia). This is the raw data the agent pulls and analyzes. |
| `enterprise-knowledge-base.md` | Company knowledge base / skill document. Describes the factories, performance thresholds, forecasting methodology, and publishing standards - all in plain language. The agent reads this before starting work to understand the business context. |
| `instructions.html` | Step-by-step demo guide for participants. Explains NemoClaw, data connectors, and walks through all four prompts with "what to expect" notes. |

## Secrets

The NemoClaw demo setup script caches values on the VM so repeated startup runs
do not require retyping every key.

Secret values (NVIDIA inference.nvidia.com key, Brave key, and Github PAT) are stored in plaintext on the VM at:

```text
~/.nemoclaw/exec-demo/secrets.tsv
```

Non-secret setup values are cached separately on the VM at:

```text
~/.nemoclaw/exec-demo/env.tsv
```

The cached secrets file is NOT accessible to the Openclaws. During demo
startup, the setup script reads the saved values on the VM and injects the
 credentials through OpenShell's provider/credential flow.


This file is used for reusable operator inputs such as the GitHub dashboard repo
URL, and can also be used for future non-secret settings such as a custom
Cloudflare domain. These values are not API keys, but they are still local VM
configuration and should not be committed unless intentionally documented.
