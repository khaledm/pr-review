function Publish-PrFinding {
    <#
    .SYNOPSIS
      Posts accepted findings to the pull request as comment threads anchored to file and line.
    .EXAMPLE
      Publish-PrFinding Finance/1234 -DryRun
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$PullRequest,
        [string]$Collection,
        [switch]$DryRun,
        [switch]$Force,
        [string]$ConfigPath
    )
    $cfg = Get-PrrConfig $ConfigPath
    $ref = Resolve-PrRef -Ref $PullRequest -Collection $Collection -Cfg $cfg
    $coll = $ref.Coll
    $run = Get-LatestRun $cfg $coll $ref.Id
    $data = $run.Data; $state = $run.State
    $todo = @($data.findings | Where-Object { $_.state -eq 'accepted' })
    if (-not $todo.Count) { Write-Say 'No accepted findings to post.'; return }

    $info = $data.pr
    $pr = Get-AdoPr @{ Coll = $coll; Id = $ref.Id; Project = $info.project } $cfg
    $cur = $pr.lastMergeSourceCommit.commitId
    if ($cur -ne $info.source_sha -and -not $Force) {
        Stop-Prr ("The PR has new commits since this review ($($info.source_sha.Substring(0, 8)) -> $($cur.Substring(0, 8))), so line numbers may have moved. " +
            "Run 'prr review $($coll.Name)/$($ref.Id) -Incremental' (decisions carry over), or post anyway with -Force.")
    }
    $iteration = (Get-AdoIteration $coll $pr | ForEach-Object { [int]$_.id } | Measure-Object -Maximum).Maximum
    if (-not $iteration) { $iteration = [int]$info.iteration }
    $tracking = @{}
    try {
        foreach ($ch in (Get-AdoIterationChange $coll $pr $iteration)) {
            $path = $ch.item.path
            if ($path -and $ch.changeTrackingId) { $tracking[$path.ToLowerInvariant()] = $ch.changeTrackingId }
        }
    }
    catch { Write-Warn "could not read iteration changes ($($_.Exception.Message)); posting without iteration context" }

    if (-not $state.posted) { $state.posted = @{} }
    $ok = 0
    foreach ($f in $todo) {
        $rows = if ($f.file) { @($data.diff_index[$f.file]) } else { @() }
        $payload = New-ThreadPayload $cfg $f $rows $tracking $iteration
        $loc = Get-FindingLocation $f
        if ($DryRun) {
            Write-Say "F$($f.id) -> $loc" -Color White
            Write-Say (ConvertTo-Json -InputObject $payload -Depth 20)
            continue
        }
        try { $res = New-AdoThread $coll $info $payload }
        catch { Write-Warn "F$($f.id) $loc`: $($_.Exception.Message)"; continue }
        $f.state = 'posted'; $f.thread_id = $res.id
        $state.posted[$f.fingerprint] = $res.id
        Save-PrRun $run.RunDir $data
        Save-PrState $cfg $coll $ref.Id $state
        $ok++
        Write-Say "  posted F$($f.id) -> $loc  (thread #$($res.id))" -Color Green
    }
    if (-not $DryRun) { Write-Say "$ok/$($todo.Count) comment(s) posted.  $($info.url)" }
}

$script:LangByExt = @{ '.cs' = 'csharp'; '.ts' = 'typescript'; '.js' = 'javascript'; '.html' = 'html'; '.sql' = 'sql'; '.json' = 'json'
    '.xml' = 'xml'; '.config' = 'xml'; '.scss' = 'scss'; '.css' = 'css'; '.yml' = 'yaml'; '.yaml' = 'yaml'; '.ps1' = 'powershell' }

function Get-CommentBody([hashtable]$Cfg, $F) {
    $text = (Get-FindingComment $F).Trim()
    $sugg = Get-FindingSuggestion $F
    $fmt = $Cfg.Post.SuggestionFormat
    if ($sugg -and $fmt -ne 'none' -and $null -ne $F.line) {
        if ($fmt -eq 'suggestion') { $text += "`n`n``````suggestion`n$sugg`n``````" }
        else {
            $lang = $script:LangByExt[[IO.Path]::GetExtension([string]$F.file).ToLowerInvariant()]
            $text += "`n`nSuggested change:`n``````$lang`n$sugg`n``````"
        }
    }
    if ($Cfg.Post.Footer) { $text += "`n`n$($Cfg.Post.Footer)" }
    $text
}

function New-ThreadPayload([hashtable]$Cfg, $F, $Rows, [hashtable]$Tracking, [int]$Iteration) {
    $content = Get-CommentBody $Cfg $F
    $payload = [ordered]@{ comments = @([ordered]@{ parentCommentId = 0; content = $content; commentType = 1 }); status = 1 }
    if ($F.file -and 'file_not_in_pr' -notin @($F.flags)) {
        $ctx = [ordered]@{ filePath = $F.file }
        if ($null -ne $F.line) {
            $end = if ($null -ne $F.end_line) { $F.end_line } else { $F.line }
            $endText = ($Rows | Where-Object { $_[0] -eq $end } | Select-Object -First 1)
            $endLen = if ($endText) { ([string]$endText[2]).Length } else { 0 }
            $ctx.rightFileStart = [ordered]@{ line = $F.line; offset = 1 }
            $ctx.rightFileEnd = [ordered]@{ line = $end; offset = [Math]::Max(1, $endLen + 1) }
        }
        $payload.threadContext = $ctx
        $tid = $Tracking[$F.file.ToLowerInvariant()]
        if ($tid) {
            $payload.pullRequestThreadContext = [ordered]@{
                changeTrackingId = $tid
                iterationContext = [ordered]@{ firstComparingIteration = 1; secondComparingIteration = $Iteration }
            }
        }
    }
    elseif ($F.file) {
        $payload.comments[0].content = "**$(Get-FindingLocation $F)**`n`n$content"
    }
    $payload
}
