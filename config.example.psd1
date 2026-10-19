# prr configuration. 'prr init' copies this to config.psd1. Lines starting with # are comments.
@{
    # ---------------------------------------------------------------- Azure DevOps collections
    # One entry per collection (Azure DevOps Server) or organisation (Azure DevOps Services).
    #   Url        Azure DevOps Server:   https://tfs.contoso.com/tfs/Finance   (or https://ado.contoso.com/Finance)
    #              Azure DevOps Services: https://dev.azure.com/contoso
    #   Auth       Auto (default)       PAT if the PatEnvVar environment variable is set, otherwise your Windows login
    #              DefaultCredentials   your Windows login (Kerberos/NTLM) - usual for on-prem servers, no PAT needed
    #              PAT                  personal access token from the PatEnvVar environment variable
    #              AzureCli             token from 'az login' (dev.azure.com organisations backed by Entra ID)
    #   PatEnvVar  defaults to AZURE_DEVOPS_PAT. PAT scopes: Code (Read), Pull Request Threads (Read & write),
    #              Work Items (Read), Project and Team (Read).
    #   ApiVersion defaults to 7.1. Older servers are detected automatically and the version is lowered for you.
    #   Projects   projects 'prr queue' searches. Empty = every project in the collection (slower).
    Collections       = @(
        @{
            Name     = 'Finance'
            Url      = 'https://tfs.contoso.com/tfs/Finance'
            Auth     = 'DefaultCredentials'
            Projects = @('Payments', 'Ledger')
        }
        @{
            Name      = 'Retail'
            Url       = 'https://tfs.contoso.com/tfs/Retail'
            Auth      = 'Auto'
            PatEnvVar = 'ADO_PAT_RETAIL'
            Projects  = @()
        }
    )

    # Collection used when you type a bare PR id (prr review 1234). Otherwise use Retail/1234 or paste the PR URL.
    DefaultCollection = 'Finance'

    # ---------------------------------------------------------------- where the code comes from
    Source            = @{
        # Api   (default) no clone at all: changed files and their old/new versions come from the Azure DevOps API.
        #       Copilot gets the full new version of every changed file to read. Nothing to clean up.
        # Clone use a local clone: Copilot CLI can read the WHOLE repository, and Checks (lint/build) can run.
        Mode           = 'Api'
        # Clone mode only: where AutoClone puts repos (default runs\_repos). prr only ever deletes clones in here.
        CacheDir       = $null
        # 'prr clean' (and the daily auto-clean) removes cached clones and prr refs unused for this many days.
        CleanAfterDays = 14
        AutoClean      = $true
    }

    # Clone mode only - folders that contain your own clones (searched 3 levels deep, matched by remote URL).
    CloneRoots        = @('C:\src')

    # Clone mode only - explicit mapping when auto-discovery can't work out which folder is which:
    #   '<Collection>/<Project>/<Repo>' (or '<Project>/<Repo>' or '<Repo>') = '<folder>'
    Repos             = @{
        # 'Finance/Payments/PaymentsApi' = 'D:\work\PaymentsApi'
    }

    # Clone mode only - clone repos you don't have into Source.CacheDir (blobless, no checkout). Removed again
    # by 'prr clean' once unused for CleanAfterDays.
    AutoClone         = $false

    Git               = @{
        Remote       = 'origin'
        # Clone mode: temporary read-only checkout of the PR's source commit (your working copy is never touched),
        # removed after each review. Lets Copilot CLI open related files, and lets Checks run against the PR's code.
        UseWorktree  = $true
        # Unchanged lines shown around each change (both modes).
        ContextLines = 10
    }

    # ---------------------------------------------------------------- model
    Model             = @{
        # copilot-cli | vscode | command | manual
        Backend    = 'copilot-cli'

        # GitHub Copilot CLI. The prompt is piped on stdin; -s prints only the answer.
        # Shell and write tools are denied, so it can read files but not change anything.
        CopilotCli = @{
            Command        = 'copilot'
            # $null = your Copilot default. Or a model your organisation enables (run 'copilot', then /model to list them).
            Model          = $null
            Args           = @('-s', '--no-ask-user', '--deny-tool=shell', '--deny-tool=write')
            ExtraArgs      = @()
            TimeoutSeconds = 900
        }

        # Copilot Chat in VS Code (agent mode). prr writes the prompts to the run folder, opens Copilot Chat on them
        # with 'code chat', and waits until Copilot has written one reply file per prompt.
        VsCode     = @{
            Command        = 'code'          # 'code-insiders' for Insiders
            Mode           = 'agent'
            TimeoutMinutes = 30
        }

        # Any command that reads the prompt on stdin and prints the reply. {prompt_file} = path of the saved prompt.
        Command    = @{
            Argv           = @()
            TimeoutSeconds = 900
        }

        # Copy each prompt to the clipboard, paste it into Copilot Chat yourself, save the reply to the file shown.
        Manual     = @{
            CopyToClipboard = $true
        }
    }

    Review            = @{
        # One extra call per PR that checks the change against the description and linked work items.
        RunPrIntent         = $true
        # Findings below this confidence are hidden from triage (kept in findings.json as 'filtered').
        MinConfidence       = 0.5
        MaxFindingsPerBatch = 15
        # Files for one route are packed into calls up to this many characters.
        MaxBatchChars       = 120000
        MaxFileDiffChars    = 50000
        # Model calls running at the same time (copilot-cli and command backends).
        Parallel            = 3
        # Paste whole changed files into the prompt as well (useful with the vscode/manual backends).
        IncludeFullFiles    = $false
        MaxFullFileChars    = 40000
    }

    Triage            = @{
        # Editor for the [e]dit key. $null = $env:EDITOR, else Notepad. VS Code: 'code --wait'
        Editor = $null
    }

    Post              = @{
        # suggestion = Azure DevOps suggested-change block | code = plain code block | none = text only
        SuggestionFormat = 'suggestion'
        # Appended to every posted comment, e.g. '_AI-assisted, reviewed by Mahmud_'
        Footer           = ''
    }

    # Clone mode only. Deterministic checks run in the worktree before the model; output goes into the prompts of the listed routes.
    # {worktree} is replaced with the worktree path.
    Checks            = @(
        @{
            Name           = 'angular lint'
            Enabled        = $false
            Routes         = @('angular')
            Cwd            = '{worktree}\src\YourAngularApp'
            Command        = @('npx', '--no-install', 'ng', 'lint')
            TimeoutSeconds = 600
        }
        @{
            Name           = 'typescript compile'
            Enabled        = $false
            Routes         = @('angular')
            Cwd            = '{worktree}\src\YourAngularApp'
            Command        = @('npx', '--no-install', 'tsc', '--noEmit', '-p', 'tsconfig.json')
            TimeoutSeconds = 600
        }
        @{
            Name           = 'msbuild'
            Enabled        = $false
            Routes         = @('csharp', 'playwright')
            Command        = @('msbuild', '{worktree}\YourSolution.sln', '/restore', '/m', '/v:minimal')
            TimeoutSeconds = 1200
        }
    )

    # Prompts, replies and decisions per PR (relative = inside the rig folder).
    RunsDir           = 'runs'
}
