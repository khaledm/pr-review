Focus: files that don't belong to a specific stack, such as pipeline YAML, PowerShell and batch scripts, JSON/XML configuration, documentation and build files.

Look hardest for:
- Secrets, tokens, passwords or connection strings committed to the repo.
- Pipeline and script changes that could deploy to the wrong environment, skip tests or quality gates, or run with more permissions than needed.
- Scripts that are destructive without safeguards (deleting, overwriting, dropping) or that fail silently (no error checking / `$ErrorActionPreference`).
- Configuration values that differ between environments without a matching change elsewhere.
- Documentation that now contradicts the code in this PR.
