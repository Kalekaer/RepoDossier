# Privacy report · v1.2.2

Release builder checks the final ZIP, not an earlier working directory.

- 15 reviewed public demo projects, explicitly labelled demo reports and demo scores.
- Empty user notes, user workspaces and personal status log.
- Exact file allowlist; no backups, temporary files, credentials, host configuration or personal session migration scripts.
- Automated text scan rejects personal user/workspace paths, fixed session identifiers and common GitHub/OpenAI credential patterns. This is a bounded scan, not a claim of exhaustive forensic analysis.
- No automatic upload or telemetry is added to the product. GitHub collection is an explicit workflow action.

Reproduce: `python tools/build-distribution.py --source <clean-public-checkout> --output <output-directory> --version 1.2.2`. The build must pass source and extracted-package checks before publication.
