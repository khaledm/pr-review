@{
    RootModule        = 'PrReview.psm1'
    ModuleVersion     = '2.1.0'
    GUID              = '4b0e6c39-6d3a-4a43-9f6f-2f0d5a8e7c11'
    Author            = 'Mahmud Khaled'
    Description       = 'Local AI pull-request review rig for Azure DevOps: routes PR changes to focused prompts, runs Copilot, lets you triage findings and posts accepted ones as inline PR comments.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Invoke-PrReview', 'Invoke-PrTriage', 'Publish-PrFinding', 'Invoke-PrGo',
        'Get-PrQueue', 'Get-PrReviewStat', 'Test-PrReviewSetup', 'Initialize-PrReview',
        'Invoke-PrCollect', 'Invoke-PrClean', 'Install-PrCopilotSkill'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
