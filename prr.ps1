<#
.SYNOPSIS
  prr - local AI pull-request review rig for Azure DevOps.

.DESCRIPTION
  prr review <PR>    gather PR context + diff, route files to prompts, run Copilot, save findings
  prr triage <PR>    accept / edit / reject each finding
  prr post   <PR>    post accepted findings as inline comment threads
  prr go     <PR>    review, triage, post
  prr queue          PRs waiting on you in every collection (-Review pre-reviews them)
  prr collect <PR>   turn reply files from a prepared review (-Prepare / Copilot skill) into findings
  prr stats          kept vs rejected per route / category, top rejection reasons
  prr clean          remove leftover worktrees, prr refs and unused cached clones (-Runs: old review history)
  prr install-copilot  install the /pr-review and /pr-queue Copilot skills (-Scope User|Repo)
  prr doctor         check setup (-Smoke also sends a tiny prompt to the model)
  prr init           create config.psd1 (-Repo <path> also seeds <repo>\.ai-review)

  <PR> is a PR URL, <Collection>/<id>, or an id with -Collection.

.EXAMPLE
  prr go https://tfs.contoso.com/tfs/Finance/Payments/_git/PaymentsApi/pullrequest/1234
.EXAMPLE
  prr review Finance/1234 -Incremental
.EXAMPLE
  prr triage Finance/1234 -Accept 1,3,5-7 -Reject 2 -Reason 'false positive'
#>
#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('review', 'go', 'triage', 'post', 'collect', 'queue', 'stats', 'clean', 'doctor', 'init', 'install-copilot', 'help')]
    [string]$Command = 'help',
    [Parameter(Position = 1)][string]$PullRequest,
    [string]$Collection,
    [string]$RepoPath,
    [switch]$Incremental,
    [switch]$Force,
    [string[]]$Routes,
    [switch]$KeepWorktree,
    [switch]$NoWorktree,
    [string[]]$Accept,
    [string[]]$Reject,
    [string]$Reason,
    [switch]$List,
    [switch]$All,
    [switch]$Revisit,
    [switch]$NoPostPrompt,
    [switch]$DryRun,
    [switch]$Review,
    [switch]$IncludeDrafts,
    [switch]$Smoke,
    [string]$Repo,
    [switch]$Prepare,
    [int]$Edit,
    [string]$Comment,
    [string]$Suggestion,
    [int]$Days = -1,
    [switch]$Runs,
    [ValidateSet('User', 'Repo')][string]$Scope = 'User',
    [switch]$Uninstall,
    [switch]$WhatIf,
    [string]$Config
)

Import-Module (Join-Path $PSScriptRoot 'PrReview/PrReview.psd1') -Force -DisableNameChecking

function Get-Bound([string[]]$Names) {
    $h = @{}
    foreach ($n in $Names) { if ($script:Bound.ContainsKey($n)) { $h[$n] = $script:Bound[$n] } }
    if ($Config) { $h['ConfigPath'] = $Config }
    $h
}
$script:Bound = $PSBoundParameters

$needsPr = 'review', 'go', 'triage', 'post', 'collect'
if ($Command -in $needsPr -and -not $PullRequest) {
    Write-Host "prr $Command needs a pull request: a PR URL, <Collection>/<id>, or an id with -Collection." -ForegroundColor Red
    exit 2
}

try {
    switch ($Command) {
        'review' { $p = Get-Bound 'PullRequest', 'Collection', 'RepoPath', 'Incremental', 'Force', 'Routes', 'KeepWorktree', 'NoWorktree', 'Prepare'; Invoke-PrReview @p }
        'collect' { $p = Get-Bound 'PullRequest', 'Collection'; Invoke-PrCollect @p }
        'clean' { $p = Get-Bound 'Days', 'Runs', 'All', 'WhatIf'; Invoke-PrClean @p }
        'install-copilot' { $p = Get-Bound 'Scope', 'Repo', 'Force', 'Uninstall', 'WhatIf'; $p.Remove('ConfigPath'); Install-PrCopilotSkill @p }
        'go' { $p = Get-Bound 'PullRequest', 'Collection', 'RepoPath', 'Incremental', 'Force', 'Routes', 'KeepWorktree', 'NoWorktree'; Invoke-PrGo @p }
        'triage' { $p = Get-Bound 'PullRequest', 'Collection', 'Accept', 'Reject', 'Reason', 'List', 'All', 'Revisit', 'NoPostPrompt', 'Edit', 'Comment', 'Suggestion'; Invoke-PrTriage @p }
        'post' { $p = Get-Bound 'PullRequest', 'Collection', 'DryRun', 'Force'; Publish-PrFinding @p }
        'queue' { $p = Get-Bound 'Collection', 'Review', 'IncludeDrafts'; Get-PrQueue @p }
        'stats' { $p = Get-Bound @(); Get-PrReviewStat @p }
        'doctor' { $p = Get-Bound 'Smoke'; Test-PrReviewSetup @p }
        'init' { $p = Get-Bound 'Repo'; Initialize-PrReview @p }
        'help' { Get-Help $PSCommandPath -Detailed }
    }
}
catch {
    if ($_.Exception.GetType().Name -eq 'PrrException') {
        Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    throw
}
