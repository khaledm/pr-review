function Invoke-PrReview {
    <#
    .SYNOPSIS
      Reviews a pull request: gathers context and the diff, routes files to prompts, runs the model, saves findings.
    .DESCRIPTION
      Source.Mode 'Api' (default) needs no clone: changed files come from the Azure DevOps REST API.
      Source.Mode 'Clone' uses a local clone (needed for Checks, and lets Copilot CLI read the whole repository).
      -Prepare writes the prompts and stops, so a Copilot agent (the pr-review skill) can answer them; then run Invoke-PrCollect.
    .PARAMETER PullRequest
      A PR URL, <Collection>/<id>, or an id (with -Collection / DefaultCollection).
    .EXAMPLE
      Invoke-PrReview https://tfs.contoso.com/tfs/Finance/Payments/_git/PaymentsApi/pullrequest/1234
    .EXAMPLE
      Invoke-PrReview Finance/1234 -Incremental
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$PullRequest,
        [string]$Collection,
        [string]$RepoPath,
        [switch]$Incremental,
        [switch]$Force,
        [string[]]$Routes,
        [switch]$KeepWorktree,
        [switch]$NoWorktree,
        [switch]$Prepare,
        [string]$ConfigPath
    )
    $cfg = Get-PrrConfig $ConfigPath
    $ref = Resolve-PrRef -Ref $PullRequest -Collection $Collection -Cfg $cfg
    $coll = $ref.Coll
    $id = $ref.Id
    $routeFilter = if ($Routes) { @($Routes -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { $null }
    $srcMode = if ($RepoPath) { 'Clone' } else { $cfg.Source.Mode }
    if ($srcMode -notin 'Api', 'Clone') { Stop-Prr "Source.Mode must be 'Api' or 'Clone' (is '$srcMode')" }

    Write-Say "Reviewing $($coll.Name)/$id" -Color White
    $pr = Get-AdoPr $ref $cfg
    if ($pr.status -ne 'active') { Write-Warn "PR is $($pr.status)" }
    if ($pr.isDraft) { Write-Warn 'PR is still a draft' }
    $repoInfo = $pr.repository
    $project = $repoInfo.project.name
    $srcSha = $pr.lastMergeSourceCommit.commitId
    $tgtSha = $pr.lastMergeTargetCommit.commitId
    $state = Get-PrState $cfg $coll $id
    if ($state.last_source_sha -eq $srcSha -and -not $Force -and -not $routeFilter) {
        Write-Say "Already reviewed source commit $($srcSha.Substring(0, 8)). Use -Force to run again, or 'prr triage $($coll.Name)/$id'."
        if ($Prepare) { Write-Say "PRR_RUN_DIR=$(Join-Path (Get-PrDir $cfg $coll $id) $state.last_run)" }
        return
    }
    $srcRef = $pr.sourceRefName; $tgtRef = $pr.targetRefName
    Write-Say "  $($pr.title)"

    $iterations = @(Get-AdoIteration $coll $pr)
    $lastIter = [int](($iterations | ForEach-Object { [int]$_.id } | Measure-Object -Maximum).Maximum ?? 1)
    if (-not $lastIter) { $lastIter = 1 }
    $threads = ConvertTo-SimpleThread (Get-AdoThread $coll $pr)
    try { $wis = Get-AdoWorkItem $coll $pr }
    catch { Write-Warn "could not read linked work items ($($_.Exception.Message)); continuing without them"; $wis = @() }
    $ctxLines = [int]$cfg.Git.ContextLines
    $mode = 'full'
    $note = $null
    $repo = $null
    $overrideRoot = $null

    if ($srcMode -eq 'Api') {
        Write-Say "  $project/$($repoInfo.name) (no clone - files from the Azure DevOps API)  $($srcRef -replace '^refs/heads/') -> $($tgtRef -replace '^refs/heads/')"
        $overrideRoot = Sync-AiReviewFolder $cfg $coll $pr $tgtSha
        $router = Get-PrrRouter $overrideRoot
        $allPr = Get-ApiChange -Coll $coll -Pr $pr -Iteration $lastIter -CompareTo 0 -Router $router -Context $ctxLines
        $changes = $allPr
        $diffBase = ($iterations | Where-Object { [int]$_.id -eq $lastIter } | Select-Object -First 1).commonRefCommit.commitId ?? $tgtSha
        if ($Incremental) {
            $prevIter = [int]($state.last_iteration ?? 0)
            if ($prevIter -gt 0 -and $prevIter -lt $lastIter) {
                $only = [System.Collections.Generic.HashSet[string]]::new()
                foreach ($fc in $allPr) { [void]$only.Add($fc.Path.ToLowerInvariant()) }
                $changes = Get-ApiChange -Coll $coll -Pr $pr -Iteration $lastIter -CompareTo $prevIter -Router $router -Context $ctxLines -OnlyPaths $only
                $mode = 'incremental'
                $diffBase = $state.last_source_sha
                $note = "This is an INCREMENTAL review: the diff shows only what changed between PR update $prevIter (last review) and update $lastIter. "
            }
            else { Write-Warn 'no earlier reviewed update to compare with - doing a full review' }
        }
    }
    else {
        $repo = Find-RepoClone -Cfg $cfg -Coll $coll -Pr $pr -Override $RepoPath
        $overrideRoot = $repo
        Write-Say "  $project/$($repoInfo.name) ($repo)  $($srcRef -replace '^refs/heads/') -> $($tgtRef -replace '^refs/heads/')"
        $refBase = "refs/prr/$(Get-SafeName $coll.Name)/$id"
        $fetch = Invoke-Git -Repo $repo -GitArgs @('fetch', '--quiet', '--no-tags', $cfg.Git.Remote, "+$srcRef`:$refBase/source", "+$tgtRef`:$refBase/target") -NoCheck -TimeoutSeconds 900
        if ($fetch.ExitCode -ne 0) {
            Stop-Prr "git fetch failed in $repo`: $($fetch.StdErr.Trim())`nIf it needs a login, run 'git fetch' once yourself in that folder so Git Credential Manager stores it."
        }
        if (-not (Test-GitCommit $repo $srcSha)) { $srcSha = (Invoke-Git -Repo $repo -GitArgs @('rev-parse', "$refBase/source")).StdOut.Trim() }
        if (-not (Test-GitCommit $repo $tgtSha)) { $tgtSha = (Invoke-Git -Repo $repo -GitArgs @('rev-parse', "$refBase/target")).StdOut.Trim() }
        $base = (Invoke-Git -Repo $repo -GitArgs @('merge-base', $tgtSha, $srcSha)).StdOut.Trim()
        $router = Get-PrrRouter $repo
        $diffBase = $base; $only = $null
        if ($Incremental) {
            $prev = $state.last_source_sha
            if ($prev -and $prev -ne $srcSha -and (Test-GitCommit $repo $prev)) {
                $mode = 'incremental'; $diffBase = $prev
                $only = [System.Collections.Generic.HashSet[string]]::new()
                foreach ($ns in (Get-GitNameStatus $repo $base $srcSha)) { [void]$only.Add((ConvertTo-NormPath $ns[2]).ToLowerInvariant()) }
                $note = "This is an INCREMENTAL review: the diff shows only commits pushed since the last review ($($prev.Substring(0, 8))..$($srcSha.Substring(0, 8))). "
            }
            else { Write-Warn 'no earlier reviewed commit available locally - doing a full review' }
        }
        $changes = Get-GitChange -Repo $repo -Base $diffBase -Head $srcSha -Context $ctxLines -Router $router -OnlyPaths $only
        $allPr = if ($mode -eq 'full') { $changes } else { Get-GitChange -Repo $repo -Base $base -Head $srcSha -Context $ctxLines -Router $router }
    }
    if ($note) { $note += 'Earlier feedback is in <existing_review_threads>; check whether it was addressed only if the new code touches it.' }
    if (-not @($changes).Count) { Write-Say 'No changed files.'; return }

    $rv = $cfg.Review
    $batches = New-PrrBatch -Changes $changes -MaxChars $rv.MaxBatchChars -MaxFileChars $rv.MaxFileDiffChars `
        -IncludeFull ([bool]$rv.IncludeFullFiles) -Repo $repo -Head $srcSha -MaxFull $rv.MaxFullFileChars
    if ($routeFilter) { $batches = [System.Collections.Generic.List[object]]@($batches | Where-Object { $_.Route.Name -in $routeFilter }) }

    $filesText = (@($allPr) | ForEach-Object {
            $counts = if (@($_.Annotated).Count) { ", +$($_.Adds) -$($_.Dels)" } else { '' }
            "- /$($_.Path) ($(Get-FileStatusWord $_)$counts)" + $(if ($null -eq $_.Route) { '  [ignored by router]' })
        }) -join "`n"

    if ($rv.RunPrIntent -and (-not $routeFilter -or $script:IntentRoute -in $routeFilter)) {
        $sb = [Text.StringBuilder]::new()
        foreach ($fc in $changes) {
            if ($null -eq $fc.Route -or -not @($fc.Annotated).Count) { continue }
            $blk = Get-FileBlock $fc ([Math]::Max(4000, [int]($rv.MaxFileDiffChars / 4)))
            if ($sb.Length + $blk.Length -gt $rv.MaxBatchChars) { [void]$sb.Append("... [remaining files omitted for length - see <changed_files_in_pr>]`n"); break }
            [void]$sb.Append($blk)
        }
        $batches.Add(@{ Route = @{ Name = $script:IntentRoute; Prompt = $script:IntentRoute }; Index = 1; Files = @(@{ Fc = $null; Block = $sb.ToString() }) })
    }

    $routeCounts = @($changes | Where-Object { $_.Route } | Group-Object { $_.Route.Name } | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" })
    $ignored = @($changes | Where-Object { $null -eq $_.Route }).Count
    $binary = @($changes | Where-Object { $_.Binary }).Count
    Write-Say ("  $(@($changes).Count) changed file(s): $($routeCounts -join ', ')" + $(if ($ignored) { ", ignored=$ignored" }) + $(if ($binary) { ", binary=$binary" }) +
        "  |  $(@($threads).Count) existing thread(s), $(@($wis).Count) work item(s)  |  $mode review")
    if (-not $batches.Count) { Write-Say 'Nothing to review after routing.'; return }

    $runName = "run-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$($srcSha.Substring(0, 7))"
    $prDir = Get-PrDir $cfg $coll $id
    $runDir = Join-Path $prDir $runName
    [void](New-Item -ItemType Directory -Path $runDir -Force)

    $backend = if ($Prepare) { 'prepare' } else { $cfg.Model.Backend }
    $wt = $null
    $workDir = $null
    $jobs = [System.Collections.Generic.List[object]]::new()
    $results = @{}
    try {
        if ($srcMode -eq 'Clone') {
            $useWt = $cfg.Git.UseWorktree -and -not $NoWorktree -and $backend -in 'copilot-cli', 'command'
            $checksOn = @($cfg.Checks | Where-Object { $_ -and $_.Enabled }).Count -gt 0
            if ($cfg.Git.UseWorktree -and -not $NoWorktree -and ($useWt -or $checksOn)) {
                $wt = New-PrWorktree $cfg $repo "$(Get-SafeName $coll.Name)-$id" $srcSha
            }
            if ($wt -and $useWt) {
                $workDir = $wt
                $extra = 'Your working directory is a read-only checkout of the PR''s source branch. You may open other files to confirm how changed code is used, but only report problems in the changed code.'
                $note = if ($note) { "$note`n$extra" } else { $extra }
            }
        }
        else {
            if (@($cfg.Checks | Where-Object { $_ -and $_.Enabled }).Count) { Write-Warn "Checks need a clone - skipped (Source.Mode = 'Api')" }
            $srcDir = Write-SourceContext $runDir $allPr
            if ($srcDir) {
                $workDir = $srcDir
                $extra = if ($backend -in 'copilot-cli', 'command') {
                    'Your working directory contains the full new version of every changed file in this PR (not the rest of the repository). Open them when the diff alone is not enough context.'
                }
                else { "The full new version of every changed file in this PR is under: $srcDir (not the rest of the repository). Open them when the diff alone is not enough context." }
                $note = if ($note) { "$note`n$extra" } else { $extra }
            }
        }
        $checks = Invoke-PrrCheck $cfg $wt @($batches | ForEach-Object { $_.Route.Name })
        $contract = (Get-PrrPrompt $overrideRoot '_contract').Replace('{{max_findings}}', [string]$rv.MaxFindingsPerBatch).Replace('{{min_confidence}}', [string]$rv.MinConfidence)
        $suppress = Get-PrrSuppression $overrideRoot
        $ctxText = Get-PrContextText $pr $wis
        $thText = Get-ThreadText $threads
        foreach ($b in $batches) {
            $rname = $b.Route.Name
            $label = "$rname-$($b.Index)"
            $focus = Get-PrrPrompt $overrideRoot $b.Route.Prompt
            $body = ($b.Files | ForEach-Object { $_.Block }) -join ''
            $prompt = New-PrrPrompt -Contract $contract -FocusName $rname -Focus $focus -Suppress $suppress -Context $ctxText `
                -ThreadsText $thText -ChecksText ($checks[$rname] ?? '') -FilesText $filesText -Note $note -Body $body
            $pfile = Join-Path $runDir "prompt-$label.md"
            Write-TextFile $pfile $prompt
            $jobs.Add(@{ Label = $label; Prompt = $prompt; PromptFile = $pfile; Batch = $b })
        }

        $pending = [ordered]@{
            run_name = $runName; created = (Get-NowIso); mode = $mode; source_mode = $srcMode; route_filter = $routeFilter
            backend = $backend
            pr = [ordered]@{
                collection = $coll.Name; collection_url = $coll.Url; id = $id; title = $pr.title; url = (Get-AdoPrUrl $coll $pr)
                project = $project; repo = $repoInfo.name; repo_id = $repoInfo.id; repo_path = $repo
                source_ref = $srcRef; target_ref = $tgtRef; source_sha = $srcSha; base_sha = $diffBase
                iteration = $lastIter; author = $pr.createdBy.displayName
            }
            jobs = @($jobs | ForEach-Object { [ordered]@{ label = $_.Label; route = $_.Batch.Route.Name; index = $_.Batch.Index
                        files = @($_.Batch.Files | Where-Object { $_.Fc } | ForEach-Object { ConvertTo-AdoPath $_.Fc.Path }) } })
            files = @($allPr | ForEach-Object { [ordered]@{ path = (ConvertTo-AdoPath $_.Path); file_level_only = [bool]$_.FileLevelOnly; rows = @($_.Rows) } })
            touched = @($changes | ForEach-Object { (ConvertTo-AdoPath $_.Path).ToLowerInvariant() })
            threads = @($threads)
        }
        Write-JsonFile (Join-Path $runDir 'pending.json') $pending
        $state.pending_run = $runName
        Save-PrState $cfg $coll $id $state

        if ($Prepare) {
            $task = New-CopilotTask $runDir $jobs.ToArray()
            Write-Say ''
            Write-Say "Prepared $($jobs.Count) review prompt(s). Answer each one as described in:" -Color White
            Write-Say "  $task"
            Write-Say "then run: prr collect $($coll.Name)/$id"
            Write-Say "PRR_RUN_DIR=$runDir"
            return
        }
        $par = if ($backend -in 'copilot-cli', 'command') { ", up to $($rv.Parallel) at a time" } else { '' }
        Write-Say "  running $($jobs.Count) model call(s) [$backend]$par"
        $results = Invoke-PrrModel -Cfg $cfg -Jobs $jobs.ToArray() -WorkDir $workDir -RunDir $runDir
    }
    finally {
        if ($wt -and -not $KeepWorktree) { Remove-PrWorktree $repo $wt }
    }
    Complete-PrReviewRun -Cfg $cfg -Coll $coll -Id $id -RunDir $runDir -Results $results
    if ($srcMode -eq 'Clone' -and $cfg.Source.AutoClean -and -not $KeepWorktree) { Invoke-PrAutoClean $cfg }
}

function Invoke-PrCollect {
    <#
    .SYNOPSIS
      Reads the reply files written for a prepared review (prr review -Prepare / the pr-review Copilot skill) and turns them into findings.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$PullRequest, [string]$Collection, [string]$ConfigPath)
    $cfg = Get-PrrConfig $ConfigPath
    $ref = Resolve-PrRef -Ref $PullRequest -Collection $Collection -Cfg $cfg
    $state = Get-PrState $cfg $ref.Coll $ref.Id
    if (-not $state.pending_run) { Stop-Prr "No prepared review is waiting for $($ref.Coll.Name)/$($ref.Id). Run 'prr review <PR> -Prepare' first." }
    $runDir = Join-Path (Get-PrDir $cfg $ref.Coll $ref.Id) $state.pending_run
    $pending = Read-JsonFile (Join-Path $runDir 'pending.json')
    $results = @{}
    foreach ($j in @($pending.jobs)) {
        $f = @("response-$($j.label).json", "response-$($j.label).txt") | ForEach-Object { Join-Path $runDir $_ } |
            Where-Object { (Test-Path -LiteralPath $_) -and (Get-Item -LiteralPath $_).Length -gt 0 } | Select-Object -First 1
        $results[$j.label] = if ($f) { @{ Ok = $true; Text = (Read-TextFile $f); Seconds = 0 } } else { @{ Ok = $false; Error = 'no reply file was written'; Seconds = 0 } }
    }
    Complete-PrReviewRun -Cfg $cfg -Coll $ref.Coll -Id $ref.Id -RunDir $runDir -Results $results
}

function Complete-PrReviewRun {
    <# Parses replies, merges with earlier decisions and saves findings.json / report.md. #>
    param([hashtable]$Cfg, [hashtable]$Coll, [int]$Id, [string]$RunDir, [hashtable]$Results)
    $pending = Read-JsonFile (Join-Path $RunDir 'pending.json')
    $state = Get-PrState $Cfg $Coll $Id
    $rv = $Cfg.Review
    $files = @{}
    $diffIndex = [ordered]@{}
    foreach ($f in @($pending.files)) {
        $rows = @($f.rows)
        $added = [System.Collections.Generic.HashSet[int]]::new()
        foreach ($r in $rows) { if ($r[1] -eq '+' -and $null -ne $r[0]) { [void]$added.Add([int]$r[0]) } }
        $norm = ConvertTo-NormPath $f.path
        $files[$norm.ToLowerInvariant()] = @{ Path = $norm; Rows = $rows; Added = $added; FileLevelOnly = [bool]$f.file_level_only }
        if ($rows.Count) { $diffIndex[$f.path] = $rows }
    }
    $threads = @($pending.threads)
    $findings = [System.Collections.Generic.List[object]]::new()
    $batchMeta = [System.Collections.Generic.List[object]]::new()
    foreach ($j in @($pending.jobs)) {
        $res = $Results[$j.label] ?? @{ Ok = $false; Error = 'no result'; Seconds = 0 }
        $meta = [ordered]@{ route = $j.route; index = $j.index; label = $j.label; files = @($j.files); status = 'ok'; error = $null; summary = $null; seconds = $res.Seconds }
        $respFile = Join-Path $RunDir "response-$($j.label).txt"
        if ($null -ne $res.Text -and -not (Test-Path -LiteralPath (Join-Path $RunDir "response-$($j.label).json"))) { Write-TextFile $respFile ([string]$res.Text) }
        if ($res.Ok) {
            try {
                $parsed = ConvertFrom-ModelReply $res.Text
                $found = ConvertTo-PrrFinding $parsed $j.route $files $threads
                foreach ($f in $found) { $findings.Add($f) }
                $s = [string]$parsed.summary
                $meta.summary = $s.Substring(0, [Math]::Min(600, $s.Length))
                Write-Say "  [$($j.label)] $(@($found).Count) finding(s)" -Color Green
            }
            catch { $meta.status = 'error'; $meta.error = $_.Exception.Message; Write-Say "  [$($j.label)] FAILED: $($meta.error)" -Color Red }
        }
        else {
            $meta.status = 'error'; $meta.error = $res.Error
            if ($pending.backend -notin 'copilot-cli', 'command') { Write-Say "  [$($j.label)] FAILED: $($res.Error)" -Color Red }
        }
        $batchMeta.Add($meta)
    }
    $okCount = @($batchMeta | Where-Object { $_.status -eq 'ok' }).Count

    # Partial reruns keep the other routes' results; incremental runs keep findings on files that didn't change.
    $routeFilter = @($pending.route_filter | Where-Object { $_ })
    if (($routeFilter.Count -or $pending.mode -eq 'incremental') -and $state.last_run) {
        $prevPath = Join-Path (Join-Path (Get-PrDir $Cfg $Coll $Id) $state.last_run) 'findings.json'
        if (Test-Path -LiteralPath $prevPath) {
            $prev = Read-JsonFile $prevPath
            if ($routeFilter.Count -and $state.last_source_sha -eq $pending.pr.source_sha) {
                foreach ($f in @($prev.findings)) { if ($f.route -notin $routeFilter) { $findings.Add($f) } }
                $batchMeta = [System.Collections.Generic.List[object]]@(@($prev.batches | Where-Object { $_.route -notin $routeFilter }) + $batchMeta.ToArray())
                Write-Say "  kept earlier results for the other routes from $($state.last_run)" -Color DarkGray
            }
            elseif ($pending.mode -eq 'incremental') {
                $touched = @{}
                foreach ($t in @($pending.touched)) { $touched[$t] = 1 }
                foreach ($f in @($prev.findings)) {
                    if ($f.route -eq $script:IntentRoute -or -not $f.file) { continue }
                    $stillInPr = $files.ContainsKey((ConvertTo-NormPath $f.file).ToLowerInvariant())
                    if (-not $touched.ContainsKey($f.file.ToLowerInvariant()) -and $stillInPr) { $findings.Add($f) }
                    elseif ($f.state -eq 'accepted') { Write-Warn "earlier accepted-but-unposted finding on a changed file was dropped: $($f.file):$($f.line) $($f.title)" }
                }
            }
        }
    }

    $final = Select-UniqueFinding $findings
    Hide-IntentOverlap $final
    Restore-PrDecision $Cfg $Coll $Id $state $final
    foreach ($f in $final) { if ($f.state -eq 'pending' -and $f.confidence -lt $rv.MinConfidence) { $f.state = 'filtered' } }
    $final = @($final | Sort-Object @{ e = { $_.state -eq 'filtered' } }, @{ e = { $script:SevRank[$_.severity] } }, @{ e = { $_.file ?? '' } }, @{ e = { $_.line ?? 0 } })
    $n = 0
    foreach ($f in $final) { $n++; $f.id = $n }

    $data = [ordered]@{
        rig_version = $script:Version; created = (Get-NowIso); mode = $pending.mode; source_mode = $pending.source_mode
        pr = $pending.pr; model = @{ backend = $pending.backend }; batches = @($batchMeta); diff_index = $diffIndex; findings = @($final)
    }
    Save-PrRun $RunDir $data
    if (-not $okCount) {
        Write-Say 'No usable reply, so this commit is not marked as reviewed. Prompts and replies are in:' -Color Red
        Write-Say "  $RunDir"
        if ($pending.backend -in 'prepare', 'vscode', 'manual') { Write-Say "Write the missing response files, then run: prr collect $($Coll.Name)/$Id" }
        return
    }
    $state.last_run = $pending.run_name
    $state.last_source_sha = $pending.pr.source_sha
    $state.last_iteration = $pending.pr.iteration
    $state.last_review = Get-NowIso
    $state.pending_run = $null
    Save-PrState $Cfg $Coll $Id $state
    Write-ReviewSummary $data $RunDir
}

function Restore-PrDecision([hashtable]$Cfg, [hashtable]$Coll, [int]$Id, $State, $Findings) {
    $posted = $State.posted ?? @{}
    $prev = @{}
    if ($State.last_run) {
        $p = Join-Path (Join-Path (Get-PrDir $Cfg $Coll $Id) $State.last_run) 'findings.json'
        if (Test-Path -LiteralPath $p) { foreach ($f in @((Read-JsonFile $p).findings)) { $prev[$f.fingerprint] = $f } }
    }
    foreach ($f in $Findings) {
        if ($posted.ContainsKey($f.fingerprint)) {
            $f.state = 'posted'; $f.thread_id = $posted[$f.fingerprint]
            if ('posted_in_earlier_run' -notin @($f.flags)) { $f.flags = @($f.flags) + 'posted_in_earlier_run' }
        }
        elseif ($prev.ContainsKey($f.fingerprint) -and $prev[$f.fingerprint].state -in 'rejected', 'accepted' -and $f.state -eq 'pending') {
            $old = $prev[$f.fingerprint]
            foreach ($k in 'state', 'reject_reason', 'final_comment', 'final_suggestion', 'decided_at') { $f[$k] = $old[$k] }
            $f.flags = @($f.flags) + 'decision_from_earlier_run'
        }
    }
}

function Write-ReviewSummary($Data, [string]$RunDir) {
    $fs = @($Data.findings)
    Write-Say ''
    $pend = @($fs | Where-Object { $_.state -eq 'pending' })
    Write-Say "$($pend.Count) finding(s) to triage  " -Color White -NoNewline
    foreach ($s in $script:Severities) {
        $c = @($pend | Where-Object { $_.severity -eq $s }).Count
        if ($c) { Write-Say "$s $c  " -Color $script:SevColor[$s] -NoNewline }
    }
    Write-Say ''
    $other = foreach ($k in 'filtered', 'rejected', 'accepted', 'posted') { $c = @($fs | Where-Object { $_.state -eq $k }).Count; if ($c) { "$c $k" } }
    if ($other) { Write-Say "  also: $($other -join ', ')" }
    $failed = @($Data.batches | Where-Object { $_.status -ne 'ok' })
    if ($failed.Count) { Write-Warn "$($failed.Count) batch(es) failed - rerun with -Force -Routes $((@($failed.route) | Sort-Object -Unique) -join ',')" }
    Write-Say "  report: $(Join-Path $RunDir 'report.md')"
    Write-Say "  next:   prr triage $($Data.pr.collection)/$($Data.pr.id)"
}
