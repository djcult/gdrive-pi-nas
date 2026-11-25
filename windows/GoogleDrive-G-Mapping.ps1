# Recreate G: as a convenient view of the David folder in Google Drive.
# Run at user logon in the normal (non-elevated) Windows session.
# H: is hidden separately by the persistent NoDrives registry policy.
$ErrorActionPreference = 'Stop'

$source = 'H:\My Drive\David'
$target = 'G:'
$log = Join-Path $env:LOCALAPPDATA 'GoogleDrive-G-Mapping.log'

try {
    # Google Drive for desktop may take a while to mount H: after sign-in.
    $ready = $false
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        if (Test-Path -LiteralPath $source -PathType Container) {
            $ready = $true
            break
        }
        Start-Sleep -Seconds 5
    }
    if (-not $ready) {
        throw "Google Drive folder unavailable after five minutes: $source"
    }

    # Don't overwrite an existing G: drive or a different SUBST mapping.
    $existing = (& subst.exe) -join "`n"
    $mapping = [regex]::Match($existing, '(?im)^G:\:\s*=>\s*(.+?)\s*$')

    if ($mapping.Success) {
        if ($mapping.Groups[1].Value.TrimEnd('\') -ine $source.TrimEnd('\')) {
            throw "G: already maps to $($mapping.Groups[1].Value); not replacing it."
        }
    } elseif (Test-Path 'G:\') {
        throw 'G: is already in use; not replacing it.'
    } else {
        & subst.exe G: $source
        if ($LASTEXITCODE -ne 0) {
            throw "SUBST failed with exit code $LASTEXITCODE."
        }
    }

    if (-not (Test-Path 'G:\')) {
        throw 'G: mapping exists but cannot be accessed.'
    }
    "$(Get-Date -Format s) OK: G: -> $source" | Out-File -FilePath $log -Append -Encoding utf8
} catch {
    "$(Get-Date -Format s) ERROR: $($_.Exception.Message)" | Out-File -FilePath $log -Append -Encoding utf8
    exit 1
}
