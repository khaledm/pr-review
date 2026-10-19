# File -> prompt routing, prompt and suppression loading (repo .ai-review folder overrides the rig's copies).

function ConvertTo-GlobRegex([string]$Pattern) {
    $pat = ConvertTo-NormPath $Pattern
    $sb = [Text.StringBuilder]::new('^')
    $i = 0
    while ($i -lt $pat.Length) {
        if ($pat.Substring($i).StartsWith('**/')) { [void]$sb.Append('(?:.*/)?'); $i += 3 }
        elseif ($pat.Substring($i).StartsWith('**')) { [void]$sb.Append('.*'); $i += 2 }
        elseif ($pat[$i] -eq '*') { [void]$sb.Append('[^/]*'); $i++ }
        elseif ($pat[$i] -eq '?') { [void]$sb.Append('[^/]'); $i++ }
        else { [void]$sb.Append([regex]::Escape([string]$pat[$i])); $i++ }
    }
    [void]$sb.Append('$')
    [regex]::new($sb.ToString(), 'IgnoreCase')
}

function Get-RigOrRepoFile([string]$RepoPath, [string[]]$Rel) {
    if ($RepoPath) {
        $cand = Join-Path (Join-Path $RepoPath '.ai-review') ($Rel -join [IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $cand) { return $cand }
    }
    $cand = Join-Path $script:RigRoot ($Rel -join [IO.Path]::DirectorySeparatorChar)
    if (Test-Path -LiteralPath $cand) { $cand } else { $null }
}

function Get-PrrRouter([string]$RepoPath) {
    $p = Get-RigOrRepoFile $RepoPath @('router.psd1')
    if (-not $p) { Stop-Prr 'router.psd1 not found in the rig folder' }
    $data = Import-PowerShellDataFile -LiteralPath $p
    $routes = foreach ($r in @($data.Routes)) {
        @{
            Name       = $r.Name
            Prompt     = $(if ($r.Prompt) { $r.Prompt } else { $r.Name })
            Preprocess = $r.Preprocess
            _Inc       = @(@($(if ($r.Include) { $r.Include } else { '**/*' })) | ForEach-Object { ConvertTo-GlobRegex $_ })
            _Exc       = @(@($r.Exclude) | Where-Object { $_ } | ForEach-Object { ConvertTo-GlobRegex $_ })
            _Content   = $(if ($r.ContentRegex) { [regex]::new($r.ContentRegex) } else { $null })
        }
    }
    @{
        Source = $p
        Ignore = @(@($data.Ignore) | Where-Object { $_ } | ForEach-Object { ConvertTo-GlobRegex $_ })
        Routes = @($routes)
    }
}

function Get-PrrRoute($Router, [string]$Path, [hashtable]$ContentSource) {
    <# $ContentSource: @{ Bytes = <new file bytes> } or @{ Repo = <clone>; Head = <sha> } - only read when a route has ContentRegex. #>
    $p = ConvertTo-NormPath $Path
    foreach ($rx in $Router.Ignore) { if ($rx.IsMatch($p)) { return $null } }
    $content = $null
    foreach ($r in $Router.Routes) {
        $inc = $false
        foreach ($rx in $r._Inc) { if ($rx.IsMatch($p)) { $inc = $true; break } }
        if (-not $inc) { continue }
        $exc = $false
        foreach ($rx in $r._Exc) { if ($rx.IsMatch($p)) { $exc = $true; break } }
        if ($exc) { continue }
        if ($r._Content) {
            if ($null -eq $content) {
                $bytes = if ($ContentSource.ContainsKey('Bytes')) { $ContentSource.Bytes } else { Get-GitBlob $ContentSource.Repo $ContentSource.Head $p }
                $content = [string](ConvertFrom-Bytes $bytes)
                if ($content.Length -gt 200000) { $content = $content.Substring(0, 200000) }
            }
            if (-not $r._Content.IsMatch($content)) { continue }
        }
        return $r
    }
    $null
}

function Get-PrrPrompt([string]$RepoPath, [string]$Name) {
    $p = Get-RigOrRepoFile $RepoPath @('prompts', "$Name.md")
    if (-not $p) { Stop-Prr "Prompt '$Name' not found (looked for prompts/$Name.md in <repo>/.ai-review and the rig folder)" }
    (Read-TextFile $p).Trim()
}

function Get-PrrSuppression([string]$RepoPath) {
    $files = @(Join-Path $script:RigRoot 'suppressions.md')
    if ($RepoPath) { $files += Join-Path (Join-Path $RepoPath '.ai-review') 'suppressions.md' }
    $lines = foreach ($f in ($files | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $f) { (Read-TextFile $f) -split "`r?`n" | Where-Object { $_.TrimStart().StartsWith('-') } }
    }
    $lines -join "`n"
}

function Get-SuppressionTarget([string]$RepoPath) {
    if ($RepoPath) {
        $p = Join-Path (Join-Path $RepoPath '.ai-review') 'suppressions.md'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    Join-Path $script:RigRoot 'suppressions.md'
}
