# No-clone source: changed files and their before/after content come from the Azure DevOps REST API
# (PR iteration changes + blobs); git's diff engine runs on the two downloaded versions (git diff --no-index).

function Get-ApiChange {
    <#
      Iteration $Iteration compared with $CompareTo (0 = the merge base, i.e. the whole PR).
      Returns FileChange hashtables like Get-GitChange, plus NewText (for the source/ context folder).
    #>
    param([hashtable]$Coll, $Pr, [int]$Iteration, [int]$CompareTo, $Router, [int]$Context, $OnlyPaths)
    $changes = [System.Collections.Generic.List[object]]::new()
    foreach ($e in (Get-AdoIterationChange $Coll $Pr $Iteration -CompareTo $CompareTo)) {
        $item = $e.item
        if (-not $item -or $item.isFolder -or ($item.gitObjectType -and $item.gitObjectType -ne 'blob')) { continue }
        $ct = ([string]$e.changeType).ToLowerInvariant()
        $code = if ($ct -match 'delete') { 'D' } elseif ($ct -match 'add') { 'A' } elseif ($ct -match 'rename') { 'R' } else { 'M' }
        $newPath = [string]$item.path
        $oldPath = if ($e.originalPath) { [string]$e.originalPath } elseif ($e.sourceServerItem) { [string]$e.sourceServerItem } else { $newPath }
        $fc = New-FileChange $code $oldPath $newPath
        if ($null -ne $OnlyPaths -and -not $OnlyPaths.Contains($fc.Path.ToLowerInvariant())) { continue }
        $fc.NewText = $null
        if ($code -eq 'D') {
            $fc.Route = Get-PrrRoute $Router $fc.Path @{ Bytes = [byte[]]@() }
            $changes.Add($fc); continue
        }
        $newBytes = if ($item.objectId) { Get-AdoBlob $Coll $Pr $item.objectId } else { [byte[]]@() }
        $fc.Route = Get-PrrRoute $Router $fc.Path @{ Bytes = $newBytes }
        if ($null -eq $fc.Route) { $changes.Add($fc); continue }
        $oldBytes = if ($code -ne 'A' -and $item.originalObjectId) { Get-AdoBlob $Coll $Pr $item.originalObjectId } else { [byte[]]@() }

        if ($fc.Route.Preprocess -eq 'dtsx' -and $fc.Path -match '\.dtsx$') {
            if (Set-DtsxDiffFromBytes $oldBytes $newBytes $fc $Context) { $changes.Add($fc); continue }
        }
        $oldT = ConvertFrom-Bytes $oldBytes
        $newT = ConvertFrom-Bytes $newBytes
        if ($null -eq $oldT -or $null -eq $newT) { $fc.Binary = $true; $changes.Add($fc); continue }
        if (($newBytes.Length -ge 2 -and $newBytes[1] -eq 0) -or ($newBytes.Length -ge 2 -and $newBytes[0] -eq 0xFF -and $newBytes[1] -eq 0xFE)) {
            $fc.Note = 'UTF-16 file, diffed as text'
        }
        Set-FileDiff $fc (Get-TextDiffLine $oldT $newT $Context)
        $fc.NewText = $newT
        $changes.Add($fc)
    }
    , $changes.ToArray()
}

function Sync-AiReviewFolder([hashtable]$Cfg, [hashtable]$Coll, $Pr, [string]$Commit) {
    <#
      Downloads <repo>/.ai-review from the TARGET branch (reviewed content, so a PR can't rewrite its own review rules).
      Returns the folder that contains .ai-review, or $null when the repo has none.
    #>
    $root = Join-Path (Join-Path (Join-Path $Cfg._Runs '_ai-review') (Get-SafeName $Coll.Name)) (Get-SafeName "$($Pr.repository.project.name)_$($Pr.repository.name)")
    try {
        $items = @((Invoke-AdoRest -Coll $Coll -Project $Pr.repository.project.name -Path "git/repositories/$($Pr.repository.id)/items" -Query @{
                    scopePath = '/.ai-review'; recursionLevel = 'Full'
                    'versionDescriptor.version' = $Commit; 'versionDescriptor.versionType' = 'commit'
                }).value)
    }
    catch { $items = @() }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    $blobs = @($items | Where-Object { $_ -and -not $_.isFolder -and $_.objectId -and $_.gitObjectType -ne 'tree' })
    if (-not $blobs.Count) { return $null }
    foreach ($it in $blobs) {
        $rel = ([string]$it.path).TrimStart('/')
        $dest = Join-Path $root $rel
        [void](New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force)
        [IO.File]::WriteAllBytes($dest, (Get-AdoBlob $Coll $Pr $it.objectId))
    }
    Write-Say "  using the repo's .ai-review folder from $($Pr.targetRefName -replace '^refs/heads/') ($($blobs.Count) file(s))" -Color DarkGray
    $root
}

function Write-SourceContext([string]$RunDir, $Changes, [long]$MaxBytes = 30MB) {
    <# New version of every reviewable changed file, so Copilot can read whole files without a clone. #>
    $dir = Join-Path $RunDir 'source'
    [long]$total = 0
    $n = 0
    foreach ($fc in $Changes) {
        if ($null -eq $fc.NewText -or $fc.FileLevelOnly) { continue }
        $total += $fc.NewText.Length
        if ($total -gt $MaxBytes) { Write-Warn 'source context folder capped at 30 MB'; break }
        $dest = Join-Path $dir ($fc.Path.Replace('/', [IO.Path]::DirectorySeparatorChar))
        [void](New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force)
        [IO.File]::WriteAllText($dest, $fc.NewText, [Text.UTF8Encoding]::new($false))
        $n++
    }
    if ($n) { $dir } else { $null }
}
