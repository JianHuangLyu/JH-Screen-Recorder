$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$downloadUrl = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.7z"
$checksumUrl = "$downloadUrl.sha256"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("ffmpeg-recorder-" + [Guid]::NewGuid().ToString("N"))
$archivePath = Join-Path $tempRoot "ffmpeg-release-essentials.7z"
$checksumPath = Join-Path $tempRoot "ffmpeg-release-essentials.7z.sha256"
$extractPath = Join-Path $tempRoot "extracted"
$destination = Join-Path $projectRoot "ffmpeg"

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    Write-Host "Downloading FFmpeg essentials build..." -ForegroundColor Cyan
    if (Get-Command "curl.exe" -ErrorAction SilentlyContinue) {
        & curl.exe --fail --location --retry 3 --output $archivePath $downloadUrl
        if ($LASTEXITCODE -ne 0) { throw "FFmpeg download failed (curl exit code $LASTEXITCODE)." }
        & curl.exe --fail --location --retry 3 --silent --show-error --output $checksumPath $checksumUrl
        if ($LASTEXITCODE -ne 0) { throw "Checksum download failed (curl exit code $LASTEXITCODE)." }
    }
    else {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -UseBasicParsing
        Invoke-WebRequest -Uri $checksumUrl -OutFile $checksumPath -UseBasicParsing
    }

    $checksumText = Get-Content -LiteralPath $checksumPath -Raw
    if ($checksumText -notmatch "(?i)[a-f0-9]{64}") {
        throw "The downloaded checksum file is invalid."
    }
    $expectedHash = $Matches[0].ToUpperInvariant()
    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "SHA-256 mismatch. The downloaded archive will not be installed."
    }
    Write-Host "SHA-256 verified. Extracting..." -ForegroundColor Green
    $tarCommand = Get-Command "tar.exe" -ErrorAction SilentlyContinue
    if (-not $tarCommand) {
        throw "Windows tar.exe is required to extract the 7z package."
    }
    New-Item -ItemType Directory -Path $extractPath | Out-Null
    & tar.exe -xf $archivePath -C $extractPath
    if ($LASTEXITCODE -ne 0) { throw "FFmpeg extraction failed (tar exit code $LASTEXITCODE)." }

    $ffmpegExe = Get-ChildItem -LiteralPath $extractPath -Filter "ffmpeg.exe" -File -Recurse | Select-Object -First 1
    if (-not $ffmpegExe) {
        throw "ffmpeg.exe was not found in the archive."
    }

    $binDestination = Join-Path $destination "bin"
    New-Item -ItemType Directory -Path $binDestination -Force | Out-Null
    Copy-Item -LiteralPath $ffmpegExe.FullName -Destination (Join-Path $binDestination "ffmpeg.exe") -Force

    $licenseFiles = Get-ChildItem -LiteralPath $extractPath -File -Recurse | Where-Object {
        $_.Name -match "^(LICENSE|COPYING|README)"
    }
    foreach ($licenseFile in $licenseFiles) {
        Copy-Item -LiteralPath $licenseFile.FullName -Destination $destination -Force
    }

    Write-Host ""
    Write-Host "FFmpeg installed successfully:" -ForegroundColor Green
    Write-Host (Join-Path $binDestination "ffmpeg.exe")
    Write-Host "Return to the recorder and click Refresh devices."
}
catch {
    Write-Host ""
    Write-Host "Installation failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
    Write-Host ""
    Read-Host "Press Enter to close"
}
