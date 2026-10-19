function Invoke-PrGo {
    <#
    .SYNOPSIS
      Review, then triage, then offer to post - the whole loop for one PR.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$PullRequest,
        [string]$Collection, [string]$RepoPath, [switch]$Incremental, [switch]$Force, [string[]]$Routes,
        [switch]$KeepWorktree, [switch]$NoWorktree, [string]$ConfigPath
    )
    $p = @{} + $PSBoundParameters
    Invoke-PrReview @p
    $cfg = Get-PrrConfig $ConfigPath
    $ref = Resolve-PrRef -Ref $PullRequest -Collection $Collection -Cfg $cfg
    if ((Get-PrState $cfg $ref.Coll $ref.Id).last_run) {
        Invoke-PrTriage -PullRequest $PullRequest -Collection $Collection -ConfigPath $ConfigPath
    }
}

function Get-PrReviewStat {
    <#
    .SYNOPSIS
      Kept vs rejected findings per route, category and severity, plus top rejection reasons.
    #>
    [CmdletBinding()]
    param([string]$ConfigPath)
    $cfg = Get-PrrConfig $ConfigPath
    if (-not (Test-Path -LiteralPath $cfg._Runs)) { Stop-Prr 'No runs yet.' }
    $merged = [System.Collections.Generic.List[object]]::new()
    $prCount = 0
    foreach ($prDir in (Get-ChildItem -LiteralPath $cfg._Runs -Directory -Recurse -Depth 1 | Where-Object { $_.Name -like 'pr-*' })) {
        $prCount++
        $byFp = @{}
        foreach ($run in (Get-ChildItem -LiteralPath $prDir.FullName -Directory -Filter 'run-*' | Sort-Object Name)) {
            $fj = Join-Path $run.FullName 'findings.json'
            if (-not (Test-Path -LiteralPath $fj)) { continue }
            foreach ($f in @((Read-JsonFile $fj).findings)) {
                if ($f.state -ne 'pending' -or -not $byFp.ContainsKey($f.fingerprint)) { $byFp[$f.fingerprint] = $f }
            }
        }
        foreach ($v in $byFp.Values) { $merged.Add($v) }
    }
    $decided = @($merged | Where-Object { $_.state -in 'accepted', 'posted', 'rejected' })
    if (-not $decided.Count) { Write-Say 'No triaged findings yet.'; return }
    $kept = @($decided | Where-Object { $_.state -ne 'rejected' }).Count
    Write-Say "$($decided.Count) triaged finding(s) across $prCount PR(s): $kept kept ($([int](100 * $kept / $decided.Count))%)" -Color White
    foreach ($pair in @(@('route', 'By route'), @('category', 'By category'), @('severity', 'By severity'))) {
        Write-Say "`n$($pair[1])" -Color White
        Write-Say ('  {0,-22}{1,6}{2,10}{3,9}' -f '', 'kept', 'rejected', 'kept %')
        $decided | Group-Object { $_[$pair[0]] } | Sort-Object Count -Descending | ForEach-Object {
            $a = @($_.Group | Where-Object { $_.state -ne 'rejected' }).Count
            $r = $_.Count - $a
            Write-Say ('  {0,-22}{1,6}{2,10}{3,8}%' -f $_.Name, $a, $r, [int](100 * $a / $_.Count))
        }
    }
    $rej = @($decided | Where-Object { $_.state -eq 'rejected' })
    if ($rej.Count) {
        Write-Say "`nRejection reasons" -Color White
        $rej | Group-Object { if ($_.reject_reason) { $_.reject_reason } else { '?' } } | Sort-Object Count -Descending |
            ForEach-Object { Write-Say ('  {0,4}  {1}' -f $_.Count, $_.Name) }
    }
    $edited = @($decided | Where-Object { $_.state -ne 'rejected' -and $_.final_comment }).Count
    if ($kept) { Write-Say "`n$edited of $kept kept comment(s) were edited before posting." }
}

function Test-PrReviewSetup {
    <#
    .SYNOPSIS
      Checks PowerShell, git, clone roots, the model backend and every collection. -Smoke also sends a tiny prompt to the model.
    #>
    [CmdletBinding()]
    param([switch]$Smoke, [string]$ConfigPath)
    $cfg = Get-PrrConfig $ConfigPath
    function ok([string]$m) { Write-Say '  ok   ' -Color Green -NoNewline; Write-Say $m }
    function bad([string]$m) { Write-Say '  FAIL ' -Color Red -NoNewline; Write-Say $m }
    Write-Say "prr $script:Version  config: $($cfg._Path)" -Color White
    if ($PSVersionTable.PSVersion -ge [version]'7.2') { ok "PowerShell $($PSVersionTable.PSVersion)" } else { bad "PowerShell $($PSVersionTable.PSVersion) - need 7.2+" }
    $git = Resolve-Exe 'git'
    if ($git) { ok ((Invoke-Native -FilePath $git -ArgumentList @('--version')).StdOut.Trim()) } else { bad 'git not found on PATH' }
    if ($cfg.Source.Mode -eq 'Api') { ok 'source mode Api - no clones needed (files come from the Azure DevOps API)' }
    else { ok "source mode Clone - AutoClone $($cfg.AutoClone), cache $(Get-CloneCacheDir $cfg), auto-clean after $($cfg.Source.CleanAfterDays) day(s)" }
    foreach ($r in @($cfg.CloneRoots)) { if (Test-Path -LiteralPath $r) { ok "clone root $r" } else { bad "clone root $r does not exist" } }
    $skillDir = Join-Path (Join-Path (Join-Path $HOME '.copilot') 'skills') 'pr-review'
    if (Test-Path -LiteralPath $skillDir) { ok "Copilot skills installed ($skillDir)" } else { Write-Say "  info Copilot skills not installed - 'prr install-copilot' adds /pr-review and /pr-queue" }
    foreach ($k in @($cfg.Repos.Keys)) { if (Test-Path -LiteralPath (Join-Path $cfg.Repos[$k] '.git')) { ok "repo $k -> $($cfg.Repos[$k])" } else { bad "repo $k -> $($cfg.Repos[$k]) is not a git clone" } }
    foreach ($f in 'router.psd1', 'prompts/_contract.md') { if (Test-Path -LiteralPath (Join-Path $script:RigRoot $f)) { ok $f } else { bad "$f missing" } }

    $b = $cfg.Model.Backend
    switch ($b) {
        'copilot-cli' {
            $exe = Resolve-Exe $cfg.Model.CopilotCli.Command
            if ($exe) {
                $v = Invoke-Native -FilePath $exe -ArgumentList @('--version') -TimeoutSeconds 60
                ok "model backend copilot-cli: $exe $($v.StdOut.Trim() -split "`n" | Select-Object -First 1)"
            }
            else { bad "copilot-cli: '$($cfg.Model.CopilotCli.Command)' not on PATH (npm install -g @github/copilot, or winget install GitHub.Copilot)" }
        }
        'vscode' { if (Resolve-Exe $cfg.Model.VsCode.Command) { ok "model backend vscode: $(Resolve-Exe $cfg.Model.VsCode.Command)" } else { bad "vscode: '$($cfg.Model.VsCode.Command)' not on PATH" } }
        'command' { if (@($cfg.Model.Command.Argv).Count -and (Resolve-Exe $cfg.Model.Command.Argv[0])) { ok "model backend command: $($cfg.Model.Command.Argv[0])" } else { bad 'model backend command: Argv[0] not found' } }
        'manual' { ok 'model backend manual (copy/paste)' }
        default { bad "unknown Model.Backend '$b'" }
    }
    if ($Smoke -and $b -in 'copilot-cli', 'command') {
        $tmp = Join-Path $cfg._Runs '_smoke'
        [void](New-Item -ItemType Directory -Path $tmp -Force)
        $res = Invoke-PrrModel -Cfg $cfg -Jobs @(@{ Label = 'smoke'; Prompt = 'Reply with exactly this JSON and nothing else: {"summary": "ok", "findings": []}'; PromptFile = (Join-Path $tmp 'prompt-smoke.md') }) -WorkDir $null -RunDir $tmp
        $r = $res['smoke']
        if ($r.Ok) {
            try { [void](ConvertFrom-ModelReply $r.Text); ok "model replied with valid JSON in $($r.Seconds)s" }
            catch { bad "model replied but not with the JSON asked for: $(([string]$r.Text).Trim() | Select-Object -First 1)" }
        }
        else { bad "model call failed: $($r.Error)" }
    }
    if (-not @($cfg.Collections).Count) { bad 'no Collections configured' }
    foreach ($c in $cfg.Collections) {
        try {
            $me = Get-AdoMe $c
            [void](Invoke-AdoRest -Coll $c -Path 'projects' -Query @{ '$top' = 1 })
            ok "$($c.Name) ($($c.Url)): signed in as $($me.providerDisplayName ?? $me.displayName), API $(Get-AdoApiVersion $c), auth $($c.Auth)"
        }
        catch { bad "$($c.Name) ($($c.Url)): $($_.Exception.Message)" }
    }
}

function Initialize-PrReview {
    <#
    .SYNOPSIS
      Creates config.psd1 from the example; -Repo also copies router, prompts and suppressions into <repo>\.ai-review for team sharing.
    #>
    [CmdletBinding()]
    param([string]$Repo, [string]$ConfigPath)
    $target = if ($ConfigPath) { $ConfigPath } else { Join-Path $script:RigRoot 'config.psd1' }
    if (Test-Path -LiteralPath $target) { Write-Say "$target already exists - leaving it alone." }
    else {
        Copy-Item -LiteralPath (Join-Path $script:RigRoot 'config.example.psd1') -Destination $target
        Write-Say "Created $target. Fill in Collections and CloneRoots, then run 'prr doctor'."
    }
    if ($Repo) {
        $dest = Join-Path (Resolve-Path -LiteralPath $Repo).Path '.ai-review'
        if (Test-Path -LiteralPath $dest) { Write-Say "$dest already exists - leaving it alone."; return }
        [void](New-Item -ItemType Directory -Path $dest)
        Copy-Item -LiteralPath (Join-Path $script:RigRoot 'prompts') -Destination $dest -Recurse
        Copy-Item -LiteralPath (Join-Path $script:RigRoot 'router.psd1'), (Join-Path $script:RigRoot 'suppressions.md') -Destination $dest
        Write-Say "Copied router, prompts and suppressions into $dest - commit it to share them with the team. Files there override the rig's copies for this repo."
    }
}
