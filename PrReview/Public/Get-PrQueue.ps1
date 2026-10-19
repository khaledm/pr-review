function Get-PrQueue {
    <#
    .SYNOPSIS
      Lists active PRs where you are a reviewer, across every configured collection, with local review status.
      -Review pre-reviews the ones that need it (incrementally when only new commits arrived).
    #>
    [CmdletBinding()]
    param([string]$Collection, [switch]$Review, [switch]$IncludeDrafts, [string]$ConfigPath)
    $cfg = Get-PrrConfig $ConfigPath
    $colls = @($cfg.Collections | Where-Object { -not $Collection -or $_.Name -ieq $Collection })
    if (-not $colls.Count) { Stop-Prr 'No collections configured (or none match -Collection).' }
    $votes = @{ 10 = 'approved'; 5 = 'approved*'; 0 = '-'; -5 = 'waiting'; -10 = 'rejected' }
    $toReview = [System.Collections.Generic.List[object]]::new()
    foreach ($coll in $colls) {
        try {
            $me = Get-AdoMe $coll
            $projects = @(Get-AdoProjectName $coll)
            if ($projects.Count -gt 40 -and -not $coll.Projects.Count) { Write-Warn "$($coll.Name) has $($projects.Count) projects - list the ones you review under Projects in config.psd1 to speed this up" }
            $prs = @{}
            foreach ($p in $projects) {
                foreach ($pr in (Get-AdoReviewerPr $coll $p $me.id)) { $prs[[int]$pr.pullRequestId] = $pr }
            }
        }
        catch { Write-Warn "$($coll.Name): $($_.Exception.Message)"; continue }
        Write-Say "$($coll.Name): $($prs.Count) active PR(s) with you as reviewer" -Color White
        foreach ($pr in ($prs.Values | Sort-Object { $_.creationDate })) {
            $id = [int]$pr.pullRequestId
            $st = Get-PrState $cfg $coll $id
            $src = $pr.lastMergeSourceCommit.commitId
            $myVote = [int](@($pr.reviewers | Where-Object { $_.id -eq $me.id } | ForEach-Object { $_.vote }) + 0)[0]
            if (-not $st.last_source_sha) { $local = 'not reviewed' }
            elseif ($st.last_source_sha -ne $src) { $local = 'new commits' }
            else {
                try {
                    $fs = @((Get-LatestRun $cfg $coll $id).Data.findings)
                    $pend = @($fs | Where-Object { $_.state -eq 'pending' }).Count
                    $acc = @($fs | Where-Object { $_.state -eq 'accepted' }).Count
                    $local = if ($pend) { "$pend to triage" } elseif ($acc) { "$acc to post" } else { 'done' }
                }
                catch { $local = 'reviewed' }
            }
            $title = [string]$pr.title
            $max = if ($pr.isDraft) { 42 } else { 50 }
            if ($title.Length -gt $max) { $title = $title.Substring(0, $max) }
            if ($pr.isDraft) { $title += ' (draft)' }
            $author = [string]$pr.createdBy.displayName
            if ($author.Length -gt 16) { $author = $author.Substring(0, 16) }
            $repoName = [string]$pr.repository.name
            if ($repoName.Length -gt 18) { $repoName = $repoName.Substring(0, 18) }
            Write-Say ('  {0,-7} {1,-18} {2,-50}  {3,-16} vote {4,-9} ' -f $id, $repoName, $title, $author, ($votes[$myVote] ?? $myVote)) -NoNewline
            Write-Say $local -Color Cyan
            if ($local -in 'not reviewed', 'new commits' -and (-not $pr.isDraft -or $IncludeDrafts)) {
                $toReview.Add(@{ Ref = "$($pr.url)"; Coll = $coll; Id = $id; Incremental = ($local -eq 'new commits'); Web = (Get-AdoPrUrl $coll $pr) })
            }
        }
    }
    if ($Review -and $toReview.Count) {
        Write-Say ''
        foreach ($t in $toReview) {
            try { Invoke-PrReview -PullRequest $t.Web -Incremental:$t.Incremental -ConfigPath $ConfigPath }
            catch { Write-Warn "$($t.Coll.Name)/$($t.Id): $($_.Exception.Message)" }
        }
    }
    elseif ($toReview.Count) { Write-Say "`n  'prr queue -Review' pre-reviews the $($toReview.Count) PR(s) that need it." }
}
