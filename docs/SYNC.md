# IT Glue → Hudu sync engine

A cross-platform (macOS, Linux, Docker) sync tool that runs alongside the original migration script.
It lets you seed Hudu once, keep it updated with repeated incremental runs while IT Glue is still in
use, and finish with a cutover pass. It never creates duplicates on re-runs.

> Status: the engine, CLI, state handling and the **companies** stage are done. The other stages are
> listed in the catalog as `planned` and are being added one at a time on the same pattern.

## Quick start on a Mac (OrbStack or Docker Desktop)

```bash
git clone https://github.com/bxjtech/ITGlue-Hudu-Migration.git
```

```bash
cd ITGlue-Hudu-Migration
```

```bash
cp .env.example .env
```

Edit `.env` and fill in `HUDU_BASE_URL`, `HUDU_API_KEY`, `ITGLUE_API_URL` and `ITGLUE_API_KEY`.
Then build the image (it runs natively on Apple Silicon):

```bash
docker compose build
```

```bash
docker compose run --rm sync check
```

```bash
docker compose run --rm sync run --stage companies --mode initial --dry-run
```

```bash
docker compose run --rm sync run --stage companies --mode initial
```

State, logs and reports are written to `./data` on your Mac, so they survive container rebuilds.
**Keep `./data` safe**: it holds the IT Glue ↔ Hudu ID map that prevents duplicates.

To run the engine's tests inside the image:

```bash
docker build --target test .
```

### Without Docker

```bash
brew install powershell
```

```bash
./itg-sync check
```

`./itg-sync` reads the same environment variables (export them, or put them in your shell profile)
and stores state in `./data` unless `SYNC_DATA_DIR` says otherwise.

## Commands

| Command | What it does |
|---|---|
| `run` | Sync stages (see options below) |
| `stages` | List stages, their dependencies and the recipes |
| `status` | Last run, mode, watermark, mapped-record count and open flags per stage |
| `flags` | Records left alone for manual review (`--stage x` to filter, `--json` for scripts) |
| `import-legacy --path <dir>` | Adopt an earlier run of the original migration script (see below) |
| `check` | Verify both API keys, the Hudu version (2.39.6+), the export path and data folder |
| `unlock` | Remove a run lock left behind by a killed process |

Both `--stage companies --dry-run` and `-Stage companies -DryRun` styles work.

### Run options

| Option | Meaning |
|---|---|
| `--stage a,b` | Stages to run. Dependency order is enforced within a run. |
| `--recipe core\|assets\|knowledge\|all` | Named groups of stages |
| `--mode initial` | Create and match only; never modifies anything already synced |
| `--mode incremental` | Create new records and update ones that changed in IT Glue |
| `--mode cutover` | Re-evaluate every record regardless of timestamps (final reconciliation) |
| `--company 123,"Acme Corp"` | Limit to IT Glue organizations by ID or exact name (for debugging) |
| `--dry-run` | Show what would change; writes nothing to Hudu or local state |
| `--reapply` | With incremental/cutover, rewrite managed records even if unchanged |
| `--with-dependencies` | Also run required upstream stages that have never synced |
| `--force` | Take over a run lock |

Exit codes: `0` success, `1` the run finished with failed stages or record errors, `2` usage or
configuration error.

## Stages and order

Run stages in any order across separate runs, as long as each stage's **required** stages have
synced at least once. For example, `companies` then `passwords` later is fine; `passwords` before any
`companies` run is refused (or use `--with-dependencies`). When several stages are in one run, they
are put in dependency order automatically.

| Stage | Requires | Runs after (if in the same run) |
|---|---|---|
| companies | | |
| locations | companies | |
| contacts | companies | locations |
| websites | companies | |
| configurations | companies | locations, contacts |
| networks | companies, configurations | |
| flexlayouts | | |
| flexassets | companies, flexlayouts | locations, contacts, configurations |
| articles | companies | |
| passwordfolders | companies | |
| passwords | companies | passwordfolders, websites, configurations, flexassets, contacts, locations |
| checklists | companies | |
| relations | companies | everything that can be related |
| urlrewrite | companies | everything with content |

Recipes: `core` = companies, locations, contacts, websites · `assets` = configurations, networks,
flexlayouts, flexassets · `knowledge` = articles, passwordfolders, passwords, checklists, relations,
urlrewrite · `all` = every stage.

## How duplicates are prevented

1. **ID map.** Every record the engine creates or matches is recorded as IT Glue ID → Hudu ID in
   `data/state/map-<stage>.json`. Re-runs look up the map first, so a record is never created twice.
   Writes go to an append-only journal first, so mappings from a run that crashes halfway are kept.
2. **Change detection.** Each mapping stores a fingerprint of the data last sent to Hudu. A record is
   only updated when the IT Glue side produces a different fingerprint, so re-runs with no IT Glue
   changes make zero writes, and later Hudu-side edits (for example rewritten links) are not clobbered.
3. **Name fallback.** If the map is lost, records are matched to existing Hudu records by name
   instead of being created again. Companies can also carry a back-reference (`ITG:<id>` in Hudu's
   ID Number field, `Companies.WriteBackReference`), which lets them re-link even after a rename.
4. **No blind retries on create.** Reads and updates are retried on rate limits and server errors;
   creates are retried only on rate limits, because retrying a create that may have succeeded could
   duplicate it.
5. **One run at a time.** A lock file stops two scheduled runs from overlapping.

## What gets flagged (and left alone)

| Flag | Meaning |
|---|---|
| `deleted-in-itglue` | The record is gone from IT Glue; the Hudu record is untouched |
| `missing-in-hudu` | The mapped Hudu record was deleted; it is not re-created |
| `hudu-modified` | Changed on both sides since the last sync; resolved per `ConflictPolicy` |
| `name-collision` | The Hudu name is already mapped to a different IT Glue record |
| `duplicate-name` | IT Glue has several records with this name; the Hudu copy got a `-N` suffix |

Flags are kept in `data/state/flags.json`, listed by `flags`, and included in every run report.
A flag disappears once a full (unscoped) run of that stage no longer finds the condition.

## Cutover playbook

1. **Seed:** `run --recipe all --mode initial` (or stage by stage).
2. **Keep current:** schedule `run --recipe all --mode incremental` nightly while people still use
   IT Glue.
3. **Cutover day:** freeze IT Glue edits, then `run --recipe all --mode cutover --dry-run`, review
   the report, then run it for real.
4. **Review:** `flags`, and the report in `data/reports/`.

### Scheduling (external)

The container does not schedule itself. On a Mac, use `crontab -e`; for example, nightly at 1:15 AM:

```
15 1 * * * cd /Users/you/ITGlue-Hudu-Migration && /usr/local/bin/docker compose run --rm sync run --recipe all --mode incremental >> data/cron.log 2>&1
```

(With OrbStack the `docker` binary is typically at `/usr/local/bin/docker` or `~/.orbstack/bin/docker`;
run `which docker` to check.) The run lock means an overlapping run exits with an error instead of
running twice.

## Coming from the original migration script

If you already ran `ITGlue-Hudu-Migration.ps1`, copy its `MigrationLogs` folder into `data/` and run:

```bash
docker compose run --rm sync import-legacy --path /data/MigrationLogs --dry-run
```

```bash
docker compose run --rm sync import-legacy --path /data/MigrationLogs
```

Records the script created become managed by the sync. On their first sync, records not changed in
IT Glue since the logs were written are recorded as a baseline without touching Hudu, so rewritten
links are preserved. Records changed since then are updated. Records the script matched to
pre-existing Hudu data stay reference-only.

## Configuration

Secrets come from environment variables (`.env` with Docker). Non-secret options can go in
`data/sync.config.json` (copy `sync.config.example.json`):

| Setting | Default | Meaning |
|---|---|---|
| `ConflictPolicy` | `itglue-wins` | When both sides changed: `itglue-wins` applies IT Glue and flags; `hudu-wins` keeps Hudu and flags |
| `LockStaleHours` | `12` | A lock older than this is treated as abandoned |
| `Companies.UpdatePreExisting` | `false` | Also update Hudu companies that existed before the sync (matched by name) |
| `Companies.WriteBackReference` | `false` | Write `ITG:<id>` to the company's ID Number field (leave off if your PSA uses it) |
| `Companies.MergeOrgTypes` | `[]` | IT Glue organization types to fold into one Hudu company, e.g. `["Vendor"]` |
| `Companies.MergeTargetHuduCompany` | `null` | Hudu company ID that merged types map to |

## Files in `data/`

| Path | Contents |
|---|---|
| `state/map-<stage>.json` (+ `.journal.jsonl`) | IT Glue ↔ Hudu ID map with fingerprints |
| `state/stages.json` | Per-stage last success, mode and watermark |
| `state/flags.json` | Open flags |
| `reports/<run>.md`, `.json` | Per-run summary, actions, flags and errors |
| `logs/<run>.log` | Full run log |
