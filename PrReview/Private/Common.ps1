# Shared helpers: output, errors, configuration, JSON files, native processes.

function Stop-Prr([string]$Message) {
    throw [PrrException]::new($Message)
}

function Write-Say {
    param([string]$Text = '', [ConsoleColor]$Color, [switch]$NoNewline)
    $p = @{ Object = $Text; NoNewline = $NoNewline }
    if ($PSBoundParameters.ContainsKey('Color')) { $p.ForegroundColor = $Color }
    Write-Host @p
}

function Write-Warn([string]$Message) { Write-Host "! $Message" -ForegroundColor Yellow }

$script:SevColor = @{ critical = 'Red'; major = 'Yellow'; minor = 'Cyan'; nit = 'DarkGray' }
$script:Severities = @('critical', 'major', 'minor', 'nit')
$script:SevRank = @{ critical = 0; major = 1; minor = 2; nit = 3 }
$script:IntentRoute = 'pr-intent'

# --------------------------------------------------------------------------- configuration

function Get-PrrDefaultConfig {
    @{
        Collections       = @()
        DefaultCollection = $null
        CloneRoots        = @()
        Repos             = @{}
        AutoClone         = $false
        Source            = @{ Mode = 'Api'; CacheDir = $null; CleanAfterDays = 14; AutoClean = $true }
        Git               = @{ Remote = 'origin'; UseWorktree = $true; ContextLines = 10 }
        Model             = @{
            Backend    = 'copilot-cli'
            CopilotCli = @{
                Command        = 'copilot'
                Model          = $null
                Args           = @('-s', '--no-ask-user', '--deny-tool=shell', '--deny-tool=write')
                ExtraArgs      = @()
                TimeoutSeconds = 900
            }
            VsCode     = @{ Command = 'code'; Mode = 'agent'; TimeoutMinutes = 30 }
            Command    = @{ Argv = @(); TimeoutSeconds = 900 }
            Manual     = @{ CopyToClipboard = $true }
        }
        Review            = @{
            RunPrIntent         = $true
            MinConfidence       = 0.5
            MaxFindingsPerBatch = 15
            MaxBatchChars       = 120000
            MaxFileDiffChars    = 50000
            Parallel            = 3
            IncludeFullFiles    = $false
            MaxFullFileChars    = 40000
        }
        Triage            = @{ Editor = $null }
        Post              = @{ SuggestionFormat = 'suggestion'; Footer = '' }
        Checks            = @()
        RunsDir           = 'runs'
    }
}

function Merge-Hashtable([hashtable]$Base, [hashtable]$Over) {
    $out = @{}
    foreach ($k in $Base.Keys) { $out[$k] = $Base[$k] }
    foreach ($k in $Over.Keys) {
        if ($Over[$k] -is [hashtable] -and $out[$k] -is [hashtable]) { $out[$k] = Merge-Hashtable $out[$k] $Over[$k] }
        else { $out[$k] = $Over[$k] }
    }
    $out
}

function Get-PrrConfig([string]$Path) {
    $p = if ($Path) { $Path } elseif ($env:PRR_CONFIG) { $env:PRR_CONFIG } else { Join-Path $script:RigRoot 'config.psd1' }
    if (-not (Test-Path -LiteralPath $p)) { Stop-Prr "No config found at $p. Run 'prr init' and fill it in." }
    try { $user = Import-PowerShellDataFile -LiteralPath $p }
    catch { Stop-Prr "config.psd1 could not be read: $($_.Exception.Message)" }
    $cfg = Merge-Hashtable (Get-PrrDefaultConfig) $user
    $cfg._Path = (Resolve-Path -LiteralPath $p).Path
    $rd = if ($cfg.RunsDir) { $cfg.RunsDir } else { 'runs' }
    $cfg._Runs = if ([IO.Path]::IsPathRooted($rd)) { $rd } else { Join-Path $script:RigRoot $rd }
    $colls = @()
    foreach ($c in @($cfg.Collections)) {
        if (-not $c.Url) { Stop-Prr 'Every entry in Collections needs a Url' }
        $colls += New-PrrCollection $c
    }
    $cfg.Collections = $colls
    $cfg
}

function New-PrrCollection([hashtable]$c) {
    $url = $c.Url.TrimEnd('/')
    $name = if ($c.Name) { $c.Name } else { ($url -split '/')[-1] }
    @{
        Name       = $name
        Url        = $url
        Auth       = if ($c.Auth) { $c.Auth } else { 'Auto' }
        PatEnvVar  = if ($c.PatEnvVar) { $c.PatEnvVar } else { 'AZURE_DEVOPS_PAT' }
        ApiVersion = if ($c.ApiVersion) { [string]$c.ApiVersion } else { '7.1' }
        Projects   = @($c.Projects | Where-Object { $_ })
    }
}

# --------------------------------------------------------------------------- files

function Read-JsonFile([string]$Path) {
    Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 64
}

function Write-JsonFile([string]$Path, $Data) {
    $tmp = "$Path.tmp"
    $json = ConvertTo-Json -InputObject $Data -Depth 64
    [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Write-TextFile([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}

function Read-TextFile([string]$Path) {
    [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}

function ConvertTo-NormPath([string]$P) {
    $p = ($P ?? '').Replace('\', '/').Trim()
    while ($p.StartsWith('./')) { $p = $p.Substring(2) }
    $p.TrimStart('/')
}

function ConvertTo-AdoPath([string]$P) { '/' + (ConvertTo-NormPath $P) }

function Get-SafeName([string]$Name) { ($Name -replace '[^A-Za-z0-9._-]', '_') }

function Get-NowIso { (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz') }

function ConvertTo-IdSet([string[]]$Spec) {
    $set = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($part in (($Spec -join ',') -split '[,\s]+')) {
        if (-not $part) { continue }
        if ($part -match '^(\d+)-(\d+)$') { [int]$Matches[1]..[int]$Matches[2] | ForEach-Object { [void]$set.Add($_) } }
        elseif ($part -match '^\d+$') { [void]$set.Add([int]$part) }
        else { Stop-Prr "Not a finding id: '$part'" }
    }
    , $set
}

# --------------------------------------------------------------------------- native processes

function Resolve-Exe([string]$Name) {
    if (-not $Name) { return $null }
    if (Test-Path -LiteralPath $Name -PathType Leaf) { return (Resolve-Path -LiteralPath $Name).Path }
    $cmd = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $cmd.Source } else { $null }
}

function Start-Native {
    <# Starts a process with stdout/stderr captured as bytes/text and optional UTF-8 stdin. #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [AllowNull()][string]$InputText,
        [hashtable]$Environment
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($a in $ArgumentList) { $psi.ArgumentList.Add([string]$a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    if ($Environment) { foreach ($k in $Environment.Keys) { $psi.Environment[$k] = [string]$Environment[$k] } }
    try { $proc = [System.Diagnostics.Process]::Start($psi) }
    catch { Stop-Prr "Could not start '$FilePath': $($_.Exception.Message)" }
    $ms = [IO.MemoryStream]::new()
    $outTask = $proc.StandardOutput.BaseStream.CopyToAsync($ms)
    $errTask = $proc.StandardError.ReadToEndAsync()
    if ($null -ne $InputText -and $InputText.Length) {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($InputText)
        try { $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $proc.StandardInput.BaseStream.Flush() } catch { Write-Verbose "ignored: $_" }
    }
    try { $proc.StandardInput.Close() } catch { Write-Verbose "ignored: $_" }
    [pscustomobject]@{ Process = $proc; Out = $ms; OutTask = $outTask; ErrTask = $errTask; Started = [DateTime]::UtcNow; FilePath = $FilePath }
}

function Complete-Native($Handle, [int]$TimeoutSeconds = 0) {
    $p = $Handle.Process
    $ms = if ($TimeoutSeconds -gt 0) { $TimeoutSeconds * 1000 } else { -1 }
    if (-not $p.WaitForExit($ms)) {
        try { $p.Kill($true) } catch { Write-Verbose "ignored: $_" }
        Stop-Prr "'$([IO.Path]::GetFileName($Handle.FilePath))' timed out after $TimeoutSeconds s"
    }
    $p.WaitForExit()
    [void]$Handle.OutTask.Wait(10000)
    $bytes = $Handle.Out.ToArray()
    [pscustomobject]@{
        ExitCode = $p.ExitCode
        Bytes    = $bytes
        StdOut   = [Text.Encoding]::UTF8.GetString($bytes)
        StdErr   = $Handle.ErrTask.GetAwaiter().GetResult()
        Seconds  = [int]([DateTime]::UtcNow - $Handle.Started).TotalSeconds
    }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [AllowNull()][string]$InputText,
        [int]$TimeoutSeconds = 0,
        [hashtable]$Environment
    )
    $h = Start-Native -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -InputText $InputText -Environment $Environment
    Complete-Native $h $TimeoutSeconds
}
