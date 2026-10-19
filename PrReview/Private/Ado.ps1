# Azure DevOps REST: collections, PR references, auth, API-version negotiation.

function Resolve-PrRef {
    <#
      Accepts:  a PR URL (any collection / organisation)
                <Collection>/<id>  e.g. Finance/1234
                <id>               uses -Collection, DefaultCollection, or the only collection configured
      Returns:  @{ Coll; Id; Project; Repo }
    #>
    param([Parameter(Mandatory)][string]$Ref, [string]$Collection, [Parameter(Mandatory)][hashtable]$Cfg)
    $ref = $Ref.Trim()
    if ($ref -match '^(https?://.+?)/_git/([^/?#]+)/pullrequest/(\d+)') {
        $left = $Matches[1]; $repo = [uri]::UnescapeDataString($Matches[2]); $id = [int]$Matches[3]
        $i = $left.LastIndexOf('/')
        $collUrl = $left.Substring(0, $i).TrimEnd('/')
        $project = [uri]::UnescapeDataString($left.Substring($i + 1))
        $coll = $Cfg.Collections | Where-Object { $_.Url -ieq $collUrl } | Select-Object -First 1
        if (-not $coll) {
            Write-Warn "Collection $collUrl is not in config.psd1 - using default settings for it (Auth = Auto)."
            $coll = New-PrrCollection @{ Url = $collUrl }
            $Cfg.Collections = @($Cfg.Collections) + $coll
        }
        return @{ Coll = $coll; Id = $id; Project = $project; Repo = $repo }
    }
    $name = $Collection
    $idText = $ref
    if ($ref -match '^(.+)[/\\](\d+)$') { $name = $Matches[1]; $idText = $Matches[2] }
    if ($idText -notmatch '^\d+$') { Stop-Prr "'$Ref' is not a PR id, <Collection>/<id> or a PR URL" }
    $coll = $null
    if ($name) {
        $coll = $Cfg.Collections | Where-Object { $_.Name -ieq $name -or $_.Url -ieq $name.TrimEnd('/') } | Select-Object -First 1
        if (-not $coll) { Stop-Prr "No collection named '$name' in config.psd1 (have: $(($Cfg.Collections.Name) -join ', '))" }
    }
    elseif ($Cfg.DefaultCollection) {
        $coll = $Cfg.Collections | Where-Object { $_.Name -ieq $Cfg.DefaultCollection } | Select-Object -First 1
        if (-not $coll) { Stop-Prr "DefaultCollection '$($Cfg.DefaultCollection)' is not in Collections" }
    }
    elseif (@($Cfg.Collections).Count -eq 1) { $coll = $Cfg.Collections[0] }
    else {
        Stop-Prr "PR ids are only unique within a collection. Use <Collection>/$idText, -Collection, or paste the PR URL."
    }
    @{ Coll = $coll; Id = [int]$idText; Project = $null; Repo = $null }
}

function Get-AdoAuth([hashtable]$Coll) {
    $mode = $Coll.Auth
    $pat = [Environment]::GetEnvironmentVariable($Coll.PatEnvVar)
    if ($mode -eq 'Auto') { $mode = if ($pat) { 'PAT' } else { 'DefaultCredentials' } }
    switch ($mode) {
        'PAT' {
            if (-not $pat) { Stop-Prr "Collection '$($Coll.Name)' uses Auth = PAT but `$env:$($Coll.PatEnvVar) is empty" }
            return @{ Headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat")) } }
        }
        'DefaultCredentials' { return @{ UseDefaultCredentials = $true } }
        'AzureCli' {
            if (-not $script:AzToken -or $script:AzTokenExpires -lt (Get-Date).AddMinutes(5)) {
                $az = Resolve-Exe 'az'
                if (-not $az) { Stop-Prr "Auth = AzureCli needs the Azure CLI ('az') on PATH" }
                $r = Invoke-Native -FilePath $az -ArgumentList @('account', 'get-access-token', '--resource', '499b84ac-1321-427f-aa17-267ca6975798', '-o', 'json') -TimeoutSeconds 60
                if ($r.ExitCode -ne 0) { Stop-Prr "az account get-access-token failed (run 'az login'): $($r.StdErr.Trim())" }
                $t = $r.StdOut | ConvertFrom-Json
                $script:AzToken = $t.accessToken
                $script:AzTokenExpires = [datetime]$t.expiresOn
            }
            return @{ Headers = @{ Authorization = "Bearer $script:AzToken" } }
        }
        default { Stop-Prr "Unknown Auth '$mode' for collection '$($Coll.Name)' (use Auto, PAT, DefaultCredentials or AzureCli)" }
    }
}

function Get-AdoApiVersion([hashtable]$Coll) {
    if ($script:ApiVersionCache.ContainsKey($Coll.Url)) { $script:ApiVersionCache[$Coll.Url] } else { $Coll.ApiVersion }
}

function Invoke-AdoRest {
    param(
        [Parameter(Mandatory)][hashtable]$Coll,
        [string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Path,
        [string]$Project,
        [hashtable]$Query = @{},
        $Body,
        [switch]$NoApiVersion,
        [switch]$Raw
    )
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $q = [ordered]@{}
        if (-not $NoApiVersion) { $q['api-version'] = Get-AdoApiVersion $Coll }
        foreach ($k in $Query.Keys) { if ($null -ne $Query[$k]) { $q[$k] = $Query[$k] } }
        $qs = ($q.GetEnumerator() | ForEach-Object { [uri]::EscapeDataString($_.Key) + '=' + [uri]::EscapeDataString([string]$_.Value) }) -join '&'
        $base = $Coll.Url + $(if ($Project) { '/' + [uri]::EscapeDataString($Project) })
        $url = "$base/_apis/$Path" + $(if ($qs) { "?$qs" })
        $auth = Get-AdoAuth $Coll
        $headers = @{ Accept = 'application/json'; 'User-Agent' = "prr/$script:Version" }
        if ($auth.Headers) { foreach ($k in $auth.Headers.Keys) { $headers[$k] = $auth.Headers[$k] } }
        $p = @{ Uri = $url; Method = $Method; Headers = $headers; TimeoutSec = 120; SkipHttpErrorCheck = $true; ErrorAction = 'Stop' }
        if ($auth.UseDefaultCredentials) { $p.UseDefaultCredentials = $true }
        if ($url.StartsWith('http://', 'OrdinalIgnoreCase')) { $p.AllowUnencryptedAuthentication = $true }  # internal http-only servers
        if ($null -ne $Body) {
            $p.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 30 -Compress))
            $p.ContentType = 'application/json; charset=utf-8'
        }
        try { $resp = Invoke-WebRequest @p }
        catch { Stop-Prr "Cannot reach $($url.Split('?')[0]): $($_.Exception.Message)" }
        $content = [string]$resp.Content
        $ctype = [string]($resp.Headers['Content-Type'] | Select-Object -First 1)
        $code = [int]$resp.StatusCode
        if ($code -ge 400) {
            $msg = $content
            try { $msg = ($content | ConvertFrom-Json).message } catch { Write-Verbose "ignored: $_" }
            if ($msg -match 'latest REST API version for this server is (\d+(?:\.\d+)?)' -and $attempt -eq 0) {
                $script:ApiVersionCache[$Coll.Url] = $Matches[1]
                continue
            }
            if ($code -eq 401) { $msg = "Unauthorized. Check the collection's Auth setting / PAT. $msg" }
            $m = [string]$msg
            if ($m.Length -gt 400) { $m = $m.Substring(0, 400) }
            Stop-Prr "$Method $($url.Split('?')[0]) -> HTTP $code`: $m"
        }
        if ($Raw -and $code -lt 300 -and $ctype -notmatch 'html') { return , [byte[]]$resp.RawContentStream.ToArray() }
        if ($ctype -match 'html') {
            Stop-Prr "Azure DevOps returned a sign-in page instead of JSON for $($Coll.Url). The PAT is invalid/expired, or the collection URL is wrong."
        }
        if (-not $content.Trim()) { return @{} }
        return ($content | ConvertFrom-Json -AsHashtable -Depth 64)
    }
}

function Get-AdoPr([hashtable]$Ref, [hashtable]$Cfg) {
    $coll = $Ref.Coll
    if ($Ref.Project) { return Invoke-AdoRest -Coll $coll -Path "git/pullrequests/$($Ref.Id)" -Project $Ref.Project }
    try { return Invoke-AdoRest -Coll $coll -Path "git/pullrequests/$($Ref.Id)" }
    catch {
        foreach ($proj in $coll.Projects) {
            try { return Invoke-AdoRest -Coll $coll -Path "git/pullrequests/$($Ref.Id)" -Project $proj } catch { Write-Verbose "ignored: $_" }
        }
        throw
    }
}

function Get-AdoPrUrl([hashtable]$Coll, $Pr) {
    "$($Coll.Url)/$([uri]::EscapeDataString($Pr.repository.project.name))/_git/$([uri]::EscapeDataString($Pr.repository.name))/pullrequest/$($Pr.pullRequestId)"
}

function Get-AdoThread([hashtable]$Coll, $Pr) {
    @((Invoke-AdoRest -Coll $Coll -Project $Pr.repository.project.name -Path "git/repositories/$($Pr.repository.id)/pullRequests/$($Pr.pullRequestId)/threads").value)
}

function Get-AdoIteration([hashtable]$Coll, $Pr) {
    @((Invoke-AdoRest -Coll $Coll -Project $Pr.repository.project.name -Path "git/repositories/$($Pr.repository.id)/pullRequests/$($Pr.pullRequestId)/iterations").value)
}

function Get-AdoIterationChange([hashtable]$Coll, $Pr, [int]$Iteration, [int]$CompareTo = 0) {
    $all = [System.Collections.Generic.List[object]]::new()
    $skip = 0
    while ($true) {
        $q = @{ '$top' = 1000; '$skip' = $skip }
        if ($CompareTo -gt 0) { $q['$compareTo'] = $CompareTo }
        $res = Invoke-AdoRest -Coll $Coll -Project $Pr.repository.project.name -Query $q `
            -Path "git/repositories/$($Pr.repository.id)/pullRequests/$($Pr.pullRequestId)/iterations/$Iteration/changes"
        foreach ($e in @($res.changeEntries)) { if ($e) { $all.Add($e) } }
        $next = [int]($res.nextSkip ?? 0)
        if (-not $next -or $next -le $skip) { break }
        $skip = $next
    }
    , $all.ToArray()
}

function Get-AdoWorkItem([hashtable]$Coll, $Pr) {
    $proj = $Pr.repository.project.name
    $refs = @((Invoke-AdoRest -Coll $Coll -Project $proj -Path "git/repositories/$($Pr.repository.id)/pullRequests/$($Pr.pullRequestId)/workitems").value)
    $ids = @($refs | Where-Object { $_.id } | ForEach-Object { [string]$_.id } | Select-Object -First 20)
    if (-not $ids.Count) { return @() }
    @((Invoke-AdoRest -Coll $Coll -Project $proj -Path 'wit/workitems' -Query @{ ids = ($ids -join ','); errorPolicy = 'omit' }).value | Where-Object { $_ })
}

function New-AdoThread([hashtable]$Coll, $PrInfo, $Payload) {
    Invoke-AdoRest -Coll $Coll -Method POST -Project $PrInfo.project -Body $Payload `
        -Path "git/repositories/$($PrInfo.repo_id)/pullRequests/$($PrInfo.id)/threads"
}

function Get-AdoMe([hashtable]$Coll) {
    (Invoke-AdoRest -Coll $Coll -Path 'connectionData' -NoApiVersion -Query @{ connectOptions = 'none' }).authenticatedUser
}

function Get-AdoProjectName([hashtable]$Coll) {
    if ($Coll.Projects.Count) { return $Coll.Projects }
    @((Invoke-AdoRest -Coll $Coll -Path 'projects' -Query @{ '$top' = 500; stateFilter = 'wellFormed' }).value | ForEach-Object { $_.name })
}

function Get-AdoReviewerPr([hashtable]$Coll, [string]$Project, [string]$ReviewerId) {
    @((Invoke-AdoRest -Coll $Coll -Project $Project -Path 'git/pullrequests' `
            -Query @{ 'searchCriteria.reviewerId' = $ReviewerId; 'searchCriteria.status' = 'active'; '$top' = 200 }).value | Where-Object { $_ })
}

function ConvertFrom-Html([string]$s) {
    $s = [regex]::Replace($s ?? '', '(?i)<li[^>]*>', "`n- ")
    $s = [regex]::Replace($s, '(?i)<br\s*/?>|</(p|div|li|h\d)>', "`n")
    $s = [regex]::Replace($s, '<[^>]+>', '')
    $s = [Net.WebUtility]::HtmlDecode($s)
    $s = [regex]::Replace($s, '[ \t]*\n[ \t]*', "`n")
    $s = [regex]::Replace($s, '\n+(?=- )', "`n")
    [regex]::Replace($s, '\n{3,}', "`n`n").Trim()
}

function Get-AdoBlob([hashtable]$Coll, $Pr, [string]$Sha) {
    if (-not $script:BlobCache) { $script:BlobCache = @{} }
    if ($script:BlobCache.ContainsKey($Sha)) { return , $script:BlobCache[$Sha] }
    $bytes = Invoke-AdoRest -Coll $Coll -Project $Pr.repository.project.name -Raw `
        -Path "git/repositories/$($Pr.repository.id)/blobs/$Sha" -Query @{ '$format' = 'octetstream'; resolveLfs = 'true' }
    $script:BlobCache[$Sha] = [byte[]]$bytes
    , [byte[]]$bytes
}
