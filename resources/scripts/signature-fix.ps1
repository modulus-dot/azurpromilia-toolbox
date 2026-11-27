function Get-OriginalReShadeHash { return '4d31e168f2e062fbe875130b1ea04244737b0f3e59d1308ab717f8924deca81f' }

function New-FixCertificate([string]$OperationId) {
    return New-SelfSignedCertificate -Type CodeSigningCert -Subject ('CN=DLSS5-XeFG-Test-' + $OperationId) `
        -CertStoreLocation 'Cert:\CurrentUser\My' -KeyExportPolicy NonExportable -KeyAlgorithm RSA `
        -KeyLength 3072 -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(1) `
        -FriendlyName ('DLSS5 XeFG optional local signing ' + $OperationId)
}

function Get-TrackedCertificate($State) {
    $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($State.certificate))
    if ($cert.Thumbprint -ne $State.thumbprint -or $cert.Subject -ne ('CN=DLSS5-XeFG-Test-' + $State.operationId) -or $cert.Subject -ne $cert.Issuer) {
        $cert.Dispose(); throw 'The tracked public certificate does not match its installation record.'
    }
    $eku = @($cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' })
    if ($eku.Count -ne 1 -or @($eku[0].EnhancedKeyUsages).Count -ne 1 -or $eku[0].EnhancedKeyUsages[0].Value -ne '1.3.6.1.5.5.7.3.3') {
        $cert.Dispose(); throw 'The tracked certificate is not restricted to code signing.'
    }
    $basic = @($cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.19' })
    if ($basic.Count -and $basic[0].CertificateAuthority) { $cert.Dispose(); throw 'CA certificates are not supported.' }
    return $cert
}

function Remove-FixPrivateKey($State) {
    $subject = 'CN=DLSS5-XeFG-Test-' + $State.operationId
    foreach ($cert in @(Get-ChildItem 'Cert:\CurrentUser\My' | Where-Object { $_.Subject -eq $subject })) {
        if ($State.thumbprint -and $cert.Thumbprint -ne $State.thumbprint) { throw 'A signing key has an unexpected identity.' }
        if ($State.certificate -and [Convert]::ToBase64String($cert.RawData) -ne $State.certificate) { throw 'A signing key does not match the public certificate.' }
        Remove-Item -LiteralPath ('Cert:\CurrentUser\My\' + $cert.Thumbprint) -DeleteKey -ErrorAction Stop
    }
    if (@(Get-ChildItem 'Cert:\CurrentUser\My' | Where-Object { $_.Subject -eq $subject }).Count) { throw 'The temporary signing key could not be removed.' }
}

function Add-FixTrust($State) {
    $certificate = Get-TrackedCertificate $State
    $store = [Security.Cryptography.X509Certificates.X509Store]::new('Root', 'CurrentUser')
    try { $store.Open('ReadWrite'); $store.Add($certificate) }
    finally { $store.Close(); $certificate.Dispose() }
}

function Remove-FixTrust($State) {
    if (-not $State.certificate) { return }
    $certificate = Get-TrackedCertificate $State
    $store = [Security.Cryptography.X509Certificates.X509Store]::new('Root', 'CurrentUser')
    try {
        $store.Open('ReadWrite')
        foreach ($hit in @($store.Certificates | Where-Object { $_.Thumbprint -eq $State.thumbprint })) {
            if ([Convert]::ToBase64String($hit.RawData) -ne $State.certificate) { throw 'A trusted certificate does not match the record.' }
            $store.Remove($hit)
        }
        if (@($store.Certificates | Where-Object { $_.Thumbprint -eq $State.thumbprint }).Count) { throw 'The local trust certificate could not be removed.' }
    }
    finally { $store.Close(); $certificate.Dispose() }
}

function Set-FixSignature([string]$Path, $Certificate) {
    $result = Set-AuthenticodeSignature -LiteralPath $Path -Certificate $Certificate -HashAlgorithm SHA256 -ErrorAction Stop
    if (-not $result.SignerCertificate -or $result.SignerCertificate.Thumbprint -ne $Certificate.Thumbprint) {
        throw 'The staged DLL was not signed by the expected certificate.'
    }
}

function Assert-FixSignature([string]$Path, $State) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or $signature.SignerCertificate.Thumbprint -ne $State.thumbprint) {
        throw 'Windows did not validate the local signature. The game file was not committed.'
    }
}

function Read-SignatureState([string]$Path) {
    $state = Read-Json $Path
    if ($state.schemaVersion -ne 1 -or $state.operationId -notmatch '^[a-f0-9]{32}$' -or
        $state.status -notin 'pending','installed' -or $state.originalHash -ne (Get-OriginalReShadeHash) -or
        ($state.signedHash -and $state.signedHash -notmatch '^[a-f0-9]{64}$') -or
        ($state.thumbprint -and $state.thumbprint -notmatch '^[A-F0-9]{40}$') -or
        ($state.certificate -and $state.certificate.Length -gt 16384) -or
        ([bool]$state.thumbprint -ne [bool]$state.certificate) -or
        ($state.signedHash -and (-not $state.certificate -or $state.signedHash -eq $state.originalHash)) -or
        ($state.status -eq 'installed' -and -not $state.signedHash)) {
        throw 'Invalid local signing record. Keep the record and backup for manual recovery.'
    }
    if ($state.certificate) {
        $cert = Get-TrackedCertificate $state
        $cert.Dispose()
    }
    return $state
}

function Clear-SignatureState([string]$StateDir) {
    foreach ($name in 'original.dll','staged.dll','state.json') {
        $path = Join-SafePath $StateDir $name
        if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
    }
    if (@(Get-ChildItem -LiteralPath $StateDir -Force).Count -eq 0) { [IO.Directory]::Delete($StateDir) }
}

function Restore-SignatureFix([string]$GameDir) {
    $stateDir = Join-SafePath $GameDir '.dlss5-xefg-signfix'
    if (-not (Test-Path -LiteralPath $stateDir)) { return }
    $state = Read-SignatureState (Join-SafePath $stateDir 'state.json')
    $target = Join-SafePath $GameDir 'd3d11.dll'
    $backup = Join-SafePath $stateDir 'original.dll'
    $current = Get-Sha $target
    # Remove reusable key material and trust even when an externally changed DLL needs manual recovery.
    Remove-FixPrivateKey $state
    Remove-FixTrust $state
    if ($current -ne $state.originalHash -and ($current -ne $state.signedHash -or -not $state.signedHash)) {
        throw 'ReShade changed outside the signing step. Automatic restore stopped; keep the signing backup.'
    }
    if ($current -ne $state.originalHash -and (Get-Sha $backup) -ne $state.originalHash) { throw 'The original ReShade backup is missing or corrupt.' }
    if ($current -ne $state.originalHash) { Copy-AtomicFile $backup $target }
    Clear-SignatureState $stateDir
    Write-Host 'Local signing undone; its trust certificate and temporary key were removed.'
}

function Install-SignatureFix([string]$GameDir) {
    Assert-GameNotRunning $GameDir
    $target = Join-SafePath $GameDir 'd3d11.dll'
    $stateDir = Join-SafePath $GameDir '.dlss5-xefg-signfix'
    $statePath = Join-SafePath $stateDir 'state.json'
    if (Test-Path -LiteralPath $stateDir) {
        $existing = Read-SignatureState $statePath
        if ($existing.status -eq 'installed' -and (Get-Sha $target) -eq $existing.signedHash) {
            Assert-FixSignature $target $existing
            Write-Host 'This ReShade DLL already has the optional local signature.'
            return
        }
        throw 'Pending local signing state exists. Restore it before retrying.'
    }
    if ((Get-Sha $target) -ne (Get-OriginalReShadeHash)) { throw 'Only this package original ReShade d3d11.dll can be signed.' }
    $state = [pscustomobject]@{schemaVersion=1; status='pending'; operationId=[guid]::NewGuid().ToString('N');
        originalHash=(Get-OriginalReShadeHash); signedHash=''; thumbprint=''; certificate=''}
    # Journal first: an interrupted certificate creation can be recovered by its unique subject.
    Write-AtomicJson $statePath $state
    $certificate = $null
    try {
        Copy-AtomicFile $target (Join-SafePath $stateDir 'original.dll')
        $stage = Join-SafePath $stateDir 'staged.dll'
        Copy-AtomicFile $target $stage
        if ((Get-Sha (Join-SafePath $stateDir 'original.dll')) -ne $state.originalHash) { throw 'The backup does not match the known ReShade DLL.' }
        $certificate = New-FixCertificate $state.operationId
        $state.thumbprint = $certificate.Thumbprint
        $state.certificate = [Convert]::ToBase64String($certificate.RawData)
        Write-AtomicJson $statePath $state
        Set-FixSignature $stage $certificate
        $state.signedHash = Get-Sha $stage
        Write-AtomicJson $statePath $state
        # The public trust entry remains, but no reusable private key is retained.
        Remove-FixPrivateKey $state
        Add-FixTrust $state
        Assert-FixSignature $stage $state
        if ((Get-Sha $target) -ne $state.originalHash) { throw 'The game file changed while local signing was being prepared.' }
        Copy-AtomicFile $stage $target
        $state.status = 'installed'
        Write-AtomicJson $statePath $state
        Write-Host 'Optional local signature applied. This does not certify safety or guarantee game compatibility.'
    }
    catch {
        $failure = $_
        try { Restore-SignatureFix $GameDir }
        catch { throw 'Local signing failed and cleanup is incomplete. Run Restore local signature before uninstalling; keep its state and backup.' }
        throw $failure
    }
    finally { if ($certificate) { $certificate.Dispose() } }
}
