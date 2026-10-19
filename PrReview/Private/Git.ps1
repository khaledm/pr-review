# git: fetching, diffs annotated with new-file line numbers, worktrees, finding local clones.

function Get-GitExe {
    if (-not $script:GitExe) {
        $script:GitExe = Resolve-Exe 'git'
        if (-not $script:GitExe) { Stop-Prr 'git was not found on PATH' }
    }
    $script:GitExe
}

function Invoke-Git {
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string[]]$GitArgs, [switch]$NoCheck, [int]$TimeoutSeconds = 0)
    $argv = @('-c', 'core.quotepath=off', '-c', 'core.longpaths=true', '-C', $Repo) + $GitArgs
    $r = Invoke-Native -FilePath (Get-GitExe) -ArgumentList $argv -TimeoutSeconds $TimeoutSeconds -Environment @{ GIT_TERMINAL_PROMPT = '0' }
    if (-not $NoCheck -and $r.ExitCode -ne 0) {
        $what = ($GitArgs | Select-Object -First 3) -join ' '
        Stop-Prr "git $what failed: $($r.StdErr.Trim())"
    }
    $r
}

function Test-GitCommit([string]$Repo, [string]$Sha) {
    (Invoke-Git -Repo $Repo -GitArgs @('cat-file', '-e', "$Sha^{commit}") -NoCheck).ExitCode -eq 0
}

function Get-GitBlob([string]$Repo, [string]$Sha, [string]$Path) {
    $r = Invoke-Git -Repo $Repo -GitArgs @('cat-file', 'blob', "$Sha`:$(ConvertTo-NormPath $Path)") -NoCheck
    , [byte[]]$r.Bytes
}

function ConvertFrom-Bytes([byte[]]$Bytes) {
    <# Bytes -> text. UTF-8/UTF-16 aware (SSMS often saves .sql as UTF-16). $null for real binaries. #>
    if (-not $Bytes -or $Bytes.Length -eq 0) { return '' }
    $n = $Bytes.Length
    if ($n -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { return [Text.Encoding]::Unicode.GetString($Bytes, 2, $n - 2) }
    if ($n -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) { return [Text.Encoding]::BigEndianUnicode.GetString($Bytes, 2, $n - 2) }
    if ($n -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { return [Text.Encoding]::UTF8.GetString($Bytes, 3, $n - 3) }
    $head = [Math]::Min($n, 4000)
    $zeros = 0; $oddZeros = 0
    for ($i = 0; $i -lt $head; $i++) { if ($Bytes[$i] -eq 0) { $zeros++; if ($i % 2 -eq 1) { $oddZeros++ } } }
    if ($zeros) {
        if ($oddZeros -gt $head / 4) { return [Text.Encoding]::Unicode.GetString($Bytes) }
        return $null
    }
    [Text.Encoding]::UTF8.GetString($Bytes)
}

function Get-GitNameStatus([string]$Repo, [string]$Base, [string]$Head) {
    $toks = (Invoke-Git -Repo $Repo -GitArgs @('diff', '--name-status', '-z', '-M', $Base, $Head)).StdOut.Split([char]0)
    $out = [System.Collections.Generic.List[object]]::new()
    $i = 0
    while ($i -lt $toks.Length) {
        $st = $toks[$i]
        if (-not $st) { $i++; continue }
        $code = $st.Substring(0, 1)
        if ($code -in 'R', 'C') { $out.Add(@($code, $toks[$i + 1], $toks[$i + 2])); $i += 3 }
        else { $out.Add(@($code, $toks[$i + 1], $toks[$i + 1])); $i += 2 }
    }
    , $out.ToArray()
}

function ConvertTo-AnnotatedDiff([string[]]$Lines, [bool]$Numbers = $true) {
    $out = [System.Collections.Generic.List[string]]::new()
    $rows = [System.Collections.Generic.List[object]]::new()
    $added = [System.Collections.Generic.HashSet[int]]::new()
    $new = 0
    $inHunk = $false
    foreach ($raw in $Lines) {
        $line = $raw.TrimEnd("`r")
        if ($line -match '^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@ ?(.*)$') {
            $new = [int]$Matches[3]
            $inHunk = $true
            $out.Add(('{0,6}   | @@ {1}' -f '', $Matches[5].Trim()).TrimEnd())
            continue
        }
        if (-not $inHunk -or $line.Length -eq 0 -or $line.StartsWith('\')) { continue }
        $tag = $line.Substring(0, 1)
        $text = $line.Substring(1)
        $num = if ($Numbers) { $new } else { '' }
        switch ($tag) {
            '+' { $out.Add(('{0,6} + | {1}' -f $num, $text)); $rows.Add(@($new, '+', $text)); [void]$added.Add($new); $new++ }
            '-' { $out.Add(('{0,6} - | {1}' -f '', $text)); $rows.Add(@($null, '-', $text)) }
            ' ' { $out.Add(('{0,6}   | {1}' -f $num, $text)); $rows.Add(@($new, ' ', $text)); $new++ }
        }
    }
    @{ Annotated = $out; Rows = $rows; Added = $added }
}

function Get-TextDiffLine([string]$OldText, [string]$NewText, [int]$Context) {
    <# Text diff of two strings using git's own diff engine (git diff --no-index). #>
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('prr-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        Write-TextFile (Join-Path $dir 'a') (($OldText ?? '') -replace "`r`n", "`n")
        Write-TextFile (Join-Path $dir 'b') (($NewText ?? '') -replace "`r`n", "`n")
        $r = Invoke-Git -Repo $dir -GitArgs @('diff', '--no-index', '--no-color', "-U$Context", '--', 'a', 'b') -NoCheck
        if ($r.ExitCode -gt 1) { Stop-Prr "git diff --no-index failed: $($r.StdErr.Trim())" }
        , ($r.StdOut -split "`n")
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

function New-FileChange([string]$Code, [string]$Old, [string]$New) {
    $o = ConvertTo-NormPath $Old
    $n = ConvertTo-NormPath $New
    @{
        Code = $Code; Old = $o; New = $n; Path = $(if ($Code -eq 'D') { $o } else { $n })
        Route = $null; Annotated = @(); Rows = @(); Added = [System.Collections.Generic.HashSet[int]]::new()
        Binary = $false; FileLevelOnly = $false; Truncated = $false; Note = ''; Adds = 0; Dels = 0; NewText = $null
    }
}

function Get-FileStatusWord([hashtable]$Fc) {
    switch ($Fc.Code) { 'A' { 'added' } 'M' { 'modified' } 'D' { 'deleted' } 'R' { 'renamed' } 'C' { 'copied' } 'T' { 'type changed' } default { $Fc.Code } }
}

function Get-FileBlock([hashtable]$Fc, [int]$MaxChars) {
    $bits = @(Get-FileStatusWord $Fc)
    if ($Fc.Code -in 'R', 'C' -and $Fc.Old -ne $Fc.New) { $bits += "from /$($Fc.Old)" }
    if ($Fc.FileLevelOnly) { $bits += 'file-level comments only' }
    if ($Fc.Note) { $bits += $Fc.Note }
    $body = $Fc.Annotated -join "`n"
    if ($body.Length -gt $MaxChars) {
        $body = $body.Substring(0, $MaxChars) + "`n... [diff truncated - too large to include in full]"
        $Fc.Truncated = $true
    }
    "### FILE: /$($Fc.Path)  [$($bits -join ', ')]`n$body`n"
}

function Set-FileDiff([hashtable]$Fc, [string[]]$Lines, [bool]$Numbers = $true) {
    $a = ConvertTo-AnnotatedDiff $Lines $Numbers
    $Fc.Annotated = $a.Annotated.ToArray()
    $Fc.Rows = $a.Rows.ToArray()
    $Fc.Added = $a.Added
    $Fc.Adds = $a.Added.Count
    $Fc.Dels = @($a.Rows | Where-Object { $_[1] -eq '-' }).Count
}

function Get-GitChange {
    param([string]$Repo, [string]$Base, [string]$Head, [int]$Context, $Router, $OnlyPaths)
    $changes = [System.Collections.Generic.List[object]]::new()
    foreach ($ns in (Get-GitNameStatus $Repo $Base $Head)) {
        $fc = New-FileChange $ns[0] $ns[1] $ns[2]
        if ($null -ne $OnlyPaths -and -not $OnlyPaths.Contains($fc.Path.ToLowerInvariant())) { continue }
        $fc.Route = Get-PrrRoute $Router $fc.Path @{ Repo = $Repo; Head = $Head }
        if ($null -eq $fc.Route -or $fc.Code -eq 'D') { $changes.Add($fc); continue }

        if ($fc.Route.Preprocess -eq 'dtsx' -and $fc.Path -match '\.dtsx$') {
            if (Set-DtsxDiff $Repo $Base $Head $fc $Context) { $changes.Add($fc); continue }
        }
        $paths = if ($fc.Code -in 'R', 'C' -and $fc.Old -ne $fc.New) { @($fc.Old, $fc.New) } else { @($fc.Path) }
        $out = (Invoke-Git -Repo $Repo -GitArgs (@('diff', '--no-color', '--no-ext-diff', '-M', "-U$Context", $Base, $Head, '--') + $paths)).StdOut
        $lines = $out -split "`n"
        if ($out -match 'GIT binary patch' -or $out -match '(?m)^Binary files .* differ\r?$') {
            $oldT = if ($fc.Code -ne 'A') { ConvertFrom-Bytes (Get-GitBlob $Repo $Base $fc.Old) } else { '' }
            $newT = ConvertFrom-Bytes (Get-GitBlob $Repo $Head $fc.New)
            if ($null -eq $oldT -or $null -eq $newT) { $fc.Binary = $true; $changes.Add($fc); continue }
            $lines = Get-TextDiffLine $oldT $newT $Context
            $fc.Note = 'UTF-16 file, diffed as text'
        }
        Set-FileDiff $fc $lines
        $changes.Add($fc)
    }
    , $changes.ToArray()
}

function Set-DtsxDiff([string]$Repo, [string]$Base, [string]$Head, [hashtable]$Fc, [int]$Context) {
    $oldBytes = if ($Fc.Code -ne 'A') { Get-GitBlob $Repo $Base $Fc.Old } else { $null }
    Set-DtsxDiffFromBytes $oldBytes (Get-GitBlob $Repo $Head $Fc.New) $Fc $Context
}

function Set-DtsxDiffFromBytes([byte[]]$OldBytes, [byte[]]$NewBytes, [hashtable]$Fc, [int]$Context) {
    try {
        $old = if ($OldBytes -and $OldBytes.Length) { ConvertTo-DtsxSummary $OldBytes } else { @() }
        $new = ConvertTo-DtsxSummary $NewBytes
    }
    catch { return $false }
    $lines = Get-TextDiffLine (($old -join "`n") + "`n") (($new -join "`n") + "`n") ([Math]::Max(3, [int]($Context / 2)))
    Set-FileDiff $Fc $lines $false
    $Fc.FileLevelOnly = $true
    $Fc.Note = 'SSIS package shown as a readable summary'
    if (-not $Fc.Annotated.Count) { $Fc.Annotated = @('       | (only layout / metadata changes - nothing functional changed)') }
    $true
}

# --------------------------------------------------------------------------- worktrees

function New-PrWorktree([hashtable]$Cfg, [string]$Repo, [string]$Key, [string]$Sha) {
    $wt = Join-Path (Join-Path $Cfg._Runs '_wt') $Key
    Remove-PrWorktree $Repo $wt
    [void](New-Item -ItemType Directory -Path (Split-Path $wt -Parent) -Force)
    [void](Invoke-Git -Repo $Repo -GitArgs @('worktree', 'add', '--detach', $wt, $Sha))
    $wt
}

function Remove-PrWorktree([string]$Repo, [string]$Path) {
    if (-not $Path) { return }
    if (Test-Path -LiteralPath $Path) {
        [void](Invoke-Git -Repo $Repo -GitArgs @('worktree', 'remove', '--force', $Path) -NoCheck)
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
    [void](Invoke-Git -Repo $Repo -GitArgs @('worktree', 'prune') -NoCheck)
}

# --------------------------------------------------------------------------- finding the local clone

function ConvertTo-NormRemote([string]$Url) {
    if (-not $Url) { return '' }
    $u = [uri]::UnescapeDataString($Url.Trim()).ToLowerInvariant().Replace('\', '/')
    $u = $u -replace '^(https?://)[^/@]+@', '$1'
    $u = $u -replace '\.git/?$', ''
    $u.TrimEnd('/')
}

function Get-CloneIndex([hashtable]$Cfg, [switch]$Rescan) {
    $file = Join-Path $Cfg._Runs 'clone-index.json'
    if (-not $Rescan -and (Test-Path -LiteralPath $file)) { return (Read-JsonFile $file) }
    $index = @{}
    $wtRoot = (Join-Path $Cfg._Runs '_wt').ToLowerInvariant()
    foreach ($root in (@($Cfg.CloneRoots) + (Get-CloneCacheDir $Cfg))) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        Write-Say "  scanning $root for git clones..." -Color DarkGray
        $gits = Get-ChildItem -LiteralPath $root -Filter '.git' -Recurse -Depth 3 -Force -ErrorAction SilentlyContinue
        foreach ($g in $gits) {
            $repoDir = Split-Path $g.FullName -Parent
            if ($repoDir.ToLowerInvariant().StartsWith($wtRoot)) { continue }
            $r = Invoke-Git -Repo $repoDir -GitArgs @('config', '--get-regexp', '^remote\..*\.url$') -NoCheck
            foreach ($ln in ($r.StdOut -split "`n")) {
                $parts = $ln.Trim() -split '\s+', 2
                if ($parts.Count -eq 2) { $index[(ConvertTo-NormRemote $parts[1])] = $repoDir }
            }
        }
    }
    [void](New-Item -ItemType Directory -Path $Cfg._Runs -Force)
    Write-JsonFile $file $index
    $index
}

function Find-RepoClone {
    param([hashtable]$Cfg, [hashtable]$Coll, $Pr, [string]$Override)
    if ($Override) {
        $p = (Resolve-Path -LiteralPath $Override).Path
        if (-not (Test-Path -LiteralPath (Join-Path $p '.git'))) { Stop-Prr "$p is not a git clone" }
        return $p
    }
    $repo = $Pr.repository
    $keys = @("$($Coll.Name)/$($repo.project.name)/$($repo.name)", "$($repo.project.name)/$($repo.name)", $repo.name)
    foreach ($k in $keys) {
        foreach ($mk in @($Cfg.Repos.Keys)) {
            if ($mk -ieq $k -and (Test-Path -LiteralPath (Join-Path $Cfg.Repos[$mk] '.git'))) { return $Cfg.Repos[$mk] }
        }
    }
    $wanted = @($repo.remoteUrl, $repo.sshUrl) | Where-Object { $_ } | ForEach-Object { ConvertTo-NormRemote $_ }
    $tail = ("/$($repo.project.name)/_git/$($repo.name)").ToLowerInvariant()
    foreach ($rescan in $false, $true) {
        $index = Get-CloneIndex $Cfg -Rescan:$rescan
        $found = $null
        foreach ($w in $wanted) {
            if ($index.ContainsKey($w) -and (Test-Path -LiteralPath $index[$w])) { $found = $index[$w]; break }
        }
        if (-not $found) {
            $hits = @($index.Keys | Where-Object { $_.EndsWith($tail) -and (Test-Path -LiteralPath $index[$_]) } | ForEach-Object { $index[$_] } | Select-Object -Unique)
            if ($hits.Count -eq 1) { $found = $hits[0] }
        }
        if ($found) { Update-CloneCacheUse $Cfg $found; return $found }
    }
    if ($Cfg.AutoClone) {
        $cache = Get-CloneCacheDir $Cfg
        $dest = Join-Path (Join-Path $cache (Get-SafeName $Coll.Name)) (Get-SafeName "$($repo.project.name)_$($repo.name)")
        [void](New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force)
        Write-Say "  cloning $($repo.remoteUrl) into the prr cache (blobless, no checkout; 'prr clean' removes it when unused)..."
        [void](Invoke-Git -Repo (Split-Path $dest -Parent) -GitArgs @('clone', '--quiet', '--filter=blob:none', '--no-checkout', $repo.remoteUrl, $dest) -TimeoutSeconds 1800)
        [void](Get-CloneIndex $Cfg -Rescan)
        Update-CloneCacheUse $Cfg $dest
        return $dest
    }
    Stop-Prr ("No local clone of '$($repo.project.name)/$($repo.name)' found. Clone it under one of CloneRoots, " +
        "add it to Repos in config.psd1, set AutoClone = `$true, pass -RepoPath, or use Source.Mode = 'Api' (no clone needed).")
}

function Get-CloneCacheDir([hashtable]$Cfg) {
    $d = $Cfg.Source.CacheDir
    if (-not $d) { return (Join-Path $Cfg._Runs '_repos') }
    if ([IO.Path]::IsPathRooted($d)) { $d } else { Join-Path $script:RigRoot $d }
}

function Update-CloneCacheUse([hashtable]$Cfg, [string]$Path) {
    <# Records when a prr-managed (auto-cloned) repo was last used, so 'prr clean' can drop unused ones. #>
    $cache = Get-CloneCacheDir $Cfg
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith([IO.Path]::GetFullPath($cache), [StringComparison]::OrdinalIgnoreCase)) { return }
    $mf = Join-Path $cache 'manifest.json'
    $m = if (Test-Path -LiteralPath $mf) { Read-JsonFile $mf } else { @{} }
    $m[$full] = Get-NowIso
    Write-JsonFile $mf $m
}
