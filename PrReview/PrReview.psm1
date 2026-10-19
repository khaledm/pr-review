#Requires -Version 7.2
# PrReview - local AI pull-request review rig for Azure DevOps (Services and Server collections).

class PrrException : System.Exception {
    PrrException([string]$Message) : base($Message) {}
}

$script:ModuleRoot = $PSScriptRoot
$script:RigRoot = Split-Path $PSScriptRoot -Parent
$script:Version = '2.1.0'
$script:ApiVersionCache = @{}

foreach ($folder in 'Private', 'Public') {
    foreach ($file in Get-ChildItem -Path (Join-Path $PSScriptRoot $folder) -Filter '*.ps1' | Sort-Object Name) {
        . $file.FullName
    }
}

Export-ModuleMember -Function @(
    'Invoke-PrReview', 'Invoke-PrTriage', 'Publish-PrFinding', 'Invoke-PrGo',
    'Get-PrQueue', 'Get-PrReviewStat', 'Test-PrReviewSetup', 'Initialize-PrReview',
        'Invoke-PrCollect', 'Invoke-PrClean', 'Install-PrCopilotSkill'
)
