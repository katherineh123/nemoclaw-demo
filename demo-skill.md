# Supply Chain Operations — Headcount & Delivery Performance

**Category:** Operations / Supply Chain Analytics
**Owner:** Supply Chain Analytics Team
**Last Updated:** April 2026
**Tags:** headcount, fulfillment, factory-ops, forecasting, reporting

---

## Demo Runtime & Publishing Contract

For this hands-on demo, each OpenClaw sandbox is assigned exactly one GitHub Pages output folder. Before creating or publishing any visualization, load the sandbox runtime values:

```bash
set -a
. /sandbox/.nemoclaw-demo/dashboard.env
set +a
mkdir -p "$DASHBOARD_OUTPUT_DIR"
```

The important values are:

| Variable | Meaning |
|---|---|
| `EXEC_SANDBOX` | Your assigned demo identity, e.g. `exec-01`. |
| `DASHBOARD_OUTPUT_DIR` | Local directory where you must write the static dashboard files. |
| `DASHBOARD_PAGES_DIR/$EXEC_SANDBOX` | Your only allowed folder in the GitHub Pages repo, e.g. `docs/exec-01`. |
| `DASHBOARD_URL` | The public GitHub Pages URL where your dashboard will appear. |
| `DASHBOARD_REPO_URL` | GitHub repo URL for the dashboard site. Git credentials are already configured through OpenShell. |
| `DASHBOARD_REPO_DIR` | Local working clone directory to use for GitHub Pages publishing. |

Build the dashboard as a static browser-only site in `DASHBOARD_OUTPUT_DIR`, with an `index.html` entry point. Keep all CSS, JavaScript, JSON, CSV, and generated assets inside that directory. When ready, publish it with normal `git` commands:

```bash
if [ ! -d "$DASHBOARD_REPO_DIR/.git" ]; then
  git clone --branch "$DASHBOARD_REPO_BRANCH" "$DASHBOARD_REPO_URL" "$DASHBOARD_REPO_DIR" || git clone "$DASHBOARD_REPO_URL" "$DASHBOARD_REPO_DIR"
fi
cd "$DASHBOARD_REPO_DIR"
git fetch origin "$DASHBOARD_REPO_BRANCH"
git checkout "$DASHBOARD_REPO_BRANCH" 2>/dev/null || git checkout -b "$DASHBOARD_REPO_BRANCH" "origin/$DASHBOARD_REPO_BRANCH"
git pull --rebase origin "$DASHBOARD_REPO_BRANCH"
target="$DASHBOARD_PAGES_DIR/$EXEC_SANDBOX"
mkdir -p "$target"
find "$target" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -R "$DASHBOARD_OUTPUT_DIR"/. "$target"/
touch "$DASHBOARD_PAGES_DIR/.nojekyll"
git add "$DASHBOARD_PAGES_DIR/.nojekyll" "$target"
if ! git diff --cached --quiet; then
  git commit -m "Update $EXEC_SANDBOX dashboard"
  git push origin "HEAD:$DASHBOARD_REPO_BRANCH" || {
    git pull --rebase origin "$DASHBOARD_REPO_BRANCH"
    git push origin "HEAD:$DASHBOARD_REPO_BRANCH"
  }
fi
```

Publishing to GitHub is what makes the dashboard viewable outside the VM: GitHub Pages serves the committed files at `DASHBOARD_URL`. Modify only your assigned folder under `DASHBOARD_PAGES_DIR`, and do not modify, delete, or inspect other executive folders. Never print, copy, or commit files under `/sandbox/.nemoclaw-demo/`; Git authentication is already configured through OpenShell credential placeholders.

---

## Overview

This article documents how we measure and model the relationship between factory headcount and on-time delivery performance across our two manufacturing sites. It is the reference for supply chain analysts, operations managers, and any tooling or agents involved in factory performance analysis and reporting.

---

## Our Factories

### Germany Factory *(also referred to as Factory A or Europe Operations)*
- **Products:** Industrial drives (AA1 line)
- **Markets served:** Germany and broader European region
- **Current headcount target:** ~250 workers
- **Data identifier in systems:** `Factory A (Europe)`

### Asia Factory *(also referred to as Factory B or Asia-Pacific Operations)*
- **Products:** Control units (TQW line)
- **Markets served:** China, Korea, India, and other Asia-Pacific and Americas markets
- **Current headcount target:** ~200 workers
- **Data identifier in systems:** `Factory B (Asia)`

> **Note on total headcount:** Combined headcount across both sites is managed as a fixed pool of 450. Workforce planning operates on a transfer model — increasing headcount at one site requires a corresponding reduction at the other. Net new hiring is handled separately through a longer-lead HR process and is not reflected in operational transfer decisions.

---

## Key Metrics

**On-time delivery rate (fulfillment rate)** is the primary factory performance KPI. It is defined as the percentage of customer orders delivered on or before the committed delivery date in a given month. In our internal data systems this field is called `fulfillment_pct`.

Internal performance thresholds:
| Zone | Fulfillment Rate | Meaning |
|------|-----------------|---------|
| 🟢 On Track | ≥ 85% | Within acceptable range |
| 🟡 At Risk | 70–84% | Requires attention |
| 🔴 Critical | < 70% | Escalation required |

These thresholds apply consistently across all factory reporting and visualizations.

---

## Data

Historical monthly headcount and delivery performance data for both factories is maintained in the company's version-controlled data repository. The data file is a CSV named `factory-delivery-data`.

| Column | Description |
|--------|-------------|
| `month` | Month of observation (YYYY-MM-DD) |
| `factory` | Factory identifier (`Factory A (Europe)` or `Factory B (Asia)`) |
| `total_headcount` | Total workers on site that month |
| `new_hires` | Workers who joined this month |
| `workers_1mo` | Workers who joined last month |
| `workers_2mo` | Workers who joined two months ago |
| `tenured` | Workers with 3+ months on site |
| `fulfillment_pct` | On-time delivery rate for that month (%) |

---

## Forecasting Methodology

Our standard approach for short-term fulfillment forecasting is a linear regression on headcount composition. Analysts should examine the available headcount columns and determine which combination best predicts fulfillment, report the fitted formula and coefficients, and include a backtest showing predicted vs actual to give stakeholders a sense of model fit. Forecasts should cover a **6-month forward window** as the default planning horizon unless a specific timeframe is requested.

Forward projections should simulate cohort aging month-by-month from the most recent observed state: each month, `new_hires` graduate to `workers_1mo`, `workers_1mo` graduate to `workers_2mo`, `workers_2mo` join `tenured`, and `new_hires` is set to zero (no new hiring assumed unless explicitly modeled). This means the projected fulfillment curve will naturally rise slightly as recent hires complete their ramp, then plateau once all workers are fully tenured.

Projections should always be accompanied by a plain-language business summary — e.g. *"At current headcount, the Germany factory is projected to fulfill approximately X% of orders on time over the next 6 months, placing it in the [zone] category."*

---

## Reporting & Visualization Standards

All factory performance visualizations are published to our internal dashboard hosted on GitHub Pages. Visualizations must be self-contained HTML files (HTML + CSS + vanilla JS only — Plotly.js or Chart.js via CDN are acceptable). No server-side dependencies.

**Publishing workflow:**
1. Load `/sandbox/.nemoclaw-demo/dashboard.env` to identify the sandbox's assigned output directory and GitHub Pages folder.
2. Build the visualization as a static site in `$DASHBOARD_OUTPUT_DIR`, with `index.html` as the entry point.
3. Clone or update `$DASHBOARD_REPO_URL` in `$DASHBOARD_REPO_DIR`.
4. Copy the static site into `docs/$EXEC_SANDBOX`, commit that folder, and push to `$DASHBOARD_REPO_BRANCH`.
5. GitHub Pages serves the update automatically at `$DASHBOARD_URL`.

**Dashboard repo:** `https://github.com/katherineh123/nemoclaw-demo.git`
Use the sandbox's assigned `docs/$EXEC_SANDBOX` folder only. Do not modify dashboard folders assigned to other executives.

Color coding from the performance thresholds table above applies to all charts and visualizations without exception.
