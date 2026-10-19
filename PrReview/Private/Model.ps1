# Model backends. Every backend receives the same prompts and returns the raw reply text per batch.
#   copilot-cli : GitHub Copilot CLI, prompt piped on stdin, -s for clean output, read-only tools
#   vscode      : hands all prompts to Copilot Chat agent mode in VS Code and waits for reply files
#   command     : any CLI that reads the prompt on stdin and prints the reply
#   manual      : copy each prompt to the clipboard, paste the reply into a file

function Get-ModelArgument([hashtable]$Cfg, [string]$WorkDir) {
    $b = $Cfg.Model.Backend
    if ($b -eq 'copilot-cli') {
        $c = $Cfg.Model.CopilotCli
        $exe = Resolve-Exe $c.Command
        if (-not $exe) { Stop-Prr "'$($c.Command)' not found on PATH. Install GitHub Copilot CLI (npm install -g @github/copilot, or winget install GitHub.Copilot) or change Model.Backend." }
        $argv = @($c.Args)
        if ($c.Model) { $argv += "--model=$($c.Model)" }
        if ($WorkDir) { $argv += "--add-dir=$WorkDir" }
        $argv += @($c.ExtraArgs)
        return @{ Exe = $exe; Argv = @($argv | Where-Object { $_ }); Timeout = [int]$c.TimeoutSeconds }
    }
    if ($b -eq 'command') {
        $c = $Cfg.Model.Command
        if (-not @($c.Argv).Count) { Stop-Prr 'Model.Command.Argv is empty' }
        $exe = Resolve-Exe $c.Argv[0]
        if (-not $exe) { Stop-Prr "'$($c.Argv[0])' not found on PATH" }
        return @{ Exe = $exe; Argv = @($c.Argv | Select-Object -Skip 1); Timeout = [int]$c.TimeoutSeconds }
    }
    $null
}

function Invoke-PrrModel {
    <#
      $Jobs: array of @{ Label; Prompt; PromptFile }
      Returns hashtable Label -> @{ Ok; Text; Error; Seconds }
    #>
    param([hashtable]$Cfg, [object[]]$Jobs, [string]$WorkDir, [string]$RunDir)
    switch ($Cfg.Model.Backend) {
        { $_ -in 'copilot-cli', 'command' } { return Invoke-ProcessModel $Cfg $Jobs $WorkDir $RunDir }
        'vscode' { return Invoke-VsCodeModel $Cfg $Jobs $RunDir }
        'manual' { return Invoke-ManualModel $Cfg $Jobs $RunDir }
        default { Stop-Prr "Unknown Model.Backend '$($Cfg.Model.Backend)' (use copilot-cli, vscode, command or manual)" }
    }
}

function Invoke-ProcessModel([hashtable]$Cfg, [object[]]$Jobs, [string]$WorkDir, [string]$RunDir) {
    $m = Get-ModelArgument $Cfg $WorkDir
    $parallel = [Math]::Max(1, [int]$Cfg.Review.Parallel)
    $cwd = if ($WorkDir) { $WorkDir } else { $RunDir }
    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($j in $Jobs) { $queue.Enqueue($j) }
    $running = @{}
    $results = @{}
    while ($queue.Count -or $running.Count) {
        while ($queue.Count -and $running.Count -lt $parallel) {
            $j = $queue.Dequeue()
            $argv = @($m.Argv | ForEach-Object { $_.Replace('{prompt_file}', $j.PromptFile) })
            try {
                $h = Start-Native -FilePath $m.Exe -ArgumentList $argv -WorkingDirectory $cwd -InputText $j.Prompt -Environment @{ COPILOT_AUTO_UPDATE = 'false' }
                $running[$j.Label] = $h
            }
            catch { $results[$j.Label] = @{ Ok = $false; Error = $_.Exception.Message; Seconds = 0 } }
        }
        foreach ($label in @($running.Keys)) {
            $h = $running[$label]
            $age = ([DateTime]::UtcNow - $h.Started).TotalSeconds
            if (-not $h.Process.HasExited -and ($m.Timeout -le 0 -or $age -lt $m.Timeout)) { continue }
            $running.Remove($label)
            try {
                $r = Complete-Native $h ([Math]::Max(1, $m.Timeout - [int]$age))
                if ($r.ExitCode -ne 0) {
                    $tail = if ($r.StdErr.Trim()) { $r.StdErr.Trim() } else { $r.StdOut.Trim() }
                    if ($tail.Length -gt 600) { $tail = $tail.Substring($tail.Length - 600) }
                    $results[$label] = @{ Ok = $false; Error = "exit code $($r.ExitCode): $tail"; Seconds = $r.Seconds; Text = $r.StdOut }
                }
                else { $results[$label] = @{ Ok = $true; Text = $r.StdOut; Seconds = $r.Seconds } }
            }
            catch { $results[$label] = @{ Ok = $false; Error = $_.Exception.Message; Seconds = [int]$age } }
            Write-BatchProgress $label $results[$label]
        }
        if ($running.Count) { Start-Sleep -Milliseconds 250 }
    }
    $results
}

function Write-BatchProgress([string]$Label, $Result) {
    if ($Result.Ok) { Write-Say "  [$Label] reply received ($($Result.Seconds)s)" -Color DarkGray }
    else { Write-Say "  [$Label] reply failed: $($Result.Error)" -Color Red }
}

function Invoke-ManualModel([hashtable]$Cfg, [object[]]$Jobs, [string]$RunDir) {
    $results = @{}
    foreach ($j in $Jobs) {
        $resp = Join-Path $RunDir "response-$($j.Label).txt"
        Write-TextFile $resp ''
        $copied = $false
        if ($Cfg.Model.Manual.CopyToClipboard) { try { Set-Clipboard -Value $j.Prompt -ErrorAction Stop; $copied = $true } catch { Write-Verbose "ignored: $_" } }
        Write-Say ''
        Write-Say "[$($j.Label)] paste this prompt into Copilot Chat$(if ($copied) { ' (it is on your clipboard)' })" -Color White
        Write-Say "  Prompt: $($j.PromptFile)"
        Write-Say "  Save the reply into: $resp"
        [void](Read-Host '  Press Enter when saved')
        $results[$j.Label] = @{ Ok = $true; Text = (Read-TextFile $resp); Seconds = 0 }
    }
    $results
}

function Invoke-VsCodeModel([hashtable]$Cfg, [object[]]$Jobs, [string]$RunDir) {
    $v = $Cfg.Model.VsCode
    $code = Resolve-Exe $v.Command
    if (-not $code) { Stop-Prr "'$($v.Command)' (VS Code command line) not found on PATH" }
    $taskFile = New-CopilotTask $RunDir $Jobs
    $argv = @('chat', '--mode', $v.Mode, '--add-file', $taskFile, 'Do the review task described in COPILOT-TASK.md in this folder.')
    $r = Invoke-Native -FilePath $code -ArgumentList $argv -WorkingDirectory $RunDir -TimeoutSeconds 120
    if ($r.ExitCode -ne 0) { Stop-Prr "code chat failed: $($r.StdErr.Trim())" }
    Write-Say "  Copilot Chat ($($v.Mode) mode) is working in VS Code. Approve its file writes there if it asks." -Color White
    Write-Say "  Waiting for $(@($Jobs).Count) reply file(s) in $RunDir - press Enter to stop waiting." -Color DarkGray
    $deadline = (Get-Date).AddMinutes([double]$v.TimeoutMinutes)
    $canPeek = $true
    $lastCount = -1
    while ((Get-Date) -lt $deadline) {
        $done = @($Jobs | Where-Object { Test-ReplyFile (Join-Path $RunDir "response-$($_.Label).json") })
        if ($done.Count -ne $lastCount) { Write-Say "  $($done.Count)/$(@($Jobs).Count) replies"; $lastCount = $done.Count }
        if ($done.Count -eq @($Jobs).Count) { break }
        if ($canPeek) {
            try { if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Enter') { break } } catch { $canPeek = $false }
        }
        Start-Sleep -Seconds 2
    }
    $results = @{}
    foreach ($j in $Jobs) {
        $f = Join-Path $RunDir "response-$($j.Label).json"
        $results[$j.Label] = if (Test-Path -LiteralPath $f) { @{ Ok = $true; Text = (Read-TextFile $f); Seconds = 0 } }
        else { @{ Ok = $false; Error = 'no reply file was written'; Seconds = 0 } }
    }
    $results
}

function Test-ReplyFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try { [void](ConvertFrom-ModelReply (Read-TextFile $Path)); $true } catch { $false }
}

function New-CopilotTask([string]$RunDir, [object[]]$Jobs) {
    <# The hand-off file a Copilot agent (VS Code agent mode, Copilot CLI, the pr-review skill) works through. #>
    $rows = foreach ($j in $Jobs) { "| ``prompt-$($j.Label).md`` | ``response-$($j.Label).json`` |" }
    $hasSource = Test-Path -LiteralPath (Join-Path $RunDir 'source')
    $task = @"
# Pull request review task

This folder holds $(@($Jobs).Count) review prompt file(s). For EACH row below:

1. Read the prompt file completely and follow its instructions exactly. You are the reviewer.
2. Write your answer to the response file named in the same row, in this folder. The file must contain ONLY the JSON object the prompt asks for (no markdown fences, no extra text).

| Prompt | Write the answer to |
|---|---|
$($rows -join "`n")
$(if ($hasSource) { "`nThe ``source`` folder holds the full new version of every changed file - open files there when the diff is not enough context.`n" })
Rules: do not edit or delete any other file, do not run commands other than reading files, and do not stop until every response file exists.
When all files are written, reply with "done".
"@
    foreach ($j in $Jobs) { Remove-Item -LiteralPath (Join-Path $RunDir "response-$($j.Label).json") -ErrorAction SilentlyContinue }
    $taskFile = Join-Path $RunDir 'COPILOT-TASK.md'
    Write-TextFile $taskFile $task
    $taskFile
}
