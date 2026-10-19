function Invoke-PrClean {
    <#
    .SYNOPSIS
      Mops up what prr leaves on disk.
    .DESCRIPTION
      Always:   leftover temporary worktrees (runs\_wt) and their git bookkeeping.
                prr's fetched refs (refs/prr/...) in your clones for PRs not reviewed for -Days days.
                Auto-cloned repos in the prr cache (Source.CacheDir) not used for -Days days.
                Your own clones are never deleted.
      -Runs:    also deletes review history: whole PR folders not reviewed for -Days days, and older
                runs of active PRs (the latest run of each PR is kept).
      -All:     ignore -Days - remove every cached clone, prr ref and (with -Runs) all PR folders.
    .EXAMPLE
      prr clean -WhatIf
    .EXAMPLE
      prr clean -Days 7 -Runs
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([int]$Days = -1, [switch]$Runs, [switch]$All, [switch]$Quiet, [string]$ConfigPath)
    $cfg = Get-PrrConfig $ConfigPath
    if ($Days -lt 0) { $Days = [int]($cfg.Source.CleanAfterDays ?? 14) }
    $cutoff = if ($All) { [datetime]::MaxValue } else { (Get-Date).AddDays(-$Days) }
    $say = { param($m) if (-not $Quiet) { Write-Say $m } }
    [long]$freed = 0
    $removed = 0; $removedClones = 0

    # Clones prr knows about: the scan index plus the cache.
    $clones = @()
    $idxFile = Join-Path $cfg._Runs 'clone-index.json'
    if (Test-Path -LiteralPath $idxFile) { $clones += @((Read-JsonFile $idxFile).Values) }
    $cache = Get-CloneCacheDir $cfg
    $mfFile = Join-Path $cache 'manifest.json'
    $manifest = if (Test-Path -LiteralPath $mfFile) { Read-JsonFile $mfFile } else { @{} }
    $clones += @($manifest.Keys)
    $clones = @($clones | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ '.git')) } | Select-Object -Unique)

    # 1. Leftover worktrees.
    $wtRoot = Join-Path $cfg._Runs '_wt'
    if (Test-Path -LiteralPath $wtRoot) {
        foreach ($d in Get-ChildItem -LiteralPath $wtRoot -Directory) {
            if ($PSCmdlet.ShouldProcess($d.FullName, 'remove leftover worktree')) {
                $freed += Get-FolderSize $d.FullName
                Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
                $removed++
                & $say "  removed worktree $($d.Name)"
            }
        }
    }
    foreach ($c in $clones) { [void](Invoke-Git -Repo $c -GitArgs @('worktree', 'prune') -NoCheck) }

    # 2. prr refs in clones (refs/prr/<collection>/<id>/... and the older refs/prr/<id>/...).
    foreach ($c in $clones) {
        $refs = (Invoke-Git -Repo $c -GitArgs @('for-each-ref', '--format=%(refname)', 'refs/prr/') -NoCheck).StdOut -split "`n" | Where-Object { $_ }
        foreach ($r in $refs) {
            $parts = $r -split '/'
            $keep = $false
            if (-not $All -and $parts.Count -ge 5) {
                $coll = $cfg.Collections | Where-Object { (Get-SafeName $_.Name) -eq $parts[2] } | Select-Object -First 1
                if ($coll -and $parts[3] -match '^\d+$') {
                    $st = Get-PrState $cfg $coll ([int]$parts[3])
                    if ($st.last_review -and [datetime]$st.last_review -gt $cutoff) { $keep = $true }
                }
            }
            if (-not $keep -and $PSCmdlet.ShouldProcess("$c : $r", 'delete prr ref')) {
                [void](Invoke-Git -Repo $c -GitArgs @('update-ref', '-d', $r) -NoCheck)
                $removed++
            }
        }
    }

    # 3. Cached auto-clones not used recently.
    foreach ($path in @($manifest.Keys)) {
        $last = [datetime]$manifest[$path]
        if (-not $All -and $last -gt $cutoff) { continue }
        if ($PSCmdlet.ShouldProcess($path, "remove cached clone (last used $($last.ToString('yyyy-MM-dd')))")) {
            if (Test-Path -LiteralPath $path) {
                $freed += Get-FolderSize $path
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            }
            $manifest.Remove($path)
            $removed++; $removedClones++
            & $say "  removed cached clone $path"
        }
    }
    if ($removedClones -and -not $WhatIfPreference) { Write-JsonFile $mfFile $manifest }
    if ($removedClones) { [void](Get-CloneIndex $cfg -Rescan) }

    # 4. Review history (opt-in).
    if ($Runs) {
        foreach ($prDir in (Get-ChildItem -LiteralPath $cfg._Runs -Directory -Recurse -Depth 1 -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'pr-*' })) {
            $stFile = Join-Path $prDir.FullName 'state.json'
            $st = if (Test-Path -LiteralPath $stFile) { Read-JsonFile $stFile } else { @{} }
            $lastReview = if ($st.last_review) { [datetime]$st.last_review } else { $prDir.LastWriteTime }
            if ($lastReview -lt $cutoff) {
                if ($PSCmdlet.ShouldProcess($prDir.FullName, 'remove review history of a PR not reviewed recently')) {
                    $freed += Get-FolderSize $prDir.FullName
                    Remove-Item -LiteralPath $prDir.FullName -Recurse -Force
                    $removed++
                    & $say "  removed $($prDir.Parent.Name)/$($prDir.Name)"
                }
                continue
            }
            foreach ($run in (Get-ChildItem -LiteralPath $prDir.FullName -Directory -Filter 'run-*')) {
                if ($run.Name -in $st.last_run, $st.pending_run) { continue }
                if ($run.LastWriteTime -lt (Get-Date).AddDays(-$Days) -or $All) {
                    if ($PSCmdlet.ShouldProcess($run.FullName, 'remove old run')) {
                        $freed += Get-FolderSize $run.FullName
                        Remove-Item -LiteralPath $run.FullName -Recurse -Force
                        $removed++
                    }
                }
            }
        }
        foreach ($d in '_smoke') { $p = Join-Path $cfg._Runs $d; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force } }
    }
    & $say ("prr clean: $removed item(s) removed, {0:N1} MB freed." -f ($freed / 1MB))
    if (-not $WhatIfPreference -and (Test-Path -LiteralPath $cfg._Runs)) { Set-Content -LiteralPath (Join-Path $cfg._Runs '.last-clean') -Value (Get-NowIso) }
}

function Get-FolderSize([string]$Path) {
    [long]((Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum ?? 0)
}

function Invoke-PrAutoClean([hashtable]$Cfg) {
    <# Runs the safe part of 'prr clean' (no review history) at most once a day. #>
    $marker = Join-Path $Cfg._Runs '.last-clean'
    if ((Test-Path -LiteralPath $marker) -and (Get-Item -LiteralPath $marker).LastWriteTime -gt (Get-Date).AddDays(-1)) { return }
    try { Invoke-PrClean -Quiet -ConfigPath $Cfg._Path -Confirm:$false } catch { Write-Verbose "auto-clean skipped: $_" }
}
