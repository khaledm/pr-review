function Install-PrCopilotSkill {
    <#
    .SYNOPSIS
      Installs the pr-review and pr-queue Copilot agent skills.
    .DESCRIPTION
      Skills are SKILL.md folders that GitHub Copilot loads in VS Code (they appear as /pr-review and /pr-queue
      slash commands in Copilot Chat), in Visual Studio, and in Copilot CLI.
        -Scope User (default)  ~/.copilot/skills - available in every workspace, points at this rig's prr.ps1
        -Scope Repo -Repo <p>  <repo>/.github/skills - shared with the team through source control; expects prr on PATH
    .EXAMPLE
      prr install-copilot
    .EXAMPLE
      prr install-copilot -Scope Repo -Repo C:\src\PaymentsApi
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([ValidateSet('User', 'Repo')][string]$Scope = 'User', [string]$Repo, [switch]$Force, [switch]$Uninstall)
    $src = Join-Path (Join-Path $script:RigRoot 'copilot') 'skills'
    if ($Scope -eq 'Repo') {
        if (-not $Repo) { Stop-Prr '-Scope Repo needs -Repo <path to the repository>' }
        $root = Join-Path (Join-Path (Resolve-Path -LiteralPath $Repo).Path '.github') 'skills'
        $prr = 'prr'
    }
    else {
        $root = Join-Path (Join-Path $HOME '.copilot') 'skills'
        $prr = "pwsh -NoProfile -File `"$(Join-Path $script:RigRoot 'prr.ps1')`""
    }
    foreach ($skill in Get-ChildItem -LiteralPath $src -Directory) {
        $dest = Join-Path $root $skill.Name
        if ($Uninstall) {
            if ((Test-Path -LiteralPath $dest) -and $PSCmdlet.ShouldProcess($dest, 'remove skill')) {
                Remove-Item -LiteralPath $dest -Recurse -Force
                Write-Say "  removed $dest"
            }
            continue
        }
        if ((Test-Path -LiteralPath $dest) -and -not $Force) { Write-Say "  $dest exists - use -Force to overwrite"; continue }
        if (-not $PSCmdlet.ShouldProcess($dest, 'install skill')) { continue }
        [void](New-Item -ItemType Directory -Path $dest -Force)
        foreach ($f in Get-ChildItem -LiteralPath $skill.FullName -File) {
            $text = (Read-TextFile $f.FullName).Replace('{{PRR}}', $prr)
            Write-TextFile (Join-Path $dest $f.Name) $text
        }
        Write-Say "  installed /$($skill.Name) -> $dest" -Color Green
    }
    if (-not $Uninstall) {
        Write-Say ''
        Write-Say 'In VS Code / Visual Studio Copilot Chat (agent mode) type:  /pr-review <PR URL>   or   /pr-queue'
        Write-Say 'In Copilot CLI:  copilot  then  "use the /pr-review skill on <PR URL>"'
    }
}
