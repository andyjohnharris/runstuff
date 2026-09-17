# Notification improvements

The run-history feature supersedes this plan's session-only retention and completed-detail layout. Finished Stuff now shows static configuration; its History entry retains evidence, output and Check Port Owner across launches. The notification rules below remain unchanged.

## Problem

RunStuff attempts to notify on unexpected exits, but suppresses foreground presentation and discards permission and delivery errors. Exit alerts contain little context. Signal rules discard the matching line, and a later nonzero exit replaces their reason with an exit code.

## Approach

1. **Retain failure evidence in RunStuffCore.** Keep the first recognised TCP bind-conflict line from the current run. Use it to explain a failed exit or a user-configured error rule; never infer failure from arbitrary output. For clean exits, pass the reported conflict separately so the completion notification can show it alongside exit code 0 without changing health or restart policy. Retain the matching line for other signal rules. Clear evidence on the next start.
2. **Complete exit reporting after output drains.** Publish a final snapshot before the exit event so alerts can include the last line, even without a newline. Preserve explicit-rule reasons instead of replacing them with an exit code. User-requested stops remain silent.
3. **Make notification delivery visible.** Present foreground banners, report delivery errors in the existing banner, expose permission status and an Enable Notifications action in Settings. Do not block the supervisor event consumer on a permission prompt. macOS Focus and notification settings remain authoritative.
4. **Offer contextual remediation.** Port-conflict alerts and detail views offer Check Port Owner, View Output and Restart. Check Port Owner runs a read-only `lsof` query in the existing preview terminal. It shows current listeners, or explains that none are visible. It never kills processes. Restart actions on stopped Stuff remain available.
5. **Keep the reason in the UI.** Show concise failure text in the list and supporting evidence in details, independent of notification permission. This is retained for the current app session, not a new persistent incident history.

## Safety and scope

- Recognise narrow Node `listen … EADDRINUSE`, Go `listen tcp … bind: address already in use`, and Ruby/Puma `TCPServer#initialize … Address already in use - bind(2) … port … (Errno::EADDRINUSE)` signatures with a valid TCP port. Do not add broad “error” heuristics.
- A reported conflict can be stale. Label it as a reported bind failure, and query the owner only when requested.
- Do not implement Kill and Restart. A listener can belong to another project, Docker or another user. A future destructive action needs owner identity verification, explicit confirmation and safe handling of PID reuse.
- Notification bodies contain bounded summaries, not arbitrary log tails. Preserve raw terminal bytes and keep the evidence in RunStuff.
- Do not change process spawning, signalling or automatic restart policy.
- The local Buildkite `bin/start` calls `system("overmind", …)` without propagating its exit status. Its completion notification must still report recognised port-conflict evidence. The suggested **bind: address already in use** signal rule additionally marks the run as a failure. No changes were made to that repository or to the user's saved Stuff.

## Verification

- Test the supplied Smokescreen line, Node-style EADDRINUSE, unrelated port numbers, invalid ports and ordinary error text.
- Test failed exits with final unterminated output, clean exits containing conflict text, explicit-rule reasons, evidence reset on restart, and silent user stops.
- Run SwiftPM and Xcode tests and the process acceptance harness after changing exit-event timing.
- Build and inspect failure list/detail states and the owner lookup window using isolated jobs. Verify foreground notification handling and permission status; report any OS-level delivery limitation honestly.

## Progress

Implemented. SwiftPM and Xcode each pass 56 tests. The acceptance harness passes 122 checks across 21 scenarios, with no failures or skipped checks.

Inspected the failure list, detail evidence/actions, permission status and read-only owner lookup in a running app with isolated jobs. Also exercised a wrapper that exits with code 0 and confirmed that its configured error rule retains the failure and remediation action.

During initial verification, macOS reported notification permission denied for the test build. The permission banner and Settings state were verified; OS banner delivery and clicking notification actions were not verified then. The user subsequently supplied a delivered notification, confirming permissions are no longer the cause of their generic completion message.

The clean-wrapper follow-up passes all 56 tests in both SwiftPM and Xcode. Its regression reproduces a Smokescreen bind conflict followed by unrelated shutdown lines and exit code 0, with no signal rules. The exit event retains the port evidence without changing health; the next run clears it. An isolated app run delivered the contextual notification, and the macOS accessibility tree confirmed its port and exit-code text. Screenshot capture did not capture the banner, and remediation clicks were not re-tested in this follow-up.

The UI follow-up also retains this evidence in completed, non-user-stopped job snapshots. The list shows the conflict and a Check output indicator; details show the evidence, exit status and remediation actions. Both 56-test suites pass, including final-snapshot ordering, next-run clearing and user-stop suppression. Inspected both views in an isolated app with exit code 0 and no signal rules.

A proposed extra drain timeout was removed after the retained-child fixture did not reproduce the suspected delay on macOS. Process lifetime handling remains unchanged; the exit event follows the existing completion boundary so it includes final output.
