param([string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$recorderSource = [IO.File]::ReadAllText((Join-Path $projectRoot 'recorder.ps1'), [Text.Encoding]::UTF8)
$versionMatch = [regex]::Match($recorderSource, '\$script:AppVersion\s*=\s*"(?<Version>\d+\.\d+)"')
if (-not $versionMatch.Success) { throw '無法從 recorder.ps1 讀取應用程式版本號。' }
$appVersion = $versionMatch.Groups['Version'].Value
$assemblyVersion = "$appVersion.0.0"
$launcherFileName = "JH錄影_v$appVersion.exe"
$installerFileName = "JH錄影程式安裝檔_v$appVersion.exe"
$pathSeparator = [IO.Path]::DirectorySeparatorChar
$projectFullPath = [IO.Path]::GetFullPath($projectRoot).TrimEnd($pathSeparator) + $pathSeparator
$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd($pathSeparator) + $pathSeparator
$temporaryRoot = Join-Path $temporaryBase ('JHCameraBuild_' + [Guid]::NewGuid().ToString('N'))
$temporaryFullPath = [IO.Path]::GetFullPath($temporaryRoot)
if (-not $temporaryFullPath.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase)) {
    throw '暫存建置路徑驗證失敗。'
}
$publishToProjectRoot = [string]::IsNullOrWhiteSpace($OutputDirectory)
if ($publishToProjectRoot) {
    $OutputDirectory = Join-Path $temporaryRoot 'output'
}
$outputFullPath = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $publishToProjectRoot -and -not $outputFullPath.StartsWith($projectFullPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw '自訂建置輸出目錄必須位於專案工作區內。'
}
if (Test-Path -LiteralPath $outputFullPath) { throw "建置輸出目錄已存在：$outputFullPath" }

$payload = Join-Path $temporaryRoot 'payload'
$payloadZip = Join-Path $temporaryRoot 'payload.zip'
$buildVersionSource = Join-Path $temporaryRoot 'BuildVersion.cs'
$launcherOutput = Join-Path $outputFullPath $launcherFileName
$installerOutput = Join-Path $outputFullPath $installerFileName
$uninstallerOutput = Join-Path $payload '解除安裝.exe'
$iconPath = Join-Path $projectRoot 'assets\jh-camera-icon.ico'
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'

try {
    New-Item -ItemType Directory -Path $outputFullPath, $payload -Force | Out-Null
    if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) { throw '找不到 .NET Framework C# 編譯器。' }
    if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) { throw '找不到應用程式圖示。' }
    $buildVersionCode = @"
using System.Reflection;
[assembly: AssemblyVersion("$assemblyVersion")]
[assembly: AssemblyFileVersion("$assemblyVersion")]
internal static class BuildVersion
{
    internal const string ProductVersion = "$appVersion";
    internal const string LauncherName = "$launcherFileName";
}
"@
    [IO.File]::WriteAllText($buildVersionSource, $buildVersionCode, (New-Object Text.UTF8Encoding($false)))

    $launcherArguments = @(
        '/nologo', '/target:winexe', '/platform:x64', '/optimize+', '/codepage:65001',
        ('/win32icon:' + $iconPath), ('/out:' + $launcherOutput),
        '/reference:System.dll', '/reference:System.Core.dll', '/reference:System.Windows.Forms.dll',
        (Join-Path $projectRoot 'RecorderLauncher.cs'), $buildVersionSource
    )
    & $csc @launcherArguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $launcherOutput)) { throw '錄影程式啟動器編譯失敗。' }

    $uninstallerArguments = @(
        '/nologo', '/target:winexe', '/platform:x64', '/optimize+', '/codepage:65001',
        ('/win32icon:' + $iconPath), ('/out:' + $uninstallerOutput),
        '/reference:System.dll', '/reference:System.Core.dll', '/reference:System.Drawing.dll',
        '/reference:System.Windows.Forms.dll', '/reference:System.IO.Compression.dll',
        '/reference:System.IO.Compression.FileSystem.dll', '/reference:Microsoft.CSharp.dll',
        (Join-Path $projectRoot 'JHCameraInstaller.cs'), $buildVersionSource
    )
    & $csc @uninstallerArguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $uninstallerOutput)) { throw '精簡解除安裝程式編譯失敗。' }

    $requiredPayloadFiles = @(
        'recorder.ps1',
        'WasapiLoopbackPipe.cs',
        'VoiceFilterPipe.cs',
        'assets\jh-camera-icon.ico',
        'ffmpeg\bin\ffmpeg.exe',
        'ffmpeg\LICENSE',
        'ffmpeg\README.txt',
        'lib\NAudio.Core.dll',
        'lib\NAudio.Wasapi.dll',
        'lib\WebRtcVad.dll',
        'lib\WebRtcVadSharp.dll',
        'models\std.rnnn',
        'models\README.txt',
        'THIRD-PARTY-LICENSES\NAudio-MIT.txt',
        'THIRD-PARTY-LICENSES\RNNoise-BSD-3-Clause.txt',
        'THIRD-PARTY-LICENSES\WebRtcVadSharp-WebRTC.txt'
    )
    foreach ($relativePath in $requiredPayloadFiles) {
        $sourcePath = Join-Path $projectRoot $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "缺少必要檔案：$relativePath" }
        $destinationPath = Join-Path $payload $relativePath
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destinationPath)) | Out-Null
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
    }
    Copy-Item -LiteralPath $launcherOutput -Destination (Join-Path $payload $launcherFileName) -Force

    $expectedPayloadFiles = @($requiredPayloadFiles + @($launcherFileName, '解除安裝.exe') | ForEach-Object { $_.Replace('/', '\') } | Sort-Object)
    $actualPayloadFiles = @(Get-ChildItem -LiteralPath $payload -Recurse -File | ForEach-Object { $_.FullName.Substring($payload.Length + 1) } | Sort-Object)
    if (($actualPayloadFiles.Count -ne $expectedPayloadFiles.Count) -or (Compare-Object $expectedPayloadFiles $actualPayloadFiles)) {
        throw "安裝內容清單不符合精簡白名單。`r`n預期：$($expectedPayloadFiles -join ', ')`r`n實際：$($actualPayloadFiles -join ', ')"
    }
    $payloadBytes = [long](($actualPayloadFiles | ForEach-Object { (Get-Item -LiteralPath (Join-Path $payload $_)).Length } | Measure-Object -Sum).Sum)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($payload, $payloadZip, [IO.Compression.CompressionLevel]::Optimal, $false)
    $installerArguments = @(
        '/nologo', '/target:winexe', '/platform:x64', '/optimize+', '/codepage:65001',
        ('/win32icon:' + $iconPath), ('/out:' + $installerOutput),
        ('/resource:' + $payloadZip + ',JHCamera.Payload.zip'),
        '/reference:System.dll', '/reference:System.Core.dll', '/reference:System.Drawing.dll',
        '/reference:System.Windows.Forms.dll', '/reference:System.IO.Compression.dll',
        '/reference:System.IO.Compression.FileSystem.dll', '/reference:Microsoft.CSharp.dll',
        (Join-Path $projectRoot 'JHCameraInstaller.cs'), $buildVersionSource
    )
    & $csc @installerArguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $installerOutput)) { throw '安裝程式編譯失敗。' }

    $launcherVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($launcherOutput).FileVersion
    $installerVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($installerOutput).FileVersion
    $uninstallerVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($uninstallerOutput).FileVersion
    if ($launcherVersion -ne $assemblyVersion -or $installerVersion -ne $assemblyVersion -or $uninstallerVersion -ne $assemblyVersion) {
        throw "建置版本錯誤：Launcher=$launcherVersion Installer=$installerVersion Uninstaller=$uninstallerVersion"
    }
    $publishedOutputDirectory = $outputFullPath
    $publishedLauncher = $launcherOutput
    $publishedInstaller = $installerOutput
    if ($publishToProjectRoot) {
        $publishedOutputDirectory = $projectRoot
        $publishedLauncher = Join-Path $projectRoot $launcherFileName
        $publishedInstaller = Join-Path $projectRoot $installerFileName
        Copy-Item -LiteralPath $launcherOutput -Destination $publishedLauncher -Force
        Copy-Item -LiteralPath $installerOutput -Destination $publishedInstaller -Force
    }
    [PSCustomObject]@{
        OutputDirectory = $publishedOutputDirectory
        Launcher = $publishedLauncher
        LauncherBytes = (Get-Item -LiteralPath $publishedLauncher).Length
        Installer = $publishedInstaller
        InstallerBytes = (Get-Item -LiteralPath $publishedInstaller).Length
        PayloadFiles = $actualPayloadFiles.Count
        PayloadBytes = $payloadBytes
        UninstallerBytes = (Get-Item -LiteralPath $uninstallerOutput).Length
        Version = $installerVersion
    }
}
finally {
    if ((Test-Path -LiteralPath $temporaryFullPath) -and $temporaryFullPath.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $temporaryFullPath -Recurse -Force
    }
}
