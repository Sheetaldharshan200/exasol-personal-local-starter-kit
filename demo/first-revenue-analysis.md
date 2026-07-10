# First workflow — revenue analysis you can trust

This is the kit's core loop, done once, end to end: **ask → inspect the SQL → run → validate → rerun**. It takes about 10 minutes and ends with an answer you didn't just receive — you *checked* it.

## Before you start

1. Kit installed and healthy: `exakit status` says `running`
2. AI assistant connected (see your OS quickstart or [QUICKSTART.md](../QUICKSTART.md) step 4)
3. Sample data loaded (the installer offers this; run it yourself any time with):
   ```bash
   exakit data-load
   ```
   You can also point the workflow at any data you upload yourself (`exapump upload yourfile.csv --table STARTER_KIT.MYDATA -p starter-kit`).

## Step 1 — Discover (let the assistant look around)

Paste into your assistant:

> What schemas and tables are available in my Exasol database? For the tables in the TPCH schema, describe their columns and how they relate to each other.

The assistant uses the MCP server's metadata tools — no SQL runs yet. You should see the sample retail tables (customers, products, orders, returns) with their columns. This step matters: the assistant grounds itself in the *real* schema instead of guessing.

## Step 2 — Ask, but see the SQL first

> Which product category generated the most revenue? **Show me the SQL you intend to run and explain it before executing.**

That bolded instruction is the habit this kit teaches. The assistant should reply with a query and an explanation — read it before anything runs. Things worth actually checking:

- Which table and columns define "revenue"? (price × quantity? an amount column?)
- Are returns subtracted, or is this gross revenue?
- Is anything filtered out (date ranges, cancelled orders)?

If you disagree with a choice, say so — e.g. *"subtract returned orders, then show me the revised SQL."* Iterate until the SQL says what *you* mean by revenue.

## Step 3 — Run

Tell the assistant to execute. The MCP server is read-only, so the worst any query can do is read data. You get the result table in the conversation.

## Step 4 — Validate independently (the trust step)

Don't take the assistant's number on faith — reproduce it yourself, outside the assistant, with the SQL you just inspected:

```bash
exapump sql -p starter-kit "<paste the approved SQL here>"
```

Same number? That's the point of the whole kit: the AI's answer is now *your* answer, verified through an independent path. (Also try changing one thing — a filter, a grouping — and see the number move the way you'd expect.)

## Step 5 — Make it rerunnable

Save the outcome so it survives beyond this chat session. Two lightweight options today:

1. **Save the SQL** to a file and rerun any time:
   ```bash
   mkdir -p ~/.exasol-starter-kit/workflows
   # paste the approved SQL into revenue-by-category.sql, then:
   exapump sql -p starter-kit < ~/.exasol-starter-kit/workflows/revenue-by-category.sql
   ```
2. **Record the workflow** — the file next to this guide, [`first-revenue-analysis.workflow.json`](first-revenue-analysis.workflow.json), captures this session (question, approved SQL, validation) in a structured, rerunnable form. Use it as the template for your own.

Kit 2 (the Trusted AI Workflow Add-on) turns this from a convention into a feature: an audit/run log in the database, semantic definitions so "revenue" is defined once, and saved workflows as first-class assets. `bash ~/.exasol-starter-kit/kit/upgrade/upgrade-kit2.sh` when you're ready.

## Where to go next

- Ask a harder question — *"monthly revenue trend by region, top 3 categories only"* — and hold the same discipline: SQL first, validate after
- Bring your own data: `exapump upload data.csv --table STARTER_KIT.MYTABLE -p starter-kit`, then ask about it
- If something misbehaves: `exakit status`, `exakit logs`, and the troubleshooting table in the [README](../README.md)
