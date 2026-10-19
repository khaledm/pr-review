# SSIS (.dtsx) -> stable, reviewable text: no layout, GUIDs or version noise.

$script:PcValues = @{ '0' = 'Success'; '1' = 'Failure'; '2' = 'Completion' }

function Get-XAttr($El, [string]$Name) {
    foreach ($a in $El.Attributes) { if ($a.LocalName -eq $Name) { return $a.Value } }
    $null
}

function Get-XChild($El, [string]$Name) {
    @($El.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and (-not $Name -or $_.LocalName -eq $Name) })
}

function Get-XDescendant($El, [string]$Name) {
    @($El.GetElementsByTagName('*') | Where-Object { $_.LocalName -eq $Name })
}

function Add-MultiLine($Out, [string]$Prefix, [string]$Text, [string]$Indent = '    ') {
    $Out.Add($Prefix)
    foreach ($ln in (($Text ?? '') -replace "`r`n", "`n" -split "`n")) { $Out.Add($Indent + $ln.TrimEnd()) }
}

function ConvertTo-DtsxSummary([byte[]]$Bytes) {
    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = 'Prohibit'
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create([IO.MemoryStream]::new($Bytes), $settings)
    $doc = [System.Xml.XmlDocument]::new()
    try { $doc.Load($reader) } finally { $reader.Dispose() }
    $out = [System.Collections.Generic.List[string]]::new()
    $root = $doc.DocumentElement
    $prot = Get-XAttr $root 'ProtectionLevel'
    $out.Add("PACKAGE $(Get-XAttr $root 'ObjectName')  ProtectionLevel=$(if ($prot) { $prot } else { '(default)' })")
    foreach ($c in (Get-XChild $root)) { Add-DtsxNode $out $c 'Package' }
    , $out.ToArray()
}

function Add-DtsxNode($Out, $El, [string]$Path) {
    $tag = $El.LocalName
    switch ($tag) {
        'DesignTimeProperties' { return }
        'ConnectionManager' {
            $name = Get-XAttr $El 'ObjectName'
            if (-not $name) { break }
            $cs = ''
            foreach ($d in $El.GetElementsByTagName('*')) { $v = Get-XAttr $d 'ConnectionString'; if ($v) { $cs = $v; break } }
            $cs = [regex]::Replace($cs, '(?i)((?:password|pwd)\s*=\s*)[^;]*', '$1***')
            $Out.Add("CONNECTION $name`: $cs")
            foreach ($pe in (Get-XDescendant $El 'PropertyExpression')) { $Out.Add("  EXPR $(Get-XAttr $pe 'Name') = $($pe.InnerText)") }
            return
        }
        'PackageParameter' {
            $val = ''
            foreach ($p in (Get-XDescendant $El 'Property')) { if ((Get-XAttr $p 'Name') -eq 'ParameterValue') { $val = $p.InnerText } }
            if ((Get-XAttr $El 'Sensitive') -eq 'True') { $val = '***' }
            $Out.Add("PARAMETER $(Get-XAttr $El 'ObjectName') ($(Get-XAttr $El 'DataType')) = $val")
            return
        }
        'Variable' {
            $name = Get-XAttr $El 'ObjectName'
            if (-not $name) { break }
            $vv = (Get-XChild $El 'VariableValue' | Select-Object -First 1).InnerText
            $ns = Get-XAttr $El 'Namespace'
            $line = "VARIABLE $Path $(if ($ns) { $ns } else { 'User' })::$name = $vv"
            if ((Get-XAttr $El 'EvaluateAsExpression') -eq 'True') { $line += "   EXPRESSION: $(Get-XAttr $El 'Expression')" }
            $Out.Add($line)
            return
        }
        'PrecedenceConstraint' {
            $v = Get-XAttr $El 'Value'
            $vName = if ($null -eq $v) { 'Success' } elseif ($script:PcValues.ContainsKey($v)) { $script:PcValues[$v] } else { $v }
            $line = "FLOW $(Get-XAttr $El 'From') -> $(Get-XAttr $El 'To')  on $vName"
            $expr = Get-XAttr $El 'Expression'
            if ($expr) { $line += "  EvalOp=$(Get-XAttr $El 'EvalOp') Expression: $expr" }
            if ((Get-XAttr $El 'LogicalAnd') -eq 'False') { $line += '  (OR)' }
            $Out.Add($line)
            return
        }
        { $_ -in 'Executable', 'EventHandler' } {
            $name = Get-XAttr $El 'ObjectName'
            if (-not $name) { $name = Get-XAttr $El 'EventName' }
            $here = "$Path\$name"
            $etype = Get-XAttr $El 'ExecutableType'
            if ($tag -eq 'EventHandler') { $etype = "EventHandler $(Get-XAttr $El 'EventName')" }
            $line = "TASK $here [$etype]"
            if ((Get-XAttr $El 'Disabled') -eq 'True') { $line += '  ** DISABLED **' }
            foreach ($k in 'TransactionOption', 'IsolationLevel', 'DelayValidation', 'FailPackageOnFailure', 'MaxErrorCount') {
                $v = Get-XAttr $El $k
                if ($null -ne $v) { $line += "  $k=$v" }
            }
            $Out.Add($line)
            foreach ($c in (Get-XChild $El)) {
                switch ($c.LocalName) {
                    'PropertyExpression' { $Out.Add("  EXPR $(Get-XAttr $c 'Name') = $($c.InnerText)") }
                    'ObjectData' { Add-DtsxTaskData $Out $c }
                    default { Add-DtsxNode $Out $c $here }
                }
            }
            return
        }
    }
    foreach ($c in (Get-XChild $El)) { Add-DtsxNode $Out $c $Path }
}

function Add-DtsxTaskData($Out, $Obj) {
    foreach ($d in (Get-XChild $Obj)) {
        switch ($d.LocalName) {
            'SqlTaskData' {
                $srcType = Get-XAttr $d 'SqlStatementSourceType'
                if ($srcType -and $srcType -ne 'DirectInput') { $Out.Add("  SQL from $srcType`: $(Get-XAttr $d 'SqlStatementSource')") }
                else { Add-MultiLine $Out '  SQL:' (Get-XAttr $d 'SqlStatementSource') }
                foreach ($k in 'ResultType', 'TimeOut', 'BypassPrepare', 'IsStoredProcedure') {
                    $v = Get-XAttr $d $k
                    if ($null -ne $v) { $Out.Add("  $k=$v") }
                }
                foreach ($pb in $d.GetElementsByTagName('*')) {
                    if ($pb.LocalName -eq 'ParameterBinding') {
                        $Out.Add("  PARAM $(Get-XAttr $pb 'ParameterName') <- $(Get-XAttr $pb 'DtsVariableName') ($(Get-XAttr $pb 'ParameterDirection'))")
                    }
                    elseif ($pb.LocalName -eq 'ResultBinding') {
                        $Out.Add("  RESULT $(Get-XAttr $pb 'ResultName') -> $(Get-XAttr $pb 'DtsVariableName')")
                    }
                }
            }
            'pipeline' { Add-DtsxPipeline $Out $d }
            'ScriptProject' {
                foreach ($item in (Get-XDescendant $d 'ProjectItem')) {
                    $n = Get-XAttr $item 'Name'
                    if ($n -match '\.(cs|vb)$' -and $n -notmatch 'AssemblyInfo') { Add-MultiLine $Out "  SCRIPT FILE $n`:" $item.InnerText '    | ' }
                }
            }
            default {
                $parts = foreach ($a in $d.Attributes) {
                    if ($a.Value -and $a.Value -notmatch '^\{?[0-9A-Fa-f-]{36}\}?$') { "$($a.LocalName)=$($a.Value)" }
                }
                if ($parts) {
                    $s = "  DATA $($d.LocalName): " + ($parts -join '; ')
                    $Out.Add($s.Substring(0, [Math]::Min(600, $s.Length)))
                }
                foreach ($c in (Get-XChild $d)) {
                    $t = $c.InnerText.Trim()
                    if ($t -and $t.Length -lt 2000 -and -not (Get-XChild $c).Count) { $Out.Add("  DATA $($c.LocalName): $t") }
                }
            }
        }
    }
}

function Add-DtsxPipeline($Out, $P) {
    foreach ($comp in (Get-XDescendant $P 'component')) {
        $cls = ((Get-XAttr $comp 'componentClassID') -split '\.')[-1]
        $Out.Add("  COMPONENT $(Get-XAttr $comp 'name') [$cls]")
        foreach ($props in (Get-XChild $comp 'properties')) {
            foreach ($prop in (Get-XChild $props 'property')) {
                $pn = Get-XAttr $prop 'name'
                $val = $prop.InnerText.Trim()
                if (-not $val -or $pn -in 'UserComponentTypeName', 'SourceCode', 'BinaryCode') { continue }
                if ($val.Contains("`n")) { Add-MultiLine $Out "    $pn`:" $val '      ' }
                else { $Out.Add("    $pn = $($val.Substring(0, [Math]::Min(500, $val.Length)))") }
            }
        }
        foreach ($conns in (Get-XChild $comp 'connections')) {
            foreach ($cn in (Get-XChild $conns 'connection')) { $Out.Add("    uses connection $(Get-XAttr $cn 'connectionManagerRefId')") }
        }
        foreach ($outs in (Get-XChild $comp 'outputs')) {
            foreach ($o in (Get-XChild $outs 'output')) {
                $cols = [System.Collections.Generic.List[string]]::new()
                foreach ($ocp in (Get-XChild $o 'outputColumns')) {
                    foreach ($oc in (Get-XChild $ocp 'outputColumn')) {
                        $len = Get-XAttr $oc 'length'
                        $cols.Add("$(Get-XAttr $oc 'name'):$(Get-XAttr $oc 'dataType')$(if ($len) { "($len)" })")
                        foreach ($pp in (Get-XDescendant $oc 'property')) {
                            if ((Get-XAttr $pp 'name') -eq 'FriendlyExpression' -and $pp.InnerText) {
                                $Out.Add("    DERIVED $(Get-XAttr $oc 'name') = $($pp.InnerText.Trim())")
                            }
                        }
                    }
                }
                $extra = if ((Get-XAttr $o 'isErrorOut') -eq 'true') { '  ERROR OUTPUT' } else { '' }
                if ($cols.Count -or $extra) {
                    $s = $cols -join ', '
                    $Out.Add("    OUTPUT $(Get-XAttr $o 'name')$extra`: $($s.Substring(0, [Math]::Min(800, $s.Length)))")
                }
                $erd = Get-XAttr $o 'errorRowDisposition'
                if ($erd) { $Out.Add("    errorRowDisposition=$erd") }
            }
        }
    }
    foreach ($path in (Get-XDescendant $P 'path')) {
        $start = ((Get-XAttr $path 'startId') -split '\\')[-1]
        $end = ((Get-XAttr $path 'endId') -split '\\')[-1]
        $Out.Add("  PATH $start -> $end")
    }
}
