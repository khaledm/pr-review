function Invoke-PrTriage {
    <#
    .SYNOPSIS
      Step through review findings: accept, edit, reject (with a reason), skip.
    .EXAMPLE
      Invoke-PrTriage Finance/1234
    .EXAMPLE
      Invoke-PrTriage Finance/1234 -Accept 1,3,5-7 -Reject 2 -Reason 'false positive'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$PullRequest,
        [string]$Collection,
        [string[]]$Accept,
        [string[]]$Reject,
        [string]$Reason,
        [switch]$List,
        [switch]$All,
        [switch]$Revisit,
        [switch]$NoPostPrompt,
        [int]$Edit,
        [string]$Comment,
        [AllowNull()][string]$Suggestion,
        [string]$ConfigPath
    )
    $cfg = Get-PrrConfig $ConfigPath
    $ref = Resolve-PrRef -Ref $PullRequest -Collection $Collection -Cfg $cfg
    $run = Get-LatestRun $cfg $ref.Coll $ref.Id
    $data = $run.Data
    $fs = @($data.findings)

    if ($Edit) {
        $f = $fs | Where-Object { $_.id -eq $Edit } | Select-Object -First 1
        if (-not $f) { Stop-Prr "No finding F$Edit" }
        if ($f.state -eq 'posted') { Stop-Prr "F$Edit is already posted" }
        if ($PSBoundParameters.ContainsKey('Comment')) { $f.final_comment = $Comment }
        if ($PSBoundParameters.ContainsKey('Suggestion')) { $f.final_suggestion = [string]$Suggestion }
        Set-FindingDecision $f 'accepted' $null
        Write-Say "  F$Edit edited and accepted" -Color Green
        if (-not ($Accept -or $Reject)) { Save-PrRun $run.RunDir $data; Write-TriageCount $data; return }
    }
    if ($Accept -or $Reject) {
        foreach ($i in (ConvertTo-IdSet $Accept)) {
            $f = $fs | Where-Object { $_.id -eq $i } | Select-Object -First 1
            if ($f -and $f.state -ne 'posted') { Set-FindingDecision $f 'accepted' $null }
        }
        foreach ($i in (ConvertTo-IdSet $Reject)) {
            $f = $fs | Where-Object { $_.id -eq $i } | Select-Object -First 1
            if ($f -and $f.state -ne 'posted') { Set-FindingDecision $f 'rejected' $(if ($Reason) { $Reason } else { 'rejected' }) }
        }
        Save-PrRun $run.RunDir $data
        Write-TriageCount $data
        return
    }

    if ($List) {
        foreach ($f in $fs) {
            if ($f.state -eq 'filtered' -and -not $All) { continue }
            Write-Say ('F{0,-3} ' -f $f.id) -NoNewline
            Write-Say ('{0,-5}' -f $f.severity.Substring(0, [Math]::Min(4, $f.severity.Length)).ToUpperInvariant()) -Color $script:SevColor[$f.severity] -NoNewline
            Write-Say (' {0,-9} {1}  {2}' -f $f.state, (Get-FindingLocation $f), $f.title)
        }
        return
    }

    $states = @('pending') + $(if ($All) { 'filtered' }) + $(if ($Revisit) { 'accepted', 'rejected' })
    $queue = @($fs | Where-Object { $_.state -in $states })
    if (-not $queue.Count) { Write-Say 'Nothing to triage.'; Write-TriageCount $data; return }

    Write-Say "$($data.pr.collection)/$($data.pr.id): $($data.pr.title)" -Color White
    Write-Say "$($queue.Count) finding(s). Keys: [a]ccept  [e]dit+accept  [r]eject  [s]kip  [d]etail  [b]ack  [q]uit"
    $i = 0; $pad = 3
    $reasons = [ordered]@{ '1' = 'false positive'; '2' = 'not worth a comment'; '3' = 'out of scope / known'; '4' = 'wrong location'; '5' = 'duplicate' }
    while ($i -ge 0 -and $i -lt $queue.Count) {
        $f = $queue[$i]
        Show-Finding $data $f ($i + 1) $queue.Count $pad
        $k = ([string](Read-Host 'a/e/r/s/d/b/q')).Trim().ToLowerInvariant()
        $decided = $false
        if ($k -in 'a', 'y') { Set-FindingDecision $f 'accepted' $null; $decided = $true }
        elseif ($k -eq 'e') { Edit-Finding $cfg $run.RunDir $f; Set-FindingDecision $f 'accepted' $null; Write-Say '  edited and accepted' -Color Green; $decided = $true }
        elseif ($k -in 'r', 'n') {
            Write-Say ('  reason: ' + (($reasons.GetEnumerator() | ForEach-Object { "[$($_.Key)] $($_.Value)" }) -join '  ') + '  or type your own')
            $r = ([string](Read-Host '  ')).Trim()
            $why = if ($reasons.Contains($r)) { $reasons[$r] } elseif ($r) { $r } else { 'rejected' }
            Set-FindingDecision $f 'rejected' $why
            $rule = ([string](Read-Host '  add a suppression rule so this stops coming up? (type the rule, Enter to skip)')).Trim()
            if ($rule) {
                $target = Get-SuppressionTarget $data.pr.repo_path
                Add-Content -LiteralPath $target -Value "- ($($f.route)/$($f.category)) $rule" -Encoding utf8
                Write-Say "  added to $target" -Color Green
            }
            $decided = $true
        }
        elseif ($k -in 's', '') { $i++; $pad = 3 }
        elseif ($k -eq 'd') { $pad = 15 }
        elseif ($k -eq 'b') { $i = [Math]::Max(0, $i - 1); $pad = 3 }
        elseif ($k -eq 'q') { break }
        else { Write-Say '  ?  use a / e / r / s / d / b / q' }
        if ($decided) {
            Save-PrRun $run.RunDir $data
            $i++; $pad = 3
        }
    }
    Save-PrRun $run.RunDir $data
    Write-TriageCount $data
    $acc = @($fs | Where-Object { $_.state -eq 'accepted' }).Count
    if ($acc -and -not $NoPostPrompt) {
        $ans = ([string](Read-Host "Post $acc accepted comment(s) to the PR now? [y/N]")).Trim().ToLowerInvariant()
        if ($ans -eq 'y') { Publish-PrFinding -PullRequest $PullRequest -Collection $Collection -ConfigPath $ConfigPath }
    }
}

function Set-FindingDecision($F, [string]$State, $Reason) {
    $F.state = $State
    $F.reject_reason = $Reason
    $F.decided_at = Get-NowIso
}

function Write-TriageCount($Data) {
    $fs = @($Data.findings)
    $parts = foreach ($k in 'pending', 'accepted', 'rejected', 'posted', 'filtered') {
        $c = @($fs | Where-Object { $_.state -eq $k }).Count
        if ($c) { "$k $c" }
    }
    Write-Say "  $($parts -join '  ')"
    if (@($fs | Where-Object { $_.state -eq 'accepted' }).Count) { Write-Say "  next: prr post $($Data.pr.collection)/$($Data.pr.id)" }
}

function Show-Finding($Data, $F, [int]$Pos, [int]$Total, [int]$Pad) {
    $w = [Math]::Min(110, [Math]::Max(60, $(try { $Host.UI.RawUI.WindowSize.Width - 2 } catch { 100 })))
    Write-Say ''
    Write-Say ('-' * $w) -Color DarkGray
    Write-Say "[$Pos/$Total] F$($F.id)  " -NoNewline
    Write-Say $F.severity.ToUpperInvariant() -Color $script:SevColor[$F.severity] -NoNewline
    Write-Say "  $($F.category)  conf $($F.confidence)  ($($F.route))" -NoNewline
    if ($F.state -ne 'pending') { Write-Say "  [$($F.state)]" -Color Magenta } else { Write-Say '' }
    Write-Say (Get-FindingLocation $F) -Color White
    Write-Say $F.title -Color White
    foreach ($row in (Get-FindingSnippet $Data $F $Pad)) {
        Write-Say $row.Prefix -NoNewline
        $c = switch ($row.Marker) { '+' { 'Green' } '-' { 'Red' } default { 'Gray' } }
        Write-Say "$($row.Marker) $($row.Text)" -Color $c
    }
    if ($F.rationale) { Write-Wrapped "Why: $($F.rationale)" $w '     ' }
    Write-Say 'Comment to post:' -Color DarkGray
    foreach ($para in ((Get-FindingComment $F) -split "`n")) { Write-Wrapped "  $para" $w '  ' }
    $s = Get-FindingSuggestion $F
    if ($s) {
        Write-Say 'Suggested replacement:' -Color DarkGray
        foreach ($ln in ($s -split "`n")) { Write-Say "  | $ln" -Color Green }
    }
    foreach ($fl in @($F.flags)) {
        if ($fl -like 'existing_thread:*') { Write-Say "  ! existing thread #$($fl.Split(':')[1]) is on/near this line - check it is not a duplicate" -Color Yellow }
        elseif ($fl -in 'outside_diff', 'not_on_changed_line', 'file_not_in_pr') { Write-Say "  ! $($fl.Replace('_', ' '))" -Color Yellow }
    }
}

function Write-Wrapped([string]$Text, [int]$Width, [string]$Indent) {
    $lead = $Text.Length - $Text.TrimStart().Length
    $line = $Text.Substring(0, $lead)
    foreach ($word in ($Text.TrimStart() -split ' ')) {
        if ($line.Trim().Length -and ($line.Length + 1 + $word.Length) -gt $Width) { Write-Say $line; $line = $Indent + $word }
        else { $line = if ($line.Trim().Length) { "$line $word" } else { "$line$word" } }
    }
    if ($line.Length) { Write-Say $line }
}

function Get-FindingSnippet($Data, $F, [int]$Pad) {
    if (-not $F.file -or $null -eq $F.line) { return @() }
    $rows = @($Data.diff_index[$F.file])
    if (-not $rows.Count) { return @() }
    $endLine = if ($null -ne $F.end_line) { $F.end_line } else { $F.line }
    $lo = $F.line - $Pad; $hi = $endLine + $Pad
    $idx = @(for ($k = 0; $k -lt $rows.Count; $k++) { if ($null -ne $rows[$k][0] -and $rows[$k][0] -ge $lo -and $rows[$k][0] -le $hi) { $k } })
    if (-not $idx.Count) { return @() }
    foreach ($r in $rows[$idx[0]..$idx[-1]]) {
        $mark = if ($null -ne $r[0] -and $r[0] -ge $F.line -and $r[0] -le $endLine) { '>' } else { ' ' }
        [pscustomobject]@{ Prefix = ('  {0}{1,5} ' -f $mark, $(if ($null -ne $r[0]) { $r[0] } else { '' })); Marker = $r[1]; Text = $r[2] }
    }
}

$script:SuggMark = '=== SUGGESTION: replacement code for the commented lines. Delete this line and everything below to drop it ==='

function Edit-Finding([hashtable]$Cfg, [string]$RunDir, $F) {
    $path = Join-Path $RunDir "edit-F$($F.id).md"
    Write-TextFile $path ((Get-FindingComment $F) + "`n`n" + $script:SuggMark + "`n" + [string](Get-FindingSuggestion $F) + "`n")
    $editor = $Cfg.Triage.Editor ?? $env:VISUAL ?? $env:EDITOR
    $parts = if ($editor) { [Management.Automation.PSParser]::Tokenize($editor, [ref]$null) | ForEach-Object Content }
    elseif ($IsWindows) { @('notepad') } else { @('nano') }
    $exe = Resolve-Exe $parts[0]
    $edited = $null
    if ($exe) {
        Start-Process -FilePath $exe -ArgumentList (@($parts | Select-Object -Skip 1) + "`"$path`"") -Wait -NoNewWindow
        $edited = Read-TextFile $path
    }
    if ($null -eq $edited) {
        Write-Say "Type the comment. End with a line containing only '.'"
        $lines = while ($true) { $ln = Read-Host; if ($ln.Trim() -eq '.') { break }; $ln }
        $edited = $lines -join "`n"
    }
    $edited = $edited -replace "`r`n", "`n"
    $i = $edited.IndexOf($script:SuggMark)
    if ($i -ge 0) { $comment = $edited.Substring(0, $i); $sugg = $edited.Substring($i + $script:SuggMark.Length).Trim("`n") }
    else { $comment = $edited; $sugg = '' }
    $F.final_comment = $comment.Trim()
    $F.final_suggestion = if ($sugg.Trim()) { $sugg } else { '' }
}
