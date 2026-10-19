# Parsing model replies, normalising findings, run storage and the markdown report.

function Find-BalancedJson([string]$Text, [int]$Start) {
    <# From a '{' at $Start, return the balanced {...} substring (string/escape aware) or $null. #>
    $depth = 0; $inStr = $false; $esc = $false
    for ($i = $Start; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($inStr) {
            if ($esc) { $esc = $false }
            elseif ($ch -eq '\') { $esc = $true }
            elseif ($ch -eq '"') { $inStr = $false }
            continue
        }
        if ($ch -eq '"') { $inStr = $true }
        elseif ($ch -eq '{') { $depth++ }
        elseif ($ch -eq '}') { $depth--; if ($depth -eq 0) { return $Text.Substring($Start, $i - $Start + 1) } }
    }
    $null
}

function ConvertFrom-ModelReply([string]$Text) {
    $t = ($Text ?? '').Trim()
    $cands = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($t, '```(?:json)?\s*(\{.*?\}|\[.*?\])\s*```', 'Singleline')) { $cands.Add($m.Groups[1].Value) }
    $cands.Add($t)
    foreach ($c in $cands) {
        try {
            $obj = $c | ConvertFrom-Json -AsHashtable -Depth 64 -ErrorAction Stop
            if ($obj -is [array]) { return @{ findings = $obj } }
            if ($obj -is [hashtable] -and $obj.ContainsKey('findings')) { return $obj }
        }
        catch { Write-Verbose "ignored: $_" }
    }
    foreach ($m in [regex]::Matches($t, '\{\s*"')) {
        $s = Find-BalancedJson $t $m.Index
        if (-not $s) { continue }
        try {
            $obj = $s | ConvertFrom-Json -AsHashtable -Depth 64 -ErrorAction Stop
            if ($obj -is [hashtable] -and $obj.ContainsKey('findings')) { return $obj }
        }
        catch { Write-Verbose "ignored: $_" }
    }
    throw [PrrException]::new("model reply did not contain a JSON object with a 'findings' list")
}

$script:SevAliases = @{
    blocker = 'critical'; critical = 'critical'; severe = 'critical'
    high = 'major'; major = 'major'; error = 'major'
    medium = 'minor'; moderate = 'minor'; minor = 'minor'; low = 'minor'; warning = 'minor'
    nit = 'nit'; nitpick = 'nit'; trivial = 'nit'; info = 'nit'; suggestion = 'nit'
}

function ConvertTo-Confidence($v) {
    $x = 0.5
    if (-not [double]::TryParse([string]$v, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$x)) { return 0.5 }
    if ($x -gt 1) { $x = if ($x -gt 10) { $x / 100 } else { $x / 10 } }
    [Math]::Round([Math]::Max(0.0, [Math]::Min(1.0, [double]$x)), 2)
}

function ConvertTo-IntOrNull($v) {
    $n = 0
    if ($null -ne $v -and [int]::TryParse([string]$v, [ref]$n)) { $n } else { $null }
}

function Get-Fingerprint([string]$File, [string]$Category, [string]$Title) {
    $words = ([regex]::Matches(($Title ?? '').ToLowerInvariant(), '[a-z0-9]+') | ForEach-Object Value) -join ' '
    $bytes = [Text.Encoding]::UTF8.GetBytes("$(($File ?? '').ToLowerInvariant())|$Category|$words")
    ([Security.Cryptography.SHA1]::HashData($bytes) | ForEach-Object { $_.ToString('x2') }) -join '' | ForEach-Object { $_.Substring(0, 12) }
}

function Resolve-FindingFile([string]$Name, [hashtable]$Files) {
    if (-not $Name) { return $null }
    $n = (ConvertTo-NormPath $Name).ToLowerInvariant()
    if ($Files.ContainsKey($n)) { return $Files[$n] }
    $hits = @($Files.Keys | Where-Object { $_.EndsWith("/$n") -or $n.EndsWith("/$_") })
    if ($hits.Count -eq 1) { $Files[$hits[0]] } else { $null }
}

function ConvertTo-PrrFinding($Raw, [string]$RouteName, [hashtable]$Files, $Threads) {
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($f in @($Raw.findings)) {
        if ($f -isnot [hashtable]) { continue }
        $fname = $f.file ?? $f.path ?? $f.filePath
        $fc = Resolve-FindingFile $fname $Files
        $flags = [System.Collections.Generic.List[string]]::new()
        $file = if ($fc) { ConvertTo-AdoPath $fc.Path } elseif ($fname) { ConvertTo-AdoPath $fname } else { $null }
        if ($fname -and -not $fc) { $flags.Add('file_not_in_pr') }
        $line = ConvertTo-IntOrNull ($f.line ?? $f.start_line ?? $f.startLine)
        $end = ConvertTo-IntOrNull ($f.end_line ?? $f.endLine)
        if ($null -eq $end) { $end = $line }
        if ($fc -and $fc.FileLevelOnly) { $line = $null; $end = $null }
        if ($null -ne $line -and $null -ne $end -and $end -lt $line) { $end = $line }
        if ($fc -and $null -ne $line -and -not $fc.Added.Contains([int]$line)) {
            $visible = @($fc.Rows | Where-Object { $null -ne $_[0] } | ForEach-Object { [int]$_[0] })
            $flags.Add($(if ($visible -contains $line) { 'not_on_changed_line' } else { 'outside_diff' }))
        }
        $sevKey = ([string]$f.severity).ToLowerInvariant().Trim()
        $sev = if ($script:SevAliases.ContainsKey($sevKey)) { $script:SevAliases[$sevKey] } else { 'minor' }
        $cat = if ($f.category) { ([string]$f.category).ToLowerInvariant().Trim() } else { 'maintainability' }
        $comment = ([string]($f.comment ?? $f.message ?? $f.rationale)).Trim()
        $title = ([string]($f.title ?? $f.summary)).Trim()
        if (-not $title) { $title = $comment.Substring(0, [Math]::Min(80, $comment.Length)) }
        $sugg = if ($f.suggestion -is [string] -and $f.suggestion.Trim()) { $f.suggestion.TrimEnd("`n", "`r") } else { $null }
        $item = [ordered]@{
            id = 0; fingerprint = (Get-Fingerprint $file $cat $title); route = $RouteName
            file = $file; line = $line; end_line = $end; severity = $sev; category = $cat
            confidence = (ConvertTo-Confidence $f.confidence); title = $title
            rationale = ([string]$f.rationale).Trim(); comment = $comment; suggestion = $sugg
            flags = $flags.ToArray(); state = 'pending'; final_comment = $null; final_suggestion = $null
            reject_reason = $null; thread_id = $null; decided_at = $null
        }
        $dup = Find-ExistingThread $item $Threads
        if ($dup) { $item.flags = @($item.flags) + "existing_thread:$dup" }
        $result.Add($item)
    }
    , $result.ToArray()
}

function Find-ExistingThread($Item, $Threads) {
    if (-not $Item.file) { return $null }
    foreach ($t in $Threads) {
        if (-not $t.file -or $t.file -ine $Item.file) { continue }
        if ($null -eq $Item.line -and $null -eq $t.line) { return $t.id }
        if ($null -ne $Item.line -and $null -ne $t.line -and [Math]::Abs([int]$t.line - [int]$Item.line) -le 3) { return $t.id }
    }
    $null
}

function ConvertTo-SimpleThread($RawThreads) {
    $out = foreach ($t in @($RawThreads)) {
        if (-not $t -or $t.isDeleted) { continue }
        $comments = @($t.comments | Where-Object { $_ -and -not $_.isDeleted -and ([string]($_.commentType ?? 'text')).ToLowerInvariant() -in 'text', '1' })
        if (-not $comments.Count) { continue }
        $ctx = $t.threadContext ?? @{}
        $start = $ctx.rightFileStart ?? $ctx.leftFileStart ?? @{}
        @{
            id = $t.id; status = [string]$t.status; file = $ctx.filePath; line = $start.line
            author = ($comments[0].author.displayName ?? '?')
            text = ([regex]::Replace([string]$comments[0].content, '\s+', ' ')).Substring(0, [Math]::Min(300, ([regex]::Replace([string]$comments[0].content, '\s+', ' ')).Length))
            replies = $comments.Count - 1
        }
    }
    , @($out)
}

function Select-UniqueFinding($Findings) {
    $seenFp = @{}; $seenLoc = @{}
    $sorted = @($Findings) | Sort-Object @{ e = { $_.route -eq $script:IntentRoute } }, @{ e = { $script:SevRank[$_.severity] } }, @{ e = { - $_.confidence } }
    $out = foreach ($f in $sorted) {
        $loc = "$($f.file)|$($f.line)|$($f.category)"
        if ($seenFp.ContainsKey($f.fingerprint) -or ($null -ne $f.line -and $seenLoc.ContainsKey($loc))) { continue }
        $seenFp[$f.fingerprint] = 1; $seenLoc[$loc] = 1
        $f
    }
    , @($out)
}

function Hide-IntentOverlap($Findings) {
    <# The PR-intent reviewer sometimes restates a code reviewer's finding; keep the code reviewer's version. #>
    $code = @($Findings | Where-Object { $_.route -ne $script:IntentRoute -and $_.file })
    foreach ($f in $Findings) {
        if ($f.route -ne $script:IntentRoute -or -not $f.file -or $f.state -ne 'pending') { continue }
        foreach ($c in $code) {
            if ($c.file -ine $f.file) { continue }
            $overlap = $null -eq $f.line -or $null -eq $c.line -or
            ($f.line -le ($c.end_line ?? $c.line) -and $c.line -le ($f.end_line ?? $f.line))
            if ($overlap) { $f.state = 'filtered'; $f.flags = @($f.flags) + "overlaps_$($c.route)_finding"; break }
        }
    }
}

# --------------------------------------------------------------------------- storage

function Get-PrDir([hashtable]$Cfg, [hashtable]$Coll, [int]$Id) {
    Join-Path (Join-Path $Cfg._Runs (Get-SafeName $Coll.Name)) "pr-$Id"
}

function Get-PrState([hashtable]$Cfg, [hashtable]$Coll, [int]$Id) {
    $p = Join-Path (Get-PrDir $Cfg $Coll $Id) 'state.json'
    if (Test-Path -LiteralPath $p) { return (Read-JsonFile $p) }
    @{ pr = $Id; collection = $Coll.Name; last_run = $null; last_source_sha = $null; posted = @{} }
}

function Save-PrState([hashtable]$Cfg, [hashtable]$Coll, [int]$Id, $State) {
    $d = Get-PrDir $Cfg $Coll $Id
    [void](New-Item -ItemType Directory -Path $d -Force)
    Write-JsonFile (Join-Path $d 'state.json') $State
}

function Get-LatestRun([hashtable]$Cfg, [hashtable]$Coll, [int]$Id) {
    $st = Get-PrState $Cfg $Coll $Id
    if (-not $st.last_run) { Stop-Prr "No review found for $($Coll.Name)/$Id. Run 'prr review' first." }
    $run = Join-Path (Get-PrDir $Cfg $Coll $Id) $st.last_run
    @{ RunDir = $run; Data = (Read-JsonFile (Join-Path $run 'findings.json')); State = $st }
}

function Save-PrRun([string]$RunDir, $Data) {
    Write-JsonFile (Join-Path $RunDir 'findings.json') $Data
    Write-TextFile (Join-Path $RunDir 'report.md') (ConvertTo-PrReport $Data)
}

function Get-FindingLocation($F) {
    $loc = if ($F.file) { $F.file } else { 'PR-level' }
    if ($null -ne $F.line) {
        $loc += ":$($F.line)"
        if ($null -ne $F.end_line -and $F.end_line -ne $F.line) { $loc += "-$($F.end_line)" }
    }
    $loc
}

function Get-FindingComment($F) { if ($F.final_comment) { $F.final_comment } else { $F.comment } }
function Get-FindingSuggestion($F) { if ($null -ne $F.final_suggestion) { $F.final_suggestion } else { $F.suggestion } }

function ConvertTo-PrReport($Data) {
    $pr = $Data.pr
    $L = [System.Collections.Generic.List[string]]::new()
    $L.Add("# PR $($pr.collection)/$($pr.id): $($pr.title)"); $L.Add('')
    $L.Add("$($pr.url)  ")
    $L.Add("$($pr.source_ref) -> $($pr.target_ref)  |  source $($pr.source_sha.Substring(0, 8))  |  $($Data.mode) review  |  $($Data.created)"); $L.Add('')
    foreach ($b in @($Data.batches)) {
        $status = if ($b.status -eq 'ok') { 'ok' } else { "FAILED: $($b.error)" }
        $L.Add("- **$($b.route)** batch $($b.index): $(@($b.files).Count) file(s), $($b.seconds)s, $status")
        if ($b.summary) { $L.Add("  - $($b.summary)") }
    }
    $L.Add('')
    $visible = @($Data.findings | Where-Object { $_.state -ne 'filtered' })
    foreach ($f in $visible) {
        $L.Add("## F$($f.id) [$($f.severity.ToUpperInvariant())] $($f.title)")
        $flags = if (@($f.flags).Count) { " | flags: $(@($f.flags) -join ', ')" } else { '' }
        $L.Add("``$(Get-FindingLocation $f)`` | $($f.category) | confidence $($f.confidence) | $($f.route) | **$($f.state)**$flags"); $L.Add('')
        if ($f.rationale) { $L.Add("_Why:_ $($f.rationale)"); $L.Add('') }
        $L.Add('> ' + ((Get-FindingComment $f) -replace "`n", "`n> "))
        $s = Get-FindingSuggestion $f
        if ($s) { $L.Add(''); $L.Add('```'); $L.Add($s); $L.Add('```') }
        $L.Add('')
    }
    $hidden = @($Data.findings).Count - $visible.Count
    if ($hidden) { $L.Add("_$hidden low-confidence or overlapping finding(s) hidden (state 'filtered' in findings.json)._") }
    ($L -join "`n") + "`n"
}
