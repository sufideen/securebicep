# Screenshots

Placeholders for real Azure DevOps screenshots, referenced from the main
[README.md](../../README.md). Each `.svg` here is a stand-in - replace it with a real
`.png` of the same name (and update the image link in README.md to point at the
`.png` instead of the `.svg`) once you've run the pipelines yourself.

| File | What it should show |
|---|---|
| `pipeline-run-success.svg` | A full green run of either pipeline: Validate -> Security gate -> Deploy dev -> Deploy prod |
| `checkov-scan-results.svg` | The Checkov console/SARIF output showing passed and failed checks |
| `prod-approval-gate.svg` | The `prod` Environment paused on its approval check, waiting for sign-off |

Add more as needed - PSRule's Tests-tab output and the What-if diff are two good
candidates if you want to expand this set.
