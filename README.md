# prr: AI pull-request review rig for Azure DevOps (PowerShell 7 + Copilot)

`prr` automates the mechanical parts of a code review. It reads the PR description and work items, gets the diff, picks the right prompt for each file and posts your comments. Your judgement stays in the loop: nothing is posted until you accept it.

There are two ways to drive it:

**A. From Copilot Chat** (recommended). Install the skills once with `prr install-copilot`, then in VS Code / Visual Studio Copilot Chat (agent mode), or in Copilot CLI:

```
/pr-review https://tfs.contoso.com/tfs/Finance/Payments/_git/PaymentsApi/pullrequest/1234
/pr-queue
```

Copilot runs prr to fetch the PR and build the review prompts, answers them itself and shows you the findings as a table. It then records your decisions and posts only what you approve.

**B. From the terminal**:

```powershell
prr review <PR>   # fetch PR context + diff, route each file to the right prompt, run Copilot CLI
prr triage <PR>   # step through findings: accept / edit / reject
prr post   <PR>   # post the accepted ones as inline comment threads
prr go     <PR>   # all three
prr queue         # PRs waiting on you in every collection (-Review pre-reviews them)
```

`<PR>` can be any of:
- a PR URL
- `<Collection>/<id>`, e.g. `Finance/1234`
- a bare id, which uses `DefaultCollection`

## No clone needed

By default (`Source.Mode = 'Api'`) prr never clones anything. For each changed file it downloads the old and new versions through the Azure DevOps API. git's own diff engine (`git diff --no-index`) compares the two copies, so no repository is needed. The full new version of every changed file goes into the run folder for Copilot to read.

Clone mode is optional (`Source.Mode = 'Clone'`). It gives Copilot CLI the whole repository to look through and lets `Checks` (lint, tsc, msbuild) run. When it's on:
- Repos prr clones itself go into a separate cache folder, and `prr clean` removes them after `CleanAfterDays` unused.
- Your own clones are never deleted. prr only adds fetch refs to them (`refs/prr/...`), which `prr clean` also removes.
- Temporary checkouts are removed after every review.
- A safe clean-up runs automatically once a day.

## What happens on a review

1. Finds the collection from the URL or name and signs in. With Windows auth (the default on-prem) no PAT is needed. It detects the server's REST API version automatically.
2. Reads the PR title, description, linked work items (with acceptance criteria), existing comment threads and update history.
3. Gets the changed files from the API (or your clone) and diffs them against the merge base, as the PR "Files" tab does.
4. Routes each file to a focused prompt (`router.psd1`): Playwright tests, SSIS, SQL, C#, Angular, then everything else.
   - **SSIS `.dtsx`** files become a readable summary (connections, SQL, expressions, data flow, script code, precedence constraints), so layout and GUID noise disappear.
   - **UTF-16 `.sql`** files from SSMS are diffed as text.
5. Adds a **PR-intent** prompt that checks the change against the description and acceptance criteria.
6. Gets one JSON answer per prompt from Copilot and saves everything under `runs\<Collection>\pr-<id>\`: prompts, replies, `findings.json` and `report.md`.

## Setup (about 10 minutes)

**You need:** PowerShell 7.2+ (`winget install Microsoft.PowerShell`), Git for Windows, and GitHub Copilot.

1. Unzip to a permanent folder, e.g. `C:\tools\pr-review-rig`, unblock the scripts and add the folder to your user `PATH`:
   ```powershell
   Get-ChildItem C:\tools\pr-review-rig -Recurse | Unblock-File
   [Environment]::SetEnvironmentVariable('Path', $env:Path + ';C:\tools\pr-review-rig', 'User')
   ```
   Open a new terminal.
2. Create and edit the config. **Collections** is the only required part.
   ```powershell
   prr init
   code C:\tools\pr-review-rig\config.psd1
   ```
3. Authentication per collection:
   - **`DefaultCredentials`**: your Windows login, the usual choice on-prem.
   - **`PAT`**: store the token with `setx ADO_PAT_RETAIL "<token>"`, using the variable named in `PatEnvVar`. Scopes: Code (Read), Pull Request Threads (Read & write), Work Items (Read), Project and Team (Read).
   - **`AzureCli`**: for dev.azure.com organisations; run `az login` first.
4. Install the Copilot skills:
   ```powershell
   prr install-copilot
   ```
   This installs `/pr-review` and `/pr-queue` into `~\.copilot\skills`. VS Code, Visual Studio and Copilot CLI all read that folder.
5. Check everything:
   ```powershell
   prr doctor
   ```

## Using it from Copilot Chat

- **`/pr-review <PR>`**
  1. Copilot runs `prr review <PR> -Prepare`, which builds the prompts without calling a model.
  2. It answers each prompt itself, writing the reply files.
  3. It runs `prr collect`, then shows you the findings as a table: id, severity, location, title and the exact comment.
  4. You tell it what to post, reject or reword. It records that with `prr triage ... -Accept / -Reject / -Edit`.
  5. It shows you `prr post -DryRun`, then posts after you confirm.
- **`/pr-review <PR> incremental`**: reviews only what changed since your last review. Earlier decisions carry over.
- **`/pr-queue`**: what's waiting for you in every collection.

**Sharing with the team:** `prr install-copilot -Scope Repo -Repo C:\src\PaymentsApi` puts the skills in that repo's `.github\skills`. Anyone who opens the repo gets the commands, as long as `prr` is on their PATH.

Copilot will ask before running terminal commands and writing files, unless you have allowed them. That approval is your safety net; the skill also never posts without your explicit confirmation.

## Using it from the terminal

```powershell
prr queue                     # every collection: PR, repo, title, author, your vote, local status
prr queue -Review             # pre-review all that need it (new commits -> incremental); drafts skipped
prr go Finance/1234           # review -> triage -> offer to post
```

**Triage keys:** `a` accept · `e` edit in your editor, then accept · `r` reject (with a reason; optionally add a suppression rule) · `s` skip · `d` more diff context · `b` back · `q` quit.

Non-interactive:
```powershell
prr triage Finance/1234 -Accept 1,3,5-7 -Reject 2 -Reason 'false positive'
prr triage Finance/1234 -Edit 4 -Comment 'Could this use a parameter instead?' -Suggestion ''
prr triage Finance/1234 -List
```

**When the author pushes fixes:** `prr review Finance/1234 -Incremental` reviews only what changed since the PR update you last reviewed. Posted findings stay posted, rejected ones stay rejected, and accepted-but-unposted findings on untouched files are kept. `prr post` refuses to post against an outdated review, so comments can't land on shifted lines.

**A route failed, or you changed a prompt:** `prr review Finance/1234 -Force -Routes sql,pr-intent`.

**Before your first real post:** `prr post Finance/1234 -DryRun`.

**`prr stats`** shows the kept vs rejected rate per route, category and severity, plus the top rejection reasons. Use it to see which prompts need tuning.

## Copilot backends for `prr review`

This applies to the terminal flow only; the skills don't use it. Set `Model.Backend`:

| Backend | How it works |
|---|---|
| `copilot-cli` (default) | Each prompt is piped to `copilot -s --no-ask-user`, in parallel, with shell and write tools denied. `CopilotCli.Model` picks the model; run `copilot`, then `/model` to see the list. |
| `vscode` | Opens Copilot Chat in agent mode on the prompts (`code chat`) and waits for its reply files. |
| `manual` | Copies each prompt to the clipboard; you paste the reply into the file shown. |
| `command` | Any CLI that reads a prompt on stdin and prints the reply. |

## Bringing your own prompts

Each file in `prompts\` holds only *what to look for* for one stack. The output format is in `_contract.md`, which is added to every prompt. To use your existing custom prompts:

1. Paste their checklist into the matching file (`csharp-net48.md`, `angular-ts.md`, `sql.md`, `ssis.md`, `playwright-cs.md`, `general.md`, `pr-intent.md`).
2. Remove any "format your output like…" instructions from them. The contract handles that, and conflicting format rules lead to replies that can't be parsed.

**Adding a route:** add an entry to `router.psd1` above the more general routes, and create `prompts\<Prompt>.md`. The first matching route wins.

**Suppressions:** `-` lines in `suppressions.md` are sent with every prompt so known false positives stop coming back.

**Per-repo rules:** commit a `.ai-review` folder to the repo (`prr init -Repo C:\src\PaymentsApi` seeds it). It can hold `router.psd1`, `prompts\` and `suppressions.md`, and these override the rig's copies. In Api mode they are read from the PR's **target** branch, so a PR can't quietly change its own review rules.

## Clean-up

```powershell
prr clean -WhatIf          # see what would go
prr clean                  # leftover worktrees, prr refs and cached clones unused for CleanAfterDays
prr clean -Runs            # also review history of PRs not reviewed for CleanAfterDays (latest run of active PRs kept)
prr clean -Days 3 -Runs    # tighter
prr clean -All -Runs       # everything prr created, including all review history
```

## Troubleshooting

- **"returned a sign-in page" / HTTP 401**: wrong `Auth` for that collection, or the PAT expired.
- **The skill doesn't show up as `/pr-review`**: run `prr install-copilot -Force`, reload VS Code, and make sure Copilot Chat is in agent mode.
- **Copilot CLI hangs or reports a permission error the first time**: run `copilot` interactively once, sign in and trust the folder. Then run `prr doctor -Smoke`.
- **Execution policy errors**: `Unblock-File` the folder (see Setup).
- **Suggested-change blocks show as plain text on your server version**: set `Post.SuggestionFormat = 'code'`.
- **A reply couldn't be parsed**: the prompt and raw reply are in the run folder. Rerun that route with `-Force -Routes <route>`; for a prepared run, fix `response-<route>-<n>.json` and run `prr collect`.

Your code goes to whichever Copilot route you use. Use the one your company has approved.

## Files

```
prr.ps1 / prr.cmd          command-line entry points
PrReview\                  the PowerShell module (Public\ = commands, Private\ = internals)
copilot\skills\            the /pr-review and /pr-queue Copilot skills (installed by 'prr install-copilot')
config.example.psd1        copied to config.psd1 by 'prr init'
router.psd1                file -> prompt routing
prompts\                   _contract.md (output format) + one focus prompt per stack + pr-intent
suppressions.md            team "don't raise this" rules
runs\                      prompts, replies, findings and decisions per collection/PR
```
