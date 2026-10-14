# Operations

Use Web or CLI to follow incidents, decide on proposed changes, and check recovery.

## Web

1. Open **Cases** and select an incident. Review the observed problem, desired
   outcome, observations, and proposed actions.
2. In Ask mode, review the proposed Target, action, and expected result.
   Enter your reason and approve or reject the change.
3. Follow the operation and verification results. A completed change does not
   by itself confirm recovery; check the fresh observations against the desired
   outcome.
4. Open the Case report to review the result and evidence. If the Case needs
   attention, inspect the reason before changing its connections, authority,
   or limits and resuming it.

Use the Case's cancellation control to request a stop. If an operation is
`unknown` or `partial`, inspect the Target and recorded evidence before deciding
whether to repeat it.

## CLI

Find the Case and inspect its response:

```sh
skopos case list --limit 20
skopos case show CASE_ID
skopos case timeline CASE_ID
skopos case proposals CASE_ID
skopos case operations CASE_ID
skopos case verifications CASE_ID
```

For a human decision, inspect the proposal with `skopos proposal show PROPOSAL_ID`.
Copy its current `revision` and `proposal_digest` into `decision.json`,
choose `approved` or `rejected`, and enter your reason:

```json
{
  "expected_revision": 1,
  "proposal_digest": "PROPOSAL_DIGEST",
  "decision": "approved",
  "reason": "Explain why this change is approved"
}
```

```sh
skopos proposal decide PROPOSAL_ID --input decision.json
skopos case wait CASE_ID --interval 1000 --timeout 60
skopos case evidence CASE_ID
skopos report list
skopos report read REPORT_ID
```

If a Case needs attention, read its reason with `case show`.
After correcting the problem, copy the current Case revision and latest run's
ID and revision from `case show` into `resume.json`. Set the authority and limits
for the resumed response:

```json
{
  "expected_case_revision": 1,
  "resolution_run_id": "RUN_ID",
  "expected_run_revision": 1,
  "authority_mode": "ask",
  "max_elapsed_seconds": 3600,
  "max_resolver_turns": 20,
  "max_target_requests": 100,
  "max_effects": 10,
  "max_related_targets": 20,
  "max_ai_usage_units": 1000000,
  "max_no_progress_turns": 3,
  "reason": "Explain what was corrected"
}
```

```sh
skopos case resume CASE_ID --input resume.json
skopos case wait CASE_ID --interval 1000 --timeout 60
```

To request cancellation, pass the current Case revision:

```json
{"expected_revision": 1}
```

Save this as `cancel.json`, then run:

```sh
skopos case cancel CASE_ID --input cancel.json
skopos case show CASE_ID
```

A cancellation request does not undo completed changes. For `unknown` or
`partial` operations, inspect `operation show OPERATION_ID` and the affected
Target before retrying.

## Scheduled audits

In Web, open **Audits → Add audit schedule**. Select the Targets, enter the
condition to investigate, cron schedule, time zone, and report language, then
save. Open an audit run to inspect its Cases and results.

In CLI, put the same settings in `audit.json`:

```json
{
  "name": "Hourly infrastructure check",
  "desired_outcome": "Describe the condition to investigate",
  "target_ids": ["TARGET_ID"],
  "cron_expression": "0 * * * *",
  "timezone": "UTC",
  "report_language": "en"
}
```

```sh
skopos audit schedule --input audit.json
skopos audit list
skopos audit-run list
skopos audit-run show RUN_ID
```

## Reports

In Web, open **Reports** to read Case reports and select the period for an
operations summary. Configure notification destinations there when you want
to deliver reports.

In CLI, read reports or request a summary for a time interval:

```sh
skopos report list
skopos report read REPORT_ID
skopos report summary --from START_ISO8601 --to END_ISO8601
skopos delivery list
skopos delivery show DELIVERY_ID
```
