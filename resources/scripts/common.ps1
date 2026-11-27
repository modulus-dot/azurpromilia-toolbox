Set-StrictMode -Version 2.0

function Get-Sha([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-SafePath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\') -or $full -eq [IO.Path]::GetPathRoot($full)) {
        throw 'Use a local directory, not a network path or drive root.'
    }
    $cursor = $full
    while ($cursor -and $cursor -ne [IO.Path]::GetPathRoot($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Junctions, symlinks and reparse points are not supported.'
            }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $full
}

function Join-SafePath([string]$Root, [string]$Name) {
    if (-not $Name -or $Name -match '(^[\\/]|[:*?"<>|]|(^|[\\/])\.{1,2}([\\/]|$)|[. ]([\\/]|$))') {
        throw 'Invalid relative file name.'
    }
    foreach ($segment in ($Name -split '[\\/]')) {
        if (-not $segment -or $segment -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') { throw 'Unsupported file name.' }
    }
    $full = Assert-SafePath (Join-Path $Root $Name)
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A file path escapes its managed directory.'
    }
    return $full
}

function Write-AtomicBytes([string]$Path, [byte[]]$Bytes) {
    $null = Assert-SafePath $Path
    $parent = [IO.Path]::GetDirectoryName($Path)
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temp = Join-Path $parent ('.xefg-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [IO.FileStream]::new($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    }
    finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Copy-AtomicFile([string]$Source, [string]$Target) {
    $null = Assert-SafePath $Source
    $null = Assert-SafePath $Target
    $parent = [IO.Path]::GetDirectoryName($Target)
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temp = Join-Path $parent ('.xefg-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $inputStream = [IO.File]::OpenRead($Source)
        try {
            $outputStream = [IO.FileStream]::new($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $inputStream.CopyTo($outputStream); $outputStream.Flush($true) } finally { $outputStream.Dispose() }
        }
        finally { $inputStream.Dispose() }
        if ((Get-Sha $Source) -ne (Get-Sha $temp)) { throw 'File verification failed before committing the copy.' }
        if ([IO.File]::Exists($Target)) { [IO.File]::Replace($temp, $Target, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Target) }
    }
    finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Write-AtomicJson([string]$Path, $Value) {
    $json = ConvertTo-Json -InputObject $Value -Depth 8
    Write-AtomicBytes $Path ([Text.UTF8Encoding]::new($false).GetBytes($json + "`r`n"))
}

function Read-Json([string]$Path) {
    $null = Assert-SafePath $Path
    if ((Get-Item -LiteralPath $Path).Length -gt 4MB) { throw 'The state file exceeds the size limit.' }
    return [IO.File]::ReadAllText($Path) | ConvertFrom-Json
}

function Set-IniValues([string]$Path, [string]$Section, $Pairs) {
    $text = [IO.File]::ReadAllText($Path)
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($line in ($text -split '\r?\n')) { $lines.Add($line) }
    foreach ($key in $Pairs.Keys) {
        $head = -1; $end = $lines.Count
        $found = [Collections.Generic.List[int]]::new()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*\[([^\]]+)\]\s*$') {
                if ($head -ge 0) { $end = $i; break }
                if ($Matches[1].Trim() -ieq $Section) { $head = $i }
            }
            elseif ($head -ge 0 -and $lines[$i] -match '^\s*([^=;#]+)\s*=') {
                if ($Matches[1].Trim() -ieq $key) { $found.Add($i) }
            }
        }
        if ($found.Count) {
            $lines[$found[0]] = "$key=$($Pairs[$key])"
            for ($j = $found.Count - 1; $j -gt 0; $j--) { $lines.RemoveAt($found[$j]) }
        }
        elseif ($head -lt 0) { $lines.Add("[$Section]"); $lines.Add("$key=$($Pairs[$key])") }
        else { $lines.Insert($end, "$key=$($Pairs[$key])") }
    }
    [IO.File]::WriteAllText($Path, (($lines -join $nl).TrimEnd("`r", "`n") + $nl), [Text.UTF8Encoding]::new($false))
}

function Get-IniValue([string]$Path, [string]$Section, [string]$Key) {
    $inSection = $false; $value = $null
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*\[([^\]]+)\]\s*$') { $inSection = $Matches[1].Trim() -ieq $Section }
        elseif ($inSection -and $line -match '^\s*([^=;#]+)\s*=(.*)$') {
            if ($Matches[1].Trim() -ieq $Key) { $value = $Matches[2].Trim() }
        }
    }
    return $value
}

function Set-PackageConfig([string]$Path, [bool]$Existing) {
    Set-IniValues $Path 'RenoDX.DLSS5' ([ordered]@{NRXeFg='1'; NRFrameGen='1'; NRFrameGenEngine='1'})
    $paths = [ordered]@{}
    foreach ($key in 'EffectSearchPaths', 'TextureSearchPaths') {
        $sub = if ($key -eq 'EffectSearchPaths') { 'Shaders' } else { 'Textures' }
        $extra = '.\DLSS5-XeFG-ReShade\' + $sub + '\**'
        $old = Get-IniValue $Path 'GENERAL' $key
        $parts = @($old -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($extra -notin $parts) { $parts += $extra }
        $paths[$key] = $parts -join ','
    }
    if (-not $Existing) { $paths['PresetPath'] = '.\DLSS5-XeFG-ReShade\Presets\Disabled.ini' }
    Set-IniValues $Path 'GENERAL' $paths
}

function Assert-GameNotRunning([string]$GameDir) {
    $prefix = $GameDir.TrimEnd('\') + '\'
    # Deny if a candidate game process cannot be inspected rather than assuming it is safe.
    foreach ($exe in Get-ChildItem -LiteralPath $GameDir -File -Filter '*.exe') {
        foreach ($process in @(Get-Process -Name $exe.BaseName -ErrorAction SilentlyContinue)) {
            try { $processPath = $process.Path } catch { throw 'Cannot inspect a running game process. Exit the game first.' }
            if (-not $processPath -or $processPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Exit the game and its launcher before changing these files.'
            }
        }
    }
}

function Enter-PackageLock([string]$GameDir) {
    $path = Join-SafePath $GameDir '.dlss5-xefg-operation.lock'
    try {
        return [IO.FileStream]::new($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
    }
    catch { throw 'Cannot lock the game directory. Close other installer windows and check write permissions.' }
}
