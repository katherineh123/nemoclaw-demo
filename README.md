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

Secret values are stored in plaintext on the VM at:

```text
~/.nemoclaw/exec-demo/secrets.tsv
```

This file may contain values such as the NVIDIA inference API key, Brave Search
API key, and GitHub token. It is written with restrictive local permissions
(`chmod 600`), but it is still plaintext storage on the VM. Treat access to the
VM account as access to those saved secrets.

The cached secrets file is not copied into the OpenClaw sandboxes. During demo
startup, the setup script reads the saved values on the VM and injects the
needed credentials through OpenShell's provider/credential flow. For GitHub
publishing, the sandbox Git credential uses an OpenShell placeholder such as:

```text
openshell:resolve:env:GITHUB_TOKEN
```

That lets the OpenClaw agent run normal `git clone`, `git commit`, and `git
push` commands without storing the raw GitHub token in the sandbox workspace.
Inference credentials are configured through the OpenShell gateway provider path
instead of being copied from the cache file into this public demo repository.

Non-secret setup values are cached separately on the VM at:

```text
~/.nemoclaw/exec-demo/env.tsv
```

This file is used for reusable operator inputs such as the GitHub dashboard repo
URL, and can also be used for future non-secret settings such as a custom
Cloudflare domain. These values are not API keys, but they are still local VM
configuration and should not be committed unless intentionally documented.
