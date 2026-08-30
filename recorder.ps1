param([switch]$SmokeTest, [switch]$AudioDiagnostics)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression
Add-Type -ReferencedAssemblies @("System.Windows.Forms", "System.Drawing") -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public static class RecorderNative {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, int wParam, int lParam);
    [DllImport("user32.dll")] public static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint affinity);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern IntPtr LoadLibrary(string fileName);
}
public class SmoothSelectionForm : Form {
    public SmoothSelectionForm() {
        this.DoubleBuffered = true;
        this.SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
    }
}
"@

[RecorderNative]::SetProcessDPIAware() | Out-Null
[RecorderNative]::SetCurrentProcessExplicitAppUserModelID("JH.Camera.ScreenRecorder") | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:InstanceMutex = $null
if (-not $SmokeTest -and -not $AudioDiagnostics -and $env:RECORDER_PAUSE_DIAGNOSTICS -ne "1") {
    $createdNewInstance = $false
    $script:InstanceMutex = [System.Threading.Mutex]::new($true, "Local\FFmpegHighQualityRecorder_SingleInstance", [ref]$createdNewInstance)
    if (-not $createdNewInstance) {
        [System.Windows.Forms.MessageBox]::Show("錄影程式已在背景執行。請使用現有的迷你錄影工具列，或先關閉舊程式再重新開啟。", "程式已開啟", "OK", "Information") | Out-Null
        $script:InstanceMutex.Dispose()
        exit 0
    }
}

$script:ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:AppVersion = "2.33"
$script:WasapiLoopbackAvailable = $false
$script:WasapiLoopbackError = ""
$script:LoopbackCaptures = New-Object System.Collections.Generic.List[object]
try {
    $naudioCorePath = Join-Path $script:ProjectRoot "lib\NAudio.Core.dll"
    $naudioWasapiPath = Join-Path $script:ProjectRoot "lib\NAudio.Wasapi.dll"
    $loopbackSourcePath = Join-Path $script:ProjectRoot "WasapiLoopbackPipe.cs"
    if ((Test-Path -LiteralPath $naudioCorePath) -and (Test-Path -LiteralPath $naudioWasapiPath) -and (Test-Path -LiteralPath $loopbackSourcePath)) {
        Add-Type -Path $naudioCorePath
        Add-Type -Path $naudioWasapiPath
        $netstandardPath = [System.Reflection.Assembly]::Load("netstandard, Version=2.0.0.0, Culture=neutral, PublicKeyToken=cc7b13ffcd2ddd51").Location
        Add-Type -Path $loopbackSourcePath -ReferencedAssemblies @($naudioCorePath, $naudioWasapiPath, $netstandardPath, "System", "System.Core")
        [RecorderLoopbackPipe]::Probe() | Out-Null
        $script:WasapiLoopbackAvailable = $true
    }
    else {
        $script:WasapiLoopbackError = "缺少 NAudio WASAPI 元件。"
    }
}
catch {
    $script:WasapiLoopbackError = $_.Exception.Message
}
$script:VoiceFilterAvailable = $false
$script:VoiceFilterError = ""
$script:VoiceCaptures = New-Object System.Collections.Generic.List[object]
try {
    $vadManagedPath = Join-Path $script:ProjectRoot "lib\WebRtcVadSharp.dll"
    $vadNativePath = Join-Path $script:ProjectRoot "lib\WebRtcVad.dll"
    $voiceFilterSourcePath = Join-Path $script:ProjectRoot "VoiceFilterPipe.cs"
    $voiceModelPath = Join-Path $script:ProjectRoot "models\std.rnnn"
    if ((Test-Path -LiteralPath $vadManagedPath) -and (Test-Path -LiteralPath $vadNativePath) -and (Test-Path -LiteralPath $voiceFilterSourcePath) -and (Test-Path -LiteralPath $voiceModelPath)) {
        $vadNativeHandle = [RecorderNative]::LoadLibrary($vadNativePath)
        if ($vadNativeHandle -eq [IntPtr]::Zero) {
            throw "WebRTC VAD 原生元件載入失敗（Windows 錯誤碼：$([Runtime.InteropServices.Marshal]::GetLastWin32Error())）。"
        }
        Add-Type -Path $vadManagedPath
        $voiceNetstandardPath = [System.Reflection.Assembly]::Load("netstandard, Version=2.0.0.0, Culture=neutral, PublicKeyToken=cc7b13ffcd2ddd51").Location
        Add-Type -Path $voiceFilterSourcePath -ReferencedAssemblies @($vadManagedPath, $voiceNetstandardPath, "System", "System.Core")
        $script:VoiceFilterAvailable = $true
    }
    else {
        $script:VoiceFilterError = "缺少 RNNoise 或 WebRTC VAD 元件。"
    }
}
catch {
    $script:VoiceFilterError = $_.Exception.Message
}
$script:NoAudio = "（不錄音）"
$script:RecorderProcess = $null
$script:ErrorTask = $null
$script:Recording = $false
$script:Paused = $false
$script:PendingAction = ""
$script:StartedAt = [DateTime]::Now
$script:LastOutput = $null
$script:LastScreenshotDirectory = ""
$script:CloseAfterStop = $false
$script:AudioDeviceMap = @{}
$script:RecordingDevices = @()
$script:RecordingSegments = New-Object System.Collections.Generic.List[string]
$script:CurrentSegmentPath = $null
$script:SessionDirectory = $null
$script:RecordingStopwatch = New-Object System.Diagnostics.Stopwatch
$script:ToolbarPositioned = $false
$script:ProcessingMessage = "正在處理錄影片段…"
$script:StopRequestedAt = [DateTime]::MinValue
$script:StopWaitNoticeShown = $false
$script:StopForced = $false
$script:LastFFmpegInstallError = ""
$script:FrameRateSelectionInternal = $false
$script:FrameRateManuallySelected = $false
$script:DisplayRefreshRate = 60
try {
    $detectedRefreshRates = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.CurrentRefreshRate -gt 0 } | ForEach-Object { [int]$_.CurrentRefreshRate })
    if ($detectedRefreshRates.Count -gt 0) { $script:DisplayRefreshRate = [int](($detectedRefreshRates | Measure-Object -Maximum).Maximum) }
}
catch { $script:DisplayRefreshRate = 60 }

function Find-FFmpeg([string]$Configured) {
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Configured)) { $candidates.Add($Configured.Trim('"')) }
    $local = Join-Path $script:ProjectRoot "ffmpeg\bin\ffmpeg.exe"
    $candidates.Add($local)
    $command = Get-Command "ffmpeg.exe" -ErrorAction SilentlyContinue
    if ($command) { $candidates.Add($command.Source) }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Install-BundledFFmpeg([string]$DestinationRoot, [string[]]$InstallerCandidates) {
    if ([string]::IsNullOrWhiteSpace($DestinationRoot)) {
        $DestinationRoot = Join-Path $script:ProjectRoot "ffmpeg"
    }
    if ($null -eq $InstallerCandidates -or $InstallerCandidates.Count -eq 0) {
        $InstallerCandidates = @(
            (Join-Path $script:ProjectRoot "解除安裝.exe"),
            (Join-Path $script:ProjectRoot "JH錄影程式安裝檔_v$($script:AppVersion).exe"),
            (Join-Path ([Environment]::GetFolderPath("DesktopDirectory")) "JH錄影程式安裝檔_v$($script:AppVersion).exe"),
            (Join-Path $script:ProjectRoot "JH錄影程式安裝檔.exe"),
            (Join-Path ([Environment]::GetFolderPath("DesktopDirectory")) "JH錄影程式安裝檔.exe")
        )
    }

    $outputMap = @{
        "ffmpeg/bin/ffmpeg.exe" = (Join-Path $DestinationRoot "bin\ffmpeg.exe")
        "ffmpeg/LICENSE" = (Join-Path $DestinationRoot "LICENSE")
        "ffmpeg/README.txt" = (Join-Path $DestinationRoot "README.txt")
    }
    foreach ($packagePath in $InstallerCandidates) {
        if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) { continue }
        $resource = $null
        $archive = $null
        try {
            $resolvedPackage = (Resolve-Path -LiteralPath $packagePath).Path
            $assembly = [System.Reflection.Assembly]::LoadFile($resolvedPackage)
            $resource = $assembly.GetManifestResourceStream("JHCamera.Payload.zip")
            if ($null -eq $resource) { continue }
            $archive = New-Object System.IO.Compression.ZipArchive($resource, [System.IO.Compression.ZipArchiveMode]::Read)
            foreach ($entryName in $outputMap.Keys) {
                $entry = $archive.GetEntry($entryName)
                if ($null -eq $entry) {
                    if ($entryName -eq "ffmpeg/bin/ffmpeg.exe") { throw "本機安裝包缺少 ffmpeg.exe。" }
                    continue
                }
                $destination = $outputMap[$entryName]
                [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
                $inputStream = $entry.Open()
                try {
                    $outputStream = New-Object System.IO.FileStream($destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                    try { $inputStream.CopyTo($outputStream) }
                    finally { $outputStream.Dispose() }
                }
                finally { $inputStream.Dispose() }
            }
            $installedPath = Join-Path $DestinationRoot "bin\ffmpeg.exe"
            if ((Test-Path -LiteralPath $installedPath -PathType Leaf) -and (Get-Item -LiteralPath $installedPath).Length -gt 1048576) {
                return (Resolve-Path -LiteralPath $installedPath).Path
            }
        }
        catch {
            $script:LastFFmpegInstallError = $_.Exception.Message
        }
        finally {
            if ($archive) { $archive.Dispose() }
            if ($resource) { $resource.Dispose() }
        }
    }
    return $null
}

function Quote-Argument([string]$Value) {
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $slashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * ($slashes * 2 + 1)))
            [void]$builder.Append('"')
        }
        else {
            if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)) }
            [void]$builder.Append($character)
        }
        $slashes = 0
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Join-Arguments([System.Collections.Generic.List[string]]$Items) {
    return (($Items | ForEach-Object { Quote-Argument $_ }) -join ' ')
}

function Use-Utf8StandardError([System.Diagnostics.ProcessStartInfo]$Info) {
    try { $Info.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
}

function Test-OpenALDevice([string]$FFmpegPath, [object]$Device) {
    $lastError = ""
    foreach ($sampleRate in @(48000, 44100, 16000)) {
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $FFmpegPath
        $nameArgument = Quote-Argument $Device.Name
        $info.Arguments = "-hide_banner -loglevel error -f openal -channels 1 -sample_rate $sampleRate -sample_size 16 -i $nameArgument -t 0.20 -f null NUL"
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardError = $true
        Use-Utf8StandardError $info
        try {
            $process = [System.Diagnostics.Process]::Start($info)
            $lastError = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            if ($process.ExitCode -eq 0) {
                return [PSCustomObject]@{ Success = $true; SampleRate = $sampleRate; Error = "" }
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }
    return [PSCustomObject]@{ Success = $false; SampleRate = 0; Error = $lastError }
}

function Test-DirectShowDevice([string]$FFmpegPath, [object]$Device) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FFmpegPath
    $inputArgument = Quote-Argument ("audio=" + $Device.Name)
    $info.Arguments = "-hide_banner -loglevel error -f dshow -i $inputArgument -t 0.20 -f null NUL"
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardError = $true
    Use-Utf8StandardError $info
    try {
        $process = [System.Diagnostics.Process]::Start($info)
        $errorText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return [PSCustomObject]@{ Success = ($process.ExitCode -eq 0); SampleRate = 48000; Error = $errorText }
    }
    catch {
        return [PSCustomObject]@{ Success = $false; SampleRate = 0; Error = $_.Exception.Message }
    }
}

function Test-AudioDevice([string]$FFmpegPath, [object]$Device) {
    if ($Device.Backend -eq "wasapi-loopback") {
        if (-not $script:WasapiLoopbackAvailable) {
            return [PSCustomObject]@{ Success = $false; SampleRate = 0; Channels = 0; InputFormat = ""; Error = $script:WasapiLoopbackError }
        }
        try {
            $format = [RecorderLoopbackPipe]::Probe()
            return [PSCustomObject]@{
                Success = $true
                SampleRate = $format.SampleRate
                Channels = $format.Channels
                InputFormat = $format.InputFormat
                Error = ""
            }
        }
        catch {
            return [PSCustomObject]@{ Success = $false; SampleRate = 0; Channels = 0; InputFormat = ""; Error = $_.Exception.Message }
        }
    }
    if ($Device.Backend -eq "openal") { return Test-OpenALDevice $FFmpegPath $Device }
    return Test-DirectShowDevice $FFmpegPath $Device
}

function Test-WasapiLoopbackPipeline([string]$FFmpegPath) {
    if (-not $script:WasapiLoopbackAvailable) {
        return [PSCustomObject]@{ Success = $false; DurationMilliseconds = 0; StopMilliseconds = 0; Error = $script:WasapiLoopbackError }
    }
    $capture = $null
    $process = $null
    $errorTask = $null
    try {
        $pipeName = "RecorderLoopbackDiagnostic_" + [Guid]::NewGuid().ToString("N")
        $capture = New-Object RecorderLoopbackPipe($pipeName)
        $items = New-Object System.Collections.Generic.List[string]
        foreach ($item in @("-hide_banner", "-loglevel", "error", "-nostats", "-progress", "pipe:2", "-f", $capture.InputFormat, "-ar", $capture.SampleRate.ToString(), "-ac", $capture.Channels.ToString(), "-i", "\\.\pipe\$pipeName", "-map", "0:a:0", "-f", "null", "NUL")) {
            $items.Add([string]$item)
        }
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $FFmpegPath
        $info.Arguments = Join-Arguments $items
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardError = $true
        Use-Utf8StandardError $info
        $process = [System.Diagnostics.Process]::Start($info)
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $capture.WaitUntilConnected(5000)) { throw "FFmpeg 未能連接 WASAPI 測試管線。" }
        Start-Sleep -Milliseconds 1200
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $capture.PrepareToStop()
        if (-not $process.WaitForExit(5000)) {
            try { $process.Kill() } catch {}
            throw "WASAPI 音訊送出 EOF 後，FFmpeg 仍未在 5 秒內結束。"
        }
        $stopwatch.Stop()
        $log = $errorTask.Result
        if ($process.ExitCode -ne 0) { throw $log }
        [long]$longestDuration = 0
        foreach ($match in [regex]::Matches($log, '(?m)^out_time_us=(\d+)$')) {
            $durationValue = [long]$match.Groups[1].Value
            if ($durationValue -gt $longestDuration) { $longestDuration = $durationValue }
        }
        $durationMilliseconds = [int]($longestDuration / 1000)
        if ($durationMilliseconds -lt 900) { throw "WASAPI 測試只產生 $durationMilliseconds ms 音訊，連續性不足。" }
        return [PSCustomObject]@{ Success = $true; DurationMilliseconds = $durationMilliseconds; StopMilliseconds = $stopwatch.ElapsedMilliseconds; Error = "" }
    }
    catch {
        return [PSCustomObject]@{ Success = $false; DurationMilliseconds = 0; StopMilliseconds = 0; Error = $_.Exception.Message }
    }
    finally {
        if ($capture) { try { $capture.Dispose() } catch {} }
        if ($process -and -not $process.HasExited) { try { $process.Kill() } catch {} }
    }
}

function Test-VoiceFilterPipeline([string]$FFmpegPath) {
    if (-not $script:VoiceFilterAvailable) {
        return [PSCustomObject]@{ Success = $false; TotalBytes = 0; SilentFrames = 0; Error = $script:VoiceFilterError }
    }
    $voiceCapture = $null
    $client = $null
    try {
        $pipeName = "RecorderVoiceDiagnostic_" + [Guid]::NewGuid().ToString("N")
        $modelPath = Join-Path $script:ProjectRoot "models\std.rnnn"
        $voiceCapture = New-Object RecorderVoiceFilterPipe($pipeName, $FFmpegPath, "lavfi", "anullsrc=r=48000:cl=mono:d=1", 48000, $modelPath)
        $client = New-Object System.IO.Pipes.NamedPipeClientStream(".", $pipeName, [System.IO.Pipes.PipeDirection]::In)
        $client.Connect(5000)
        if (-not $voiceCapture.WaitUntilReady(5000)) {
            $details = $voiceCapture.ErrorMessage
            if ([string]::IsNullOrWhiteSpace($details)) { $details = "RNNoise＋VAD 未能在 5 秒內啟動。" }
            throw $details
        }
        $buffer = New-Object byte[] 8192
        [long]$totalBytes = 0
        [long]$nonZeroBytes = 0
        while (($read = $client.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $totalBytes += $read
            for ($index = 0; $index -lt $read; $index++) {
                if ($buffer[$index] -ne 0) { $nonZeroBytes++ }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($voiceCapture.ErrorMessage)) { throw $voiceCapture.ErrorMessage }
        if ($totalBytes -ne 96000) { throw "人聲管線應保留 1 秒（96000 bytes），實際為 $totalBytes bytes。" }
        if ($nonZeroBytes -ne 0 -or $voiceCapture.VoicedFrames -ne 0 -or $voiceCapture.SilentFrames -ne 50) {
            throw "人聲管線未正確將非人聲替換為等長靜音。"
        }
        return [PSCustomObject]@{ Success = $true; TotalBytes = $totalBytes; SilentFrames = $voiceCapture.SilentFrames; Error = "" }
    }
    catch {
        return [PSCustomObject]@{ Success = $false; TotalBytes = 0; SilentFrames = 0; Error = $_.Exception.Message }
    }
    finally {
        if ($client) { try { $client.Dispose() } catch {} }
        if ($voiceCapture) { try { $voiceCapture.Dispose() } catch {} }
    }
}

function Test-VoiceMicrophonePipeline([string]$FFmpegPath, [object]$Device) {
    if (-not $script:VoiceFilterAvailable) {
        return [PSCustomObject]@{ Success = $false; TotalBytes = 0; VoicedFrames = 0; SilentFrames = 0; Error = $script:VoiceFilterError }
    }
    $voiceCapture = $null
    $client = $null
    try {
        $pipeName = "RecorderVoiceMicDiagnostic_" + [Guid]::NewGuid().ToString("N")
        $sampleRate = if ($Device.PSObject.Properties["SampleRate"] -and $Device.SampleRate) { [int]$Device.SampleRate } else { 48000 }
        $voiceCapture = New-Object RecorderVoiceFilterPipe($pipeName, $FFmpegPath, $Device.Backend, $Device.Name, $sampleRate, (Join-Path $script:ProjectRoot "models\std.rnnn"))
        $client = New-Object System.IO.Pipes.NamedPipeClientStream(".", $pipeName, [System.IO.Pipes.PipeDirection]::In, [System.IO.Pipes.PipeOptions]::Asynchronous)
        $client.Connect(5000)
        if (-not $voiceCapture.WaitUntilReady(5000)) {
            $details = $voiceCapture.ErrorMessage
            if ([string]::IsNullOrWhiteSpace($details)) { $details = "麥克風人聲管線未能在 5 秒內啟動。" }
            throw $details
        }
        $buffer = New-Object byte[] 8192
        [long]$totalBytes = 0
        $deadline = [DateTime]::UtcNow.AddSeconds(3)
        while ($totalBytes -lt 96000 -and [DateTime]::UtcNow -lt $deadline) {
            $readTask = $client.ReadAsync($buffer, 0, $buffer.Length)
            if (-not $readTask.Wait(2000)) { throw "麥克風人聲管線超過 2 秒沒有送出連續音訊。" }
            $read = $readTask.Result
            if ($read -le 0) { break }
            $totalBytes += $read
        }
        $voiceCapture.PrepareToStop()
        if ($totalBytes -lt 90000) { throw "麥克風人聲管線資料不足：$totalBytes bytes。" }
        if (-not [string]::IsNullOrWhiteSpace($voiceCapture.ErrorMessage)) { throw $voiceCapture.ErrorMessage }
        return [PSCustomObject]@{ Success = $true; TotalBytes = $totalBytes; VoicedFrames = $voiceCapture.VoicedFrames; SilentFrames = $voiceCapture.SilentFrames; Error = "" }
    }
    catch {
        return [PSCustomObject]@{ Success = $false; TotalBytes = 0; VoicedFrames = 0; SilentFrames = 0; Error = $_.Exception.Message }
    }
    finally {
        if ($voiceCapture) { try { $voiceCapture.PrepareToStop() } catch {} }
        if ($client) { try { $client.Dispose() } catch {} }
        if ($voiceCapture) { try { $voiceCapture.Dispose() } catch {} }
    }
}

function Get-AudioDevices([string]$FFmpegPath) {
    $devices = New-Object System.Collections.Generic.List[object]
    $knownNames = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

    if ($script:WasapiLoopbackAvailable) {
        $devices.Add([PSCustomObject]@{
            Backend = "wasapi-loopback"
            Name = "DefaultPlayback"
            Display = "系統音訊（預設播放裝置／WASAPI）"
            Channels = 2
            SampleRate = 48000
            InputFormat = "f32le"
            PipePath = ""
        })
    }

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FFmpegPath
    $info.Arguments = "-hide_banner -list_devices true -f dshow -i dummy"
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardError = $true
    Use-Utf8StandardError $info
    $process = [System.Diagnostics.Process]::Start($info)
    $output = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $insideAudio = $false
    foreach ($line in ($output -split "`r?`n")) {
        if ($line -match "DirectShow audio devices") { $insideAudio = $true; continue }
        if ($line -match "DirectShow video devices") { $insideAudio = $false; continue }
        if ($insideAudio -and $line -notmatch "Alternative name" -and $line -match '"([^"]+)"') {
            $name = $Matches[1]
            if ($knownNames.Add($name)) {
                $devices.Add([PSCustomObject]@{
                    Backend = "dshow"
                    Name = $name
                    Display = "DirectShow — $name"
                    Channels = 0
                    SampleRate = 48000
                })
            }
        }
    }

    # Some Windows audio drivers expose microphones to OpenAL but not to
    # DirectShow. Query both backends so recording still works on those PCs.
    $openALInfo = New-Object System.Diagnostics.ProcessStartInfo
    $openALInfo.FileName = $FFmpegPath
    $openALInfo.Arguments = "-hide_banner -list_devices true -f openal -i dummy"
    $openALInfo.UseShellExecute = $false
    $openALInfo.CreateNoWindow = $true
    $openALInfo.RedirectStandardError = $true
    Use-Utf8StandardError $openALInfo
    $openALProcess = [System.Diagnostics.Process]::Start($openALInfo)
    $openALOutput = $openALProcess.StandardError.ReadToEnd()
    $openALProcess.WaitForExit()

    $insideOpenAL = $false
    foreach ($line in ($openALOutput -split "`r?`n")) {
        if ($line -match "List of OpenAL capture devices") { $insideOpenAL = $true; continue }
        if ($insideOpenAL -and $line -match '^\[[^\]]+\]\s+(.+)$') {
            $name = $Matches[1].Trim()
            if ($name -and $knownNames.Add($name)) {
                $friendlyName = $name -replace '^OpenAL Soft on\s+', ''
                $devices.Add([PSCustomObject]@{
                    Backend = "openal"
                    Name = $name
                    Display = "麥克風（OpenAL）— $friendlyName"
                    Channels = 1
                    SampleRate = 48000
                })
            }
        }
    }
    return $devices
}

function New-Label([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height) {
    $control = New-Object System.Windows.Forms.Label
    $control.Text = $Text
    $control.Location = New-Object System.Drawing.Point($X, $Y)
    $control.Size = New-Object System.Drawing.Size($Width, $Height)
    return $control
}

function New-Button([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height) {
    $control = New-Object System.Windows.Forms.Button
    $control.Text = $Text
    $control.Location = New-Object System.Drawing.Point($X, $Y)
    $control.Size = New-Object System.Drawing.Size($Width, $Height)
    return $control
}

$main = New-Object System.Windows.Forms.Form
$main.Text = "JH Camera錄影程式 v$($script:AppVersion)"
$main.StartPosition = "Manual"
$main.Location = New-Object System.Drawing.Point(20, 20)
$main.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$main.MaximizeBox = $false
$main.ClientSize = New-Object System.Drawing.Size(690, 575)
$main.MinimumSize = $main.Size
$main.MaximumSize = $main.Size
$main.Font = New-Object System.Drawing.Font("Microsoft JhengHei UI", 10)
$main.TopMost = $false
$main.WindowState = [System.Windows.Forms.FormWindowState]::Normal
$script:AppIcon = $null
$appIconPath = Join-Path $script:ProjectRoot "assets\jh-camera-icon.ico"
if (Test-Path -LiteralPath $appIconPath -PathType Leaf) {
    try {
        $script:AppIcon = New-Object System.Drawing.Icon($appIconPath)
        $main.Icon = $script:AppIcon
    } catch { $script:AppIcon = $null }
}
$main.ShowIcon = $true

$dateTimeLabel = New-Label ([DateTime]::Now.ToString("yyyy年MM月dd日 HH:mm:ss")) 25 30 365 34
$dateTimeLabel.Font = New-Object System.Drawing.Font("Microsoft JhengHei UI", 15, [System.Drawing.FontStyle]::Bold)
$dateTimeLabel.ForeColor = [System.Drawing.Color]::DarkSlateGray
$main.Controls.Add($dateTimeLabel)

$customSelect = New-Button "自訂框選" 410 30 110 34
$main.Controls.Add($customSelect)
$fitScreen = New-Button "全螢幕" 535 30 135 35
$main.Controls.Add($fitScreen)

$audioOneLabel = New-Label "音訊來源 1" 22 100 125 27
$main.Controls.Add($audioOneLabel)
$audioOne = New-Object System.Windows.Forms.ComboBox
$audioOne.Location = New-Object System.Drawing.Point(150, 96)
$audioOne.Size = New-Object System.Drawing.Size(350, 30)
$audioOne.DropDownStyle = "DropDownList"
$main.Controls.Add($audioOne)

$audioTwoLabel = New-Label "音訊來源 2" 22 140 125 27
$main.Controls.Add($audioTwoLabel)
$audioTwo = New-Object System.Windows.Forms.ComboBox
$audioTwo.Location = New-Object System.Drawing.Point(150, 135)
$audioTwo.Size = New-Object System.Drawing.Size(350, 30)
$audioTwo.DropDownStyle = "DropDownList"
$main.Controls.Add($audioTwo)

$refresh = New-Button "重新偵測音訊" 510 105 155 50
$main.Controls.Add($refresh)

$fpsLabel = New-Label "幀數" 25 185 108 27
$main.Controls.Add($fpsLabel)
$fps = New-Object System.Windows.Forms.ComboBox
$fps.Location = New-Object System.Drawing.Point(130, 185)
$fps.Size = New-Object System.Drawing.Size(70, 30)
$fps.DropDownStyle = "DropDownList"
[void]$fps.Items.AddRange(@("30", "60"))
$fps.SelectedItem = "60"
$main.Controls.Add($fps)

$qualityLabel = New-Label "畫質" 230 185 62 27
$main.Controls.Add($qualityLabel)
$quality = New-Object System.Windows.Forms.ComboBox
$quality.Location = New-Object System.Drawing.Point(290, 185)
$quality.Size = New-Object System.Drawing.Size(210, 30)
$quality.DropDownStyle = "DropDownList"
[void]$quality.Items.AddRange(@("高畫質（建議）", "極高畫質", "平衡／較小檔案"))
$quality.SelectedIndex = 0
$main.Controls.Add($quality)

$drawMouse = New-Object System.Windows.Forms.CheckBox
$drawMouse.Text = "錄下滑鼠游標"
$drawMouse.Location = New-Object System.Drawing.Point(320, 230)
$drawMouse.Size = New-Object System.Drawing.Size(150, 27)
$drawMouse.Checked = $true
$main.Controls.Add($drawMouse)

$noiseSuppression = New-Object System.Windows.Forms.CheckBox
$noiseSuppression.Text = "只錄製人聲（RNNoise＋VAD）"
$noiseSuppression.Location = New-Object System.Drawing.Point(20, 230)
$noiseSuppression.Size = New-Object System.Drawing.Size(300, 27)
$noiseSuppression.Checked = $script:VoiceFilterAvailable
$noiseSuppression.Enabled = $script:VoiceFilterAvailable
$noiseSuppression.Tag = if ($script:VoiceFilterAvailable) { "RNNoise 先降低背景雜音，WebRTC VAD 再將非人聲改為等長靜音。" } else { $script:VoiceFilterError }
$noiseSuppression.AutoSize = $false
$main.Controls.Add($noiseSuppression)

$outputPathLabel = New-Label "儲存資料夾" 20 265 125 27
$main.Controls.Add($outputPathLabel)
$outputPath = New-Object System.Windows.Forms.TextBox
$outputPath.Location = New-Object System.Drawing.Point(20, 290)
$outputPath.Size = New-Object System.Drawing.Size(520, 30)
$outputPath.Anchor = "Top,Left,Right"
$videosPath = Join-Path ([Environment]::GetFolderPath("MyVideos")) ""
if ([string]::IsNullOrWhiteSpace($videosPath)) { $videosPath = $script:ProjectRoot }
$outputPath.Text = $videosPath
$main.Controls.Add($outputPath)
$browseOutput = New-Button "瀏覽…" 550 290 115 34
$browseOutput.Anchor = "Top,Right"
$main.Controls.Add($browseOutput)

$ffmpegPathLabel = New-Label "FFmpeg 執行檔" 20 349 160 27
$main.Controls.Add($ffmpegPathLabel)
$ffmpegPath = New-Object System.Windows.Forms.TextBox
$ffmpegPath.Location = New-Object System.Drawing.Point(20, 374)
$ffmpegPath.Size = New-Object System.Drawing.Size(395, 30)
$ffmpegPath.Anchor = "Top,Left,Right"
$main.Controls.Add($ffmpegPath)
$browseFFmpeg = New-Button "選擇…" 425 370 115 38
$browseFFmpeg.Anchor = "Top,Right"
$main.Controls.Add($browseFFmpeg)
$installFFmpeg = New-Button "偵測安裝" 550 370 115 38
$installFFmpeg.Anchor = "Top,Right"
$main.Controls.Add($installFFmpeg)

$screenshotButton = New-Button "擷取截圖" 300 445 115 38
$screenshotButton.Font = New-Object System.Drawing.Font("Microsoft JhengHei UI", 11, [System.Drawing.FontStyle]::Bold)
$main.Controls.Add($screenshotButton)
$record = New-Button "開始錄影" 425 445 115 38
$record.Font = New-Object System.Drawing.Font("Microsoft JhengHei UI", 12, [System.Drawing.FontStyle]::Bold)
$main.Controls.Add($record)
$timerLabel = New-Label "00:00:00" 80 425 210 65
$timerLabel.Font = New-Object System.Drawing.Font("Consolas", 20, [System.Drawing.FontStyle]::Bold)
$timerLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$main.Controls.Add($timerLabel)
$openFolder = New-Button "開啟資料夾" 550 445 115 38
$openFolder.Anchor = "Top,Right"
$main.Controls.Add($openFolder)

$status = New-Label "準備就緒。" 0 0 1 1
$status.Visible = $false
$captureSizeStatus = New-Label "" 20 510 645 55
$captureSizeStatus.Anchor = "Top,Left,Right"
$captureSizeStatus.ForeColor = [System.Drawing.Color]::DarkSlateGray
$captureSizeStatus.Font = New-Object System.Drawing.Font("Microsoft JhengHei UI", 10, [System.Drawing.FontStyle]::Bold)
$main.Controls.Add($captureSizeStatus)

$selector = New-Object System.Windows.Forms.Form
$selector.Text = "錄影捕捉範圍"
$selector.FormBorderStyle = "None"
$selector.TopMost = $false
$selector.ShowInTaskbar = $false
$selector.MaximizeBox = $false
$selector.Opacity = 1.0
$selector.BackColor = [System.Drawing.Color]::Fuchsia
$selector.TransparencyKey = [System.Drawing.Color]::Fuchsia
$selector.MinimumSize = New-Object System.Drawing.Size(160, 90)
$screenArea = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$selector.StartPosition = "Manual"
$selector.Bounds = $screenArea
$script:SuppressCaptureSizeStatus = $false

function Get-RecommendedFrameRate {
    $refreshRate = [Math]::Max(1, $script:DisplayRefreshRate)
    $logicalProcessors = [Math]::Max(1, [Environment]::ProcessorCount)
    $pixelCount = [long]$selector.Width * [long]$selector.Height
    $onBattery = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -eq [System.Windows.Forms.PowerLineStatus]::Offline

    if ($refreshRate -lt 50 -or $onBattery) { return 30 }
    if ($pixelCount -le (1280 * 720) -and $logicalProcessors -ge 8) { return 60 }
    if ($pixelCount -le (1920 * 1080) -and $logicalProcessors -ge 16) { return 60 }
    if ($pixelCount -le (2560 * 1440) -and $logicalProcessors -ge 24) { return 60 }
    return 30
}

function Update-AutomaticFrameRate {
    if ($script:FrameRateManuallySelected) { return }
    $recommended = (Get-RecommendedFrameRate).ToString()
    $script:FrameRateSelectionInternal = $true
    try {
        $fps.SelectedItem = $recommended
        $fpsLabel.Text = "幀數"
    }
    finally { $script:FrameRateSelectionInternal = $false }
}

$fps.Add_SelectedIndexChanged({
    if (-not $script:FrameRateSelectionInternal) {
        $script:FrameRateManuallySelected = $true
        $fpsLabel.Text = "幀數"
    }
})

function Set-CaptureSizeStatus([bool]$UserAdjusted) {
    $captureSizeStatus.Text = "偵測視窗大小: $($selector.Width)*$($selector.Height)"
    Update-AutomaticFrameRate
}

Set-CaptureSizeStatus $false

$selectionBorderThickness = 6
$selectionCornerSize = 18
$selectorTopBorder = New-Object System.Windows.Forms.Panel
$selectorBottomBorder = New-Object System.Windows.Forms.Panel
$selectorLeftBorder = New-Object System.Windows.Forms.Panel
$selectorRightBorder = New-Object System.Windows.Forms.Panel
foreach ($borderControl in @($selectorTopBorder, $selectorBottomBorder, $selectorLeftBorder, $selectorRightBorder)) {
    $borderControl.BackColor = [System.Drawing.Color]::Red
    $selector.Controls.Add($borderControl)
}
$selectorTopBorder.Cursor = [System.Windows.Forms.Cursors]::SizeAll
$selectorBottomBorder.Cursor = [System.Windows.Forms.Cursors]::SizeNS
$selectorLeftBorder.Cursor = [System.Windows.Forms.Cursors]::SizeWE
$selectorRightBorder.Cursor = [System.Windows.Forms.Cursors]::SizeWE

$updateSelectorBorders = {
    $clientWidth = [Math]::Max(1, $selector.ClientSize.Width)
    $clientHeight = [Math]::Max(1, $selector.ClientSize.Height)
    $selectorTopBorder.SetBounds(0, 0, $clientWidth, $selectionBorderThickness)
    $selectorBottomBorder.SetBounds(0, ($clientHeight - $selectionBorderThickness), $clientWidth, $selectionBorderThickness)
    $selectorLeftBorder.SetBounds(0, 0, $selectionBorderThickness, $clientHeight)
    $selectorRightBorder.SetBounds(($clientWidth - $selectionBorderThickness), 0, $selectionBorderThickness, $clientHeight)
    $selectorTopBorder.BringToFront()
    $selectorBottomBorder.BringToFront()
    $selectorLeftBorder.BringToFront()
    $selectorRightBorder.BringToFront()
}
& $updateSelectorBorders
$selector.Add_SizeChanged({
    & $updateSelectorBorders
    if (-not $script:SuppressCaptureSizeStatus) { Set-CaptureSizeStatus $true }
})
$selector.Add_Move({
    if (-not $script:SuppressCaptureSizeStatus) { Set-CaptureSizeStatus $true }
})

$selectorTopBorder.Add_MouseMove({
    param($sender, $eventArgs)
    if ($eventArgs.X -le $selectionCornerSize) { $sender.Cursor = [System.Windows.Forms.Cursors]::SizeNWSE }
    elseif ($eventArgs.X -ge ($sender.Width - $selectionCornerSize)) { $sender.Cursor = [System.Windows.Forms.Cursors]::SizeNESW }
    else { $sender.Cursor = [System.Windows.Forms.Cursors]::SizeAll }
})
$selectorBottomBorder.Add_MouseMove({
    param($sender, $eventArgs)
    if ($eventArgs.X -le $selectionCornerSize) { $sender.Cursor = [System.Windows.Forms.Cursors]::SizeNESW }
    elseif ($eventArgs.X -ge ($sender.Width - $selectionCornerSize)) { $sender.Cursor = [System.Windows.Forms.Cursors]::SizeNWSE }
    else { $sender.Cursor = [System.Windows.Forms.Cursors]::SizeNS }
})
$selectorLeftBorder.Add_MouseMove({
    param($sender, $eventArgs)
    if ($eventArgs.Y -le $selectionCornerSize) { $sender.Cursor = [System.Windows.Forms.Cursors]::SizeNWSE }
    elseif ($eventArgs.Y -ge ($sender.Height - $selectionCornerSize)) { $sender.Cursor = [System.Windows.Forms.Cursors]::SizeNESW }
    else { $sender.Cursor = [System.Windows.Forms.Cursors]::SizeWE }
})
$selectorRightBorder.Add_MouseMove({
    param($sender, $eventArgs)
    if ($eventArgs.Y -le $selectionCornerSize) { $sender.Cursor = [System.Windows.Forms.Cursors]::SizeNESW }
    elseif ($eventArgs.Y -ge ($sender.Height - $selectionCornerSize)) { $sender.Cursor = [System.Windows.Forms.Cursors]::SizeNWSE }
    else { $sender.Cursor = [System.Windows.Forms.Cursors]::SizeWE }
})

$selectorTopBorder.Add_MouseDown({
    param($sender, $eventArgs)
    if ($eventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $hitTest = if ($eventArgs.X -le $selectionCornerSize) { 13 } elseif ($eventArgs.X -ge ($sender.Width - $selectionCornerSize)) { 14 } else { 2 }
    [RecorderNative]::ReleaseCapture() | Out-Null
    [RecorderNative]::SendMessage($selector.Handle, 0xA1, $hitTest, 0) | Out-Null
})
$selectorBottomBorder.Add_MouseDown({
    param($sender, $eventArgs)
    if ($eventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $hitTest = if ($eventArgs.X -le $selectionCornerSize) { 16 } elseif ($eventArgs.X -ge ($sender.Width - $selectionCornerSize)) { 17 } else { 15 }
    [RecorderNative]::ReleaseCapture() | Out-Null
    [RecorderNative]::SendMessage($selector.Handle, 0xA1, $hitTest, 0) | Out-Null
})
$selectorLeftBorder.Add_MouseDown({
    param($sender, $eventArgs)
    if ($eventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $hitTest = if ($eventArgs.Y -le $selectionCornerSize) { 13 } elseif ($eventArgs.Y -ge ($sender.Height - $selectionCornerSize)) { 16 } else { 10 }
    [RecorderNative]::ReleaseCapture() | Out-Null
    [RecorderNative]::SendMessage($selector.Handle, 0xA1, $hitTest, 0) | Out-Null
})
$selectorRightBorder.Add_MouseDown({
    param($sender, $eventArgs)
    if ($eventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $hitTest = if ($eventArgs.Y -le $selectionCornerSize) { 14 } elseif ($eventArgs.Y -ge ($sender.Height - $selectionCornerSize)) { 17 } else { 11 }
    [RecorderNative]::ReleaseCapture() | Out-Null
    [RecorderNative]::SendMessage($selector.Handle, 0xA1, $hitTest, 0) | Out-Null
})

$script:SelectionBitmap = $null
$script:SelectionStart = [System.Drawing.Point]::Empty
$script:SelectionRectangle = [System.Drawing.Rectangle]::Empty
$script:SelectionDragging = $false
$script:SelectionPurpose = "recording"
$script:SelectionMainWasVisible = $false
$script:SelectionSelectorWasVisible = $false
$script:SelectionToolbarWasVisible = $false

$selectionOverlay = New-Object SmoothSelectionForm
$selectionOverlay.Text = "自訂錄影範圍"
$selectionOverlay.FormBorderStyle = "None"
$selectionOverlay.ShowInTaskbar = $false
$selectionOverlay.StartPosition = "Manual"
$selectionOverlay.TopMost = $true
$selectionOverlay.KeyPreview = $true
$selectionOverlay.Cursor = [System.Windows.Forms.Cursors]::Cross
$selectionOverlay.BackColor = [System.Drawing.Color]::Black

function Get-NormalizedSelectionRectangle([System.Drawing.Point]$Start, [System.Drawing.Point]$End) {
    $left = [Math]::Min($Start.X, $End.X)
    $top = [Math]::Min($Start.Y, $End.Y)
    $width = [Math]::Abs($End.X - $Start.X)
    $height = [Math]::Abs($End.Y - $Start.Y)
    return New-Object System.Drawing.Rectangle($left, $top, $width, $height)
}

function Dispose-SelectionBitmap {
    if ($script:SelectionBitmap) {
        $script:SelectionBitmap.Dispose()
        $script:SelectionBitmap = $null
    }
}

function Restore-AfterCustomSelection {
    $selectionOverlay.Hide()
    Dispose-SelectionBitmap
    if ($script:SelectionSelectorWasVisible) { $selector.Show() } else { $selector.Hide() }
    if ($script:SelectionMainWasVisible) { $main.Show() } else { $main.Hide() }
    if ($script:SelectionToolbarWasVisible) { Show-RecordingOverlay } else { $recordingOverlay.Hide() }
    if ($selector.Visible) { $selector.BringToFront() }
    if ($main.Visible) { $main.BringToFront(); $main.Activate() }
}

function Cancel-CustomSelection {
    $cancelledPurpose = $script:SelectionPurpose
    Restore-AfterCustomSelection
    $script:SelectionPurpose = "recording"
    $status.Text = if ($cancelledPurpose -eq "screenshot") { "已取消螢幕截圖。" } else { "已取消自訂框選；錄影範圍未變更。" }
}

function Complete-CustomSelection([System.Drawing.Rectangle]$Rectangle) {
    if ($Rectangle.Width -lt 80 -or $Rectangle.Height -lt 60) {
        $script:SelectionRectangle = [System.Drawing.Rectangle]::Empty
        $selectionOverlay.Invalidate()
        [System.Media.SystemSounds]::Beep.Play()
        return
    }
    if ($script:SelectionPurpose -eq "screenshot") {
        Complete-ScreenshotSelection $Rectangle
        return
    }
    $desktop = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $selector.Bounds = New-Object System.Drawing.Rectangle(
        ($desktop.Left + $Rectangle.Left),
        ($desktop.Top + $Rectangle.Top),
        $Rectangle.Width,
        $Rectangle.Height
    )
    Set-CaptureSizeStatus $true
    Restore-AfterCustomSelection
    $script:SelectionPurpose = "recording"
    $status.Text = "已自訂錄影範圍：$($Rectangle.Width) × $($Rectangle.Height)；仍可拖曳透明邊框微調。"
}

function Start-SelectionOverlay(
    [ValidateSet("recording", "screenshot")][string]$Purpose,
    [System.Drawing.Bitmap]$SourceBitmap = $null
) {
    $desktop = [System.Windows.Forms.SystemInformation]::VirtualScreen
    try {
        $script:SelectionPurpose = $Purpose
        $script:SelectionMainWasVisible = $main.Visible
        $script:SelectionSelectorWasVisible = $selector.Visible
        $script:SelectionToolbarWasVisible = $recordingOverlay.Visible
        $main.Hide()
        $selector.Hide()
        $recordingOverlay.Hide()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 150
        # A pending Form.Shown event can briefly re-open the red selector or
        # mini recording toolbar. Hide them again immediately before capture.
        $main.Hide()
        $selector.Hide()
        $recordingOverlay.Hide()
        [System.Windows.Forms.Application]::DoEvents()

        Dispose-SelectionBitmap
        $script:SelectionBitmap = New-Object System.Drawing.Bitmap(
            $desktop.Width,
            $desktop.Height,
            [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
        )
        $graphics = [System.Drawing.Graphics]::FromImage($script:SelectionBitmap)
        try {
            if ($SourceBitmap) {
                if ($SourceBitmap.Width -ne $desktop.Width -or $SourceBitmap.Height -ne $desktop.Height) {
                    throw "框選測試畫面尺寸不符。"
                }
                $graphics.DrawImageUnscaled($SourceBitmap, 0, 0)
            }
            else {
                $graphics.CopyFromScreen(
                    $desktop.Left,
                    $desktop.Top,
                    0,
                    0,
                    $desktop.Size,
                    [System.Drawing.CopyPixelOperation]::SourceCopy
                )
            }
        }
        finally {
            $graphics.Dispose()
        }

        $script:SelectionStart = [System.Drawing.Point]::Empty
        $script:SelectionRectangle = [System.Drawing.Rectangle]::Empty
        $script:SelectionDragging = $false
        $selectionOverlay.Bounds = $desktop
        $selectionOverlay.Show()
        $selectionOverlay.Activate()
        $selectionOverlay.Invalidate()
    }
    catch {
        Restore-AfterCustomSelection
        $script:SelectionPurpose = "recording"
        $status.Text = "無法開啟自訂框選：$($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($main, $_.Exception.Message, "自訂框選失敗", "OK", "Error") | Out-Null
    }
}

function Start-CustomSelection {
    Start-SelectionOverlay "recording"
}

$selectionOverlay.Add_Paint({
    param($sender, $eventArgs)
    if (-not $script:SelectionBitmap) { return }
    $graphics = $eventArgs.Graphics
    $graphics.DrawImageUnscaled($script:SelectionBitmap, 0, 0)
    $shade = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(145, 0, 0, 0))
    try { $graphics.FillRectangle($shade, $selectionOverlay.ClientRectangle) }
    finally { $shade.Dispose() }

    $rectangle = $script:SelectionRectangle
    if ($rectangle.Width -gt 0 -and $rectangle.Height -gt 0) {
        $graphics.DrawImage(
            $script:SelectionBitmap,
            $rectangle,
            $rectangle,
            [System.Drawing.GraphicsUnit]::Pixel
        )
        $border = New-Object System.Drawing.Pen([System.Drawing.Color]::DeepSkyBlue, 3)
        try {
            $drawRectangle = New-Object System.Drawing.Rectangle(
                $rectangle.X,
                $rectangle.Y,
                ([Math]::Max(1, $rectangle.Width - 1)),
                ([Math]::Max(1, $rectangle.Height - 1))
            )
            $graphics.DrawRectangle($border, $drawRectangle)
        }
        finally { $border.Dispose() }

        $sizeText = "$($rectangle.Width) × $($rectangle.Height)"
        $sizeFont = New-Object System.Drawing.Font("Microsoft JhengHei UI", 11, [System.Drawing.FontStyle]::Bold)
        $textBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $textBackground = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(210, 20, 24, 30))
        try {
            $textSize = $graphics.MeasureString($sizeText, $sizeFont)
            $textX = $rectangle.Left
            $textY = [Math]::Max(4, $rectangle.Top - [int]$textSize.Height - 8)
            $graphics.FillRectangle($textBackground, $textX, $textY, ([int]$textSize.Width + 12), ([int]$textSize.Height + 5))
            $graphics.DrawString($sizeText, $sizeFont, $textBrush, ($textX + 6), ($textY + 2))
        }
        finally {
            $textBackground.Dispose()
            $textBrush.Dispose()
            $sizeFont.Dispose()
        }
    }

    $instruction = if ($script:SelectionPurpose -eq "screenshot") {
        "按住滑鼠左鍵拖曳框選截圖範圍｜Esc 或滑鼠右鍵取消"
    }
    else {
        "按住滑鼠左鍵拖曳選取錄影範圍｜Esc 或滑鼠右鍵取消"
    }
    $instructionFont = New-Object System.Drawing.Font("Microsoft JhengHei UI", 13, [System.Drawing.FontStyle]::Bold)
    $instructionBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $instructionBackground = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(220, 24, 28, 34))
    try {
        $instructionSize = $graphics.MeasureString($instruction, $instructionFont)
        $instructionX = [Math]::Max(12, [int](($selectionOverlay.ClientSize.Width - $instructionSize.Width) / 2))
        $graphics.FillRectangle($instructionBackground, ($instructionX - 12), 14, ([int]$instructionSize.Width + 24), ([int]$instructionSize.Height + 12))
        $graphics.DrawString($instruction, $instructionFont, $instructionBrush, $instructionX, 20)
    }
    finally {
        $instructionBackground.Dispose()
        $instructionBrush.Dispose()
        $instructionFont.Dispose()
    }
})

$selectionOverlay.Add_MouseDown({
    param($sender, $eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        Cancel-CustomSelection
        return
    }
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:SelectionStart = $eventArgs.Location
        $script:SelectionRectangle = [System.Drawing.Rectangle]::Empty
        $script:SelectionDragging = $true
        $selectionOverlay.Capture = $true
    }
})
$selectionOverlay.Add_MouseMove({
    param($sender, $eventArgs)
    if ($script:SelectionDragging) {
        $script:SelectionRectangle = Get-NormalizedSelectionRectangle $script:SelectionStart $eventArgs.Location
        $selectionOverlay.Invalidate()
    }
})
$selectionOverlay.Add_MouseUp({
    param($sender, $eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left -and $script:SelectionDragging) {
        $script:SelectionDragging = $false
        $selectionOverlay.Capture = $false
        Complete-CustomSelection $script:SelectionRectangle
    }
})
$selectionOverlay.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
        $eventArgs.Handled = $true
        Cancel-CustomSelection
    }
})
$selectionOverlay.Add_FormClosing({
    param($sender, $eventArgs)
    if (-not $main.IsDisposed) {
        $eventArgs.Cancel = $true
        Cancel-CustomSelection
    }
})

$recordingOverlay = New-Object System.Windows.Forms.Form
$recordingOverlay.FormBorderStyle = "None"
$recordingOverlay.ShowInTaskbar = $false
$recordingOverlay.StartPosition = "Manual"
$recordingOverlay.TopMost = $true
$recordingOverlay.Size = New-Object System.Drawing.Size(500, 64)
$recordingOverlay.BackColor = [System.Drawing.Color]::FromArgb(28, 31, 36)
$recordingOverlay.Opacity = 0.96

$toolbarGrip = New-Label "⠿" 0 0 34 64
$toolbarGrip.TextAlign = "MiddleCenter"
$toolbarGrip.ForeColor = [System.Drawing.Color]::Silver
$toolbarGrip.Font = New-Object System.Drawing.Font("Segoe UI Symbol", 18, [System.Drawing.FontStyle]::Bold)
$toolbarGrip.Cursor = [System.Windows.Forms.Cursors]::SizeAll
$recordingOverlay.Controls.Add($toolbarGrip)

$overlayLabel = New-Label "00:00:00" 34 0 108 64
$overlayLabel.TextAlign = "MiddleCenter"
$overlayLabel.ForeColor = [System.Drawing.Color]::White
$overlayLabel.Font = New-Object System.Drawing.Font("Consolas", 13, [System.Drawing.FontStyle]::Bold)
$overlayLabel.Cursor = [System.Windows.Forms.Cursors]::SizeAll
$recordingOverlay.Controls.Add($overlayLabel)

$miniPause = New-Button "⏸ 暫停" 148 12 108 40
$miniPause.Enabled = $false
$recordingOverlay.Controls.Add($miniPause)
$miniRecord = New-Button "● 錄製" 262 12 108 40
$recordingOverlay.Controls.Add($miniRecord)
$miniStop = New-Button "■ 停止" 376 12 112 40
$miniStop.Enabled = $false
$recordingOverlay.Controls.Add($miniStop)

foreach ($transportButton in @($miniPause, $miniRecord, $miniStop)) {
    $transportButton.Font = New-Object System.Drawing.Font("Microsoft JhengHei UI", 10, [System.Drawing.FontStyle]::Bold)
    $transportButton.ForeColor = [System.Drawing.Color]::Red
    $transportButton.BackColor = [System.Drawing.Color]::FromArgb(48, 48, 52)
    $transportButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $transportButton.FlatAppearance.BorderColor = [System.Drawing.Color]::Firebrick
    $transportButton.FlatAppearance.BorderSize = 1
    $transportButton.UseVisualStyleBackColor = $false
}

$processingForm = New-Object System.Windows.Forms.Form
$processingForm.Text = "錄影處理進度"
$processingForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$processingForm.ControlBox = $false
$processingForm.ShowInTaskbar = $false
$processingForm.StartPosition = "Manual"
$processingForm.TopMost = $true
$processingForm.ClientSize = New-Object System.Drawing.Size(470, 155)
$processingForm.BackColor = [System.Drawing.Color]::WhiteSmoke
$processingForm.Font = New-Object System.Drawing.Font("Microsoft JhengHei UI", 10)

$processingLabel = New-Label "正在處理錄影片段…" 20 17 420 30
$processingLabel.Font = New-Object System.Drawing.Font("Microsoft JhengHei UI", 11, [System.Drawing.FontStyle]::Bold)
$processingForm.Controls.Add($processingLabel)
$processingBar = New-Object System.Windows.Forms.ProgressBar
$processingBar.Location = New-Object System.Drawing.Point(20, 52)
$processingBar.Size = New-Object System.Drawing.Size(420, 25)
$processingBar.Minimum = 0
$processingBar.Maximum = 100
$processingBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
$processingBar.MarqueeAnimationSpeed = 25
$processingForm.Controls.Add($processingBar)
$processingDetail = New-Label "請勿關閉程式，完成後會自動顯示通知。" 20 86 420 26
$processingDetail.ForeColor = [System.Drawing.Color]::DimGray
$processingForm.Controls.Add($processingDetail)

$toolbarTip = New-Object System.Windows.Forms.ToolTip
$toolbarTip.SetToolTip($toolbarGrip, "按住拖曳工具列；雙擊開啟完整設定")
$toolbarTip.SetToolTip($overlayLabel, "按住拖曳工具列；雙擊開啟完整設定")

$dragToolbar = {
    param($sender, $eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        [RecorderNative]::ReleaseCapture() | Out-Null
        [RecorderNative]::SendMessage($recordingOverlay.Handle, 0xA1, 2, 0) | Out-Null
        $script:ToolbarPositioned = $true
    }
}
$restoreSettings = {
    $main.Show()
    $main.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $main.Activate()
}
$recordingOverlay.Add_MouseDown($dragToolbar)
$toolbarGrip.Add_MouseDown($dragToolbar)
$overlayLabel.Add_MouseDown($dragToolbar)
$toolbarGrip.Add_DoubleClick($restoreSettings)
$overlayLabel.Add_DoubleClick($restoreSettings)

function Position-RecordingOverlay {
    $targetScreen = [System.Windows.Forms.Screen]::FromRectangle($selector.Bounds)
    $area = $targetScreen.WorkingArea
    $recordingOverlay.Location = New-Object System.Drawing.Point(($area.Right - $recordingOverlay.Width - 18), ($area.Top + 18))
    $script:ToolbarPositioned = $true
}

function Show-RecordingOverlay {
    if (-not $script:ToolbarPositioned) { Position-RecordingOverlay }
    $recordingOverlay.Show()
    $recordingOverlay.BringToFront()
    # WDA_EXCLUDEFROMCAPTURE: keep the toolbar visible to the user without
    # burning it into supported Windows screen-capture output.
    [RecorderNative]::SetWindowDisplayAffinity($recordingOverlay.Handle, 0x11) | Out-Null
}

function Position-ProcessingForm {
    $targetScreen = [System.Windows.Forms.Screen]::FromRectangle($selector.Bounds)
    $area = $targetScreen.WorkingArea
    $left = $area.Left + [int](($area.Width - $processingForm.Width) / 2)
    $top = $area.Top + [int](($area.Height - $processingForm.Height) / 2)
    $processingForm.Location = New-Object System.Drawing.Point($left, $top)
}

function Show-ProcessingProgress([string]$Message, [bool]$Determinate, [int]$Value) {
    $script:ProcessingMessage = $Message
    if ($Determinate) {
        $processingBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
        $processingBar.MarqueeAnimationSpeed = 0
        $processingBar.Value = [Math]::Max(0, [Math]::Min(100, $Value))
        $processingLabel.Text = "$Message　$($processingBar.Value)%"
        $processingDetail.Text = "影片封裝進度：$($processingBar.Value)%"
    }
    else {
        $processingLabel.Text = $Message
        $processingBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        $processingBar.MarqueeAnimationSpeed = 25
        $processingDetail.Text = "正在安全封裝影片，請勿關閉程式。"
    }
    if (-not $processingForm.Visible) {
        Position-ProcessingForm
        $processingForm.Show()
        [RecorderNative]::SetWindowDisplayAffinity($processingForm.Handle, 0x11) | Out-Null
    }
    $processingForm.BringToFront()
    [System.Windows.Forms.Application]::DoEvents()
}

function Update-ProcessingProgress([string]$Message, [int]$Value) {
    $script:ProcessingMessage = $Message
    $safeValue = [Math]::Max(0, [Math]::Min(100, $Value))
    if (-not $processingForm.Visible) {
        Show-ProcessingProgress $Message $true $safeValue
        return
    }
    $processingBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $processingBar.MarqueeAnimationSpeed = 0
    $processingBar.Value = $safeValue
    $processingLabel.Text = "$Message　$safeValue%"
    $processingDetail.Text = "影片封裝進度：$safeValue%"
    [System.Windows.Forms.Application]::DoEvents()
}

function Hide-ProcessingProgress {
    if ($processingForm.Visible) {
        $processingForm.Hide()
        $processingBar.Value = 0
        $script:ProcessingMessage = "正在處理錄影片段…"
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Update-TransportControls {
    $hasSession = $script:Recording -or $script:Paused
    $miniRecord.Enabled = -not $hasSession
    $miniStop.Enabled = $hasSession
    $miniPause.Enabled = $hasSession -and [string]::IsNullOrEmpty($script:PendingAction)
    $miniPause.Text = if ($script:Paused) { "▶ 繼續" } else { "⏸ 暫停" }
    $record.Text = if ($hasSession) { "停止並儲存" } else { "開始錄影" }
}

function Set-RecordingControls([bool]$IsRecording) {
    $audioOne.Enabled = -not $IsRecording
    $audioTwo.Enabled = -not $IsRecording
    $refresh.Enabled = -not $IsRecording
    $browseOutput.Enabled = -not $IsRecording
    $browseFFmpeg.Enabled = -not $IsRecording
    $installFFmpeg.Enabled = -not $IsRecording
    $customSelect.Enabled = -not $IsRecording
    $fitScreen.Enabled = -not $IsRecording
    $screenshotButton.Enabled = -not $IsRecording
    $fps.Enabled = -not $IsRecording
    $quality.Enabled = -not $IsRecording
    $drawMouse.Enabled = -not $IsRecording
    $noiseSuppression.Enabled = (-not $IsRecording) -and $script:VoiceFilterAvailable
}

function Refresh-AudioDevices {
    $path = Find-FFmpeg $ffmpegPath.Text
    if (-not $path) {
        $status.Text = "找不到內附的 FFmpeg，請重新安裝程式或手動選擇 ffmpeg.exe。"
        return
    }
    $ffmpegPath.Text = $path
    $refresh.Enabled = $false
    $status.Text = "正在搜尋本機音訊裝置…"
    try {
        # @() guarantees an empty result is still an array with Count = 0.
        $candidates = @(Get-AudioDevices $path)
        $usableDevices = New-Object System.Collections.Generic.List[object]
        $tested = 0
        foreach ($candidate in $candidates) {
            $tested++
            $status.Text = "正在測試音訊裝置 $tested／$($candidates.Count)：$($candidate.Display)…"
            $main.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            [System.Windows.Forms.Application]::DoEvents()
            $audioTest = Test-AudioDevice $path $candidate
            if ($audioTest.Success) {
                $candidate.SampleRate = $audioTest.SampleRate
                if ($audioTest.PSObject.Properties["Channels"] -and $audioTest.Channels) { $candidate.Channels = $audioTest.Channels }
                if ($audioTest.PSObject.Properties["InputFormat"] -and $audioTest.InputFormat) { $candidate.InputFormat = $audioTest.InputFormat }
                $usableDevices.Add($candidate)
            }
        }
        $devices = @($usableDevices.ToArray())
        $audioOne.Items.Clear()
        $audioTwo.Items.Clear()
        [void]$audioOne.Items.Add($script:NoAudio)
        [void]$audioTwo.Items.Add($script:NoAudio)
        $script:AudioDeviceMap = @{}
        foreach ($device in $devices) {
            $script:AudioDeviceMap[$device.Display] = $device
            [void]$audioOne.Items.Add($device.Display)
            [void]$audioTwo.Items.Add($device.Display)
        }
        $systemDevice = @($devices | Where-Object { $_.Backend -eq "wasapi-loopback" } | Select-Object -First 1)
        $microphoneDevice = @($devices | Where-Object { $_.Backend -in @("dshow", "openal") } | Select-Object -First 1)
        if ($systemDevice.Count -gt 0) { $audioOne.SelectedItem = $systemDevice[0].Display } else { $audioOne.SelectedIndex = 0 }
        if ($microphoneDevice.Count -gt 0) { $audioTwo.SelectedItem = $microphoneDevice[0].Display } else { $audioTwo.SelectedIndex = 0 }
        if ($systemDevice.Count -gt 0 -and $microphoneDevice.Count -gt 0) {
            $status.Text = "準備就緒。"
        }
        elseif ($devices.Count -gt 0) {
            $missingSource = if ($systemDevice.Count -eq 0) { "系統播放聲音" } else { "麥克風" }
            $status.Text = "已找到 $($devices.Count) 個可用音訊裝置，但未找到可用的$missingSource。"
        }
        else {
            $status.Text = "未找到可正常錄製的音訊裝置；請開啟 Windows 麥克風權限後重新偵測。"
        }
    }
    catch {
        $status.Text = "音訊裝置偵測失敗：$($_.Exception.Message)"
    }
    finally {
        $main.Cursor = [System.Windows.Forms.Cursors]::Default
        $refresh.Enabled = $true
    }
}

function Get-CaptureRectangle {
    # Native borders can extend beyond the desktop (for example -9 when a
    # window is enlarged to the screen edges). Clamp the user-visible outer
    # selection to the Windows virtual desktop before passing it to FFmpeg.
    $selection = $selector.Bounds
    $desktop = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $left = [Math]::Max($selection.Left, $desktop.Left)
    $top = [Math]::Max($selection.Top, $desktop.Top)
    $right = [Math]::Min($selection.Right, $desktop.Right)
    $bottom = [Math]::Min($selection.Bottom, $desktop.Bottom)
    $width = $right - $left
    $height = $bottom - $top
    $width -= $width % 2
    $height -= $height % 2
    if ($width -lt 2 -or $height -lt 2) {
        throw "錄影範圍不在可擷取的桌面內，請將透明選取框移回螢幕。"
    }
    return New-Object System.Drawing.Rectangle($left, $top, $width, $height)
}

function Save-ScreenRectangleAsPng(
    [System.Drawing.Rectangle]$Rectangle,
    [string]$Path,
    [System.Drawing.Bitmap]$SourceBitmap = $null
) {
    if ($Rectangle.Width -lt 1 -or $Rectangle.Height -lt 1) { throw "截圖範圍無效。" }
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "尚未指定截圖儲存位置。" }
    $bitmap = New-Object System.Drawing.Bitmap(
        $Rectangle.Width,
        $Rectangle.Height,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        if ($null -ne $SourceBitmap) {
            if ($SourceBitmap.Width -ne $Rectangle.Width -or $SourceBitmap.Height -ne $Rectangle.Height) {
                throw "截圖畫面尺寸不符。"
            }
            $graphics.DrawImageUnscaled($SourceBitmap, 0, 0)
        }
        else {
            $graphics.CopyFromScreen(
                $Rectangle.Left,
                $Rectangle.Top,
                0,
                0,
                $bitmap.Size,
                [System.Drawing.CopyPixelOperation]::SourceCopy
            )
        }
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Copy-SelectionBitmapRegion([System.Drawing.Rectangle]$Rectangle) {
    if (-not $script:SelectionBitmap) { throw "找不到可裁切的螢幕畫面。" }
    $sourceBounds = New-Object System.Drawing.Rectangle(0, 0, $script:SelectionBitmap.Width, $script:SelectionBitmap.Height)
    if ($Rectangle.Width -lt 1 -or $Rectangle.Height -lt 1 -or -not $sourceBounds.Contains($Rectangle)) {
        throw "截圖框選範圍無效。"
    }
    $result = New-Object System.Drawing.Bitmap(
        $Rectangle.Width,
        $Rectangle.Height,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    $graphics = [System.Drawing.Graphics]::FromImage($result)
    try {
        $destination = New-Object System.Drawing.Rectangle(0, 0, $Rectangle.Width, $Rectangle.Height)
        $graphics.DrawImage($script:SelectionBitmap, $destination, $Rectangle, [System.Drawing.GraphicsUnit]::Pixel)
    }
    catch {
        $result.Dispose()
        throw
    }
    finally { $graphics.Dispose() }
    return $result
}

function Complete-ScreenshotSelection([System.Drawing.Rectangle]$Rectangle) {
    $selectedBitmap = $null
    $dialog = $null
    try {
        # Crop from the frozen desktop image so the dark overlay, blue border,
        # red recording frame, and recorder UI can never appear in the PNG.
        $selectedBitmap = Copy-SelectionBitmapRegion $Rectangle
        $selectionOverlay.Hide()
        Dispose-SelectionBitmap

        $initialDirectory = $script:LastScreenshotDirectory
        if ([string]::IsNullOrWhiteSpace($initialDirectory)) { $initialDirectory = $outputPath.Text.Trim() }
        if (-not (Test-Path -LiteralPath $initialDirectory -PathType Container)) {
            $initialDirectory = [Environment]::GetFolderPath("MyPictures")
        }
        if ([string]::IsNullOrWhiteSpace($initialDirectory) -or -not (Test-Path -LiteralPath $initialDirectory -PathType Container)) {
            $initialDirectory = [Environment]::GetFolderPath("MyVideos")
        }
        if ([string]::IsNullOrWhiteSpace($initialDirectory)) { $initialDirectory = $script:ProjectRoot }

        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Title = "選擇截圖儲存位置"
        $dialog.Filter = "PNG 圖片|*.png"
        $dialog.DefaultExt = "png"
        $dialog.AddExtension = $true
        $dialog.OverwritePrompt = $true
        $dialog.RestoreDirectory = $true
        $dialog.InitialDirectory = $initialDirectory
        $dialog.FileName = "螢幕截圖_$([DateTime]::Now.ToString('yyyyMMdd_HHmmss')).png"
        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            Restore-AfterCustomSelection
            $status.Text = "已取消螢幕截圖。"
            return
        }

        $savePath = $dialog.FileName
        $saveRectangle = New-Object System.Drawing.Rectangle(0, 0, $selectedBitmap.Width, $selectedBitmap.Height)
        Save-ScreenRectangleAsPng $saveRectangle $savePath $selectedBitmap
        $script:LastScreenshotDirectory = Split-Path -Parent $savePath
        Restore-AfterCustomSelection
        $status.Text = "截圖已儲存：$savePath"
        [System.Windows.Forms.MessageBox]::Show($main, "截圖已儲存。`r`n`r`n$savePath", "截圖完成", "OK", "Information") | Out-Null
    }
    catch {
        Restore-AfterCustomSelection
        $status.Text = "截圖失敗：$($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($main, $_.Exception.Message, "截圖失敗", "OK", "Error") | Out-Null
    }
    finally {
        $script:SelectionPurpose = "recording"
        if ($dialog) { $dialog.Dispose() }
        if ($selectedBitmap) { $selectedBitmap.Dispose() }
    }
}

function Capture-Screenshot {
    if ($script:Recording -or $script:Paused) {
        [System.Windows.Forms.MessageBox]::Show($main, "請先停止目前錄影，再使用獨立截圖功能。", "無法截圖", "OK", "Information") | Out-Null
        return
    }
    Start-SelectionOverlay "screenshot"
}

function Stop-LoopbackCaptures {
    foreach ($loopbackCapture in $script:LoopbackCaptures.ToArray()) {
        try { $loopbackCapture.Dispose() } catch {}
    }
    $script:LoopbackCaptures.Clear()
}

function Prepare-LoopbackCapturesToStop {
    foreach ($loopbackCapture in $script:LoopbackCaptures.ToArray()) {
        try { $loopbackCapture.PrepareToStop() } catch {}
    }
}

function Stop-VoiceCaptures {
    foreach ($voiceCapture in $script:VoiceCaptures.ToArray()) {
        try { $voiceCapture.Dispose() } catch {}
    }
    $script:VoiceCaptures.Clear()
    foreach ($device in @($script:RecordingDevices | Where-Object { $_.Backend -in @("dshow", "openal") })) {
        if ($device.PSObject.Properties["VoiceFiltered"]) { $device.VoiceFiltered = $false }
        if ($device.PSObject.Properties["PipePath"]) { $device.PipePath = "" }
    }
}

function Prepare-VoiceCapturesToStop {
    foreach ($voiceCapture in $script:VoiceCaptures.ToArray()) {
        try { $voiceCapture.PrepareToStop() } catch {}
    }
}

function Request-RecorderProcessStop {
    $script:StopRequestedAt = [DateTime]::UtcNow
    $script:StopWaitNoticeShown = $false
    $script:StopForced = $false
    Prepare-VoiceCapturesToStop
    Prepare-LoopbackCapturesToStop
    try {
        $script:RecorderProcess.StandardInput.WriteLine("q")
        $script:RecorderProcess.StandardInput.Flush()
        $script:RecorderProcess.StandardInput.Close()
    }
    catch {
        try { $script:RecorderProcess.StandardInput.Close() } catch {}
    }
}

function Start-LoopbackCaptures([object[]]$Devices) {
    Stop-LoopbackCaptures
    foreach ($device in @($Devices | Where-Object { $_.Backend -eq "wasapi-loopback" })) {
        if (-not $script:WasapiLoopbackAvailable) { throw "WASAPI 系統音訊元件無法使用：$($script:WasapiLoopbackError)" }
        $pipeName = "RecorderLoopback_" + [Guid]::NewGuid().ToString("N")
        $loopbackCapture = New-Object RecorderLoopbackPipe($pipeName)
        $device.PipePath = "\\.\pipe\$pipeName"
        $device.SampleRate = $loopbackCapture.SampleRate
        $device.Channels = $loopbackCapture.Channels
        $device.InputFormat = $loopbackCapture.InputFormat
        $script:LoopbackCaptures.Add($loopbackCapture)
    }
}

function Wait-LoopbackCaptures {
    foreach ($loopbackCapture in $script:LoopbackCaptures.ToArray()) {
        if (-not $loopbackCapture.WaitUntilConnected(5000)) {
            $details = $loopbackCapture.ErrorMessage
            if ([string]::IsNullOrWhiteSpace($details)) { $details = "FFmpeg 未能在 5 秒內連接系統音訊管線。" }
            throw $details
        }
    }
}

function Start-VoiceCaptures([object[]]$Devices, [string]$FFmpegPath) {
    Stop-VoiceCaptures
    if (-not $noiseSuppression.Checked) { return }
    $microphones = @($Devices | Where-Object { $_.Backend -in @("dshow", "openal") })
    if ($microphones.Count -eq 0) { return }
    if (-not $script:VoiceFilterAvailable) { throw "RNNoise＋WebRTC VAD 人聲元件無法使用：$($script:VoiceFilterError)" }
    $modelPath = Join-Path $script:ProjectRoot "models\std.rnnn"
    try {
        foreach ($device in $microphones) {
            $pipeName = "RecorderVoice_" + [Guid]::NewGuid().ToString("N")
            $inputSampleRate = 48000
            if ($device.PSObject.Properties["SampleRate"] -and $device.SampleRate) { $inputSampleRate = [int]$device.SampleRate }
            $voiceCapture = New-Object RecorderVoiceFilterPipe($pipeName, $FFmpegPath, $device.Backend, $device.Name, $inputSampleRate, $modelPath)
            $device | Add-Member -NotePropertyName VoiceFiltered -NotePropertyValue $true -Force
            $device | Add-Member -NotePropertyName PipePath -NotePropertyValue $voiceCapture.PipePath -Force
            $device | Add-Member -NotePropertyName InputFormat -NotePropertyValue "s16le" -Force
            $device.Channels = 1
            $device.SampleRate = 48000
            $script:VoiceCaptures.Add($voiceCapture)
        }
    }
    catch {
        Stop-VoiceCaptures
        throw
    }
}

function Wait-VoiceCaptures {
    foreach ($voiceCapture in $script:VoiceCaptures.ToArray()) {
        if (-not $voiceCapture.WaitUntilReady(7000)) {
            $details = $voiceCapture.ErrorMessage
            if ([string]::IsNullOrWhiteSpace($details)) { $details = "FFmpeg 未能在 7 秒內連接 RNNoise＋VAD 人聲管線。" }
            throw $details
        }
    }
}

function Build-RecorderArguments([object[]]$Devices, [string]$TargetPath) {
    $items = New-Object System.Collections.Generic.List[string]
    $capture = Get-CaptureRectangle
    $selectedFrameRate = [int]$fps.SelectedItem
    # Keep roughly 4.3 seconds of video packets at either frame rate. This is
    # enough for short CPU spikes without leaving a very large stop-time queue.
    $videoQueueSize = if ($selectedFrameRate -ge 60) { "256" } else { "128" }
    foreach ($item in @("-hide_banner", "-loglevel", "info", "-y", "-thread_queue_size", $videoQueueSize, "-rtbufsize", "512M", "-f", "gdigrab", "-framerate", $fps.SelectedItem.ToString(), "-offset_x", $capture.Left.ToString(), "-offset_y", $capture.Top.ToString(), "-video_size", "$($capture.Width)x$($capture.Height)", "-draw_mouse", $(if ($drawMouse.Checked) { "1" } else { "0" }), "-i", "desktop")) {
        $items.Add([string]$item)
    }
    foreach ($device in $Devices) {
        $backend = $device.Backend
        if ($backend -eq "wasapi-loopback") {
            if ([string]::IsNullOrWhiteSpace($device.PipePath)) { throw "尚未建立 WASAPI 系統音訊管線。" }
            foreach ($item in @("-thread_queue_size", "4096", "-f", $device.InputFormat, "-ar", $device.SampleRate.ToString(), "-ac", $device.Channels.ToString(), "-i", $device.PipePath)) {
                $items.Add([string]$item)
            }
            continue
        }
        $voiceFiltered = $device.PSObject.Properties["VoiceFiltered"] -and $device.VoiceFiltered
        if ($voiceFiltered) {
            if ([string]::IsNullOrWhiteSpace($device.PipePath)) { throw "尚未建立 RNNoise＋VAD 人聲管線。" }
            foreach ($item in @("-thread_queue_size", "4096", "-f", "s16le", "-ar", "48000", "-ac", "1", "-i", $device.PipePath)) {
                $items.Add([string]$item)
            }
            continue
        }
        $inputName = if ($backend -eq "dshow") { "audio=$($device.Name)" } else { $device.Name }
        $inputItems = @("-thread_queue_size", "4096", "-rtbufsize", "256M")
        if ($backend -eq "dshow") { $inputItems += @("-use_wallclock_as_timestamps", "1") }
        $inputItems += @("-f", $backend)
        if ($backend -eq "openal") {
            # OpenAL defaults to stereo/44.1 kHz. Many built-in Windows
            # microphone arrays are mono-only and reject that format.
            $sampleRate = 48000
            if ($device.PSObject.Properties["SampleRate"] -and $device.SampleRate) { $sampleRate = $device.SampleRate }
            $inputItems += @("-channels", "1", "-sample_rate", $sampleRate.ToString(), "-sample_size", "16")
        }
        $inputItems += @("-i", $inputName)
        foreach ($item in $inputItems) {
            $items.Add([string]$item)
        }
    }
    $items.Add("-map"); $items.Add("0:v:0")
    if ($Devices.Count -eq 1) {
        $audioFilter = "aresample=48000,asetpts=N/SR/TB"
        $audioFilter += ",alimiter=limit=0.80:attack=5:release=50:level=false[aout]"
        $items.Add("-filter_complex")
        $items.Add("[1:a]$audioFilter")
        $items.Add("-map"); $items.Add("[aout]")
    }
    elseif ($Devices.Count -gt 1) {
        $filters = New-Object System.Collections.Generic.List[string]
        $labels = ""
        for ($index = 1; $index -le $Devices.Count; $index++) {
            $audioFilter = "aresample=48000,asetpts=N/SR/TB"
            $filters.Add("[$index`:a]$audioFilter[a$index]")
            $labels += "[a$index]"
        }
        $filters.Add($labels + "amix=inputs=$($Devices.Count):duration=longest:dropout_transition=2:normalize=1,alimiter=limit=0.80:attack=5:release=50:level=false[aout]")
        $items.Add("-filter_complex"); $items.Add(($filters -join ";"))
        $items.Add("-map"); $items.Add("[aout]")
    }
    $crf = switch ($quality.SelectedIndex) { 1 { "12" } 2 { "20" } default { "16" } }
    # Full-HD-and-larger desktop capture was slightly below real time on the
    # target PC (about 0.94x). Prefer a faster x264 preset at this size so the
    # capture queue does not grow throughout a long recording. CRF still
    # controls visual quality; the tradeoff is a somewhat larger file.
    $highLoadCapture = (($capture.Width * $capture.Height) -ge (1920 * 1080))
    $preset = if ($highLoadCapture) { "superfast" } elseif ($quality.SelectedIndex -eq 1) { "fast" } else { "veryfast" }
    foreach ($item in @("-c:v", "libx264", "-preset", $preset, "-crf", $crf, "-pix_fmt", "yuv420p", "-fps_mode", "cfr")) { $items.Add([string]$item) }
    if ($Devices.Count -gt 0) {
        foreach ($item in @("-c:a", "aac", "-b:a", "256k", "-ar", "48000")) { $items.Add([string]$item) }
    }
    $items.Add("-max_muxing_queue_size"); $items.Add("4096")
    # Recording segments use Matroska so an interrupted encoder leaves a much
    # better chance of a readable file. MP4 remuxing happens only at finalize.
    $items.Add($TargetPath)
    return (Join-Arguments $items)
}

function Get-ConcatListLines([string[]]$Segments) {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($segment in $Segments) {
        $portablePath = $segment.Replace('\', '/')
        $safePath = $portablePath.Replace("'", "'\''")
        $lines.Add("file '$safePath'")
    }
    return $lines.ToArray()
}

function Build-ConcatArguments([string]$ConcatPath, [string]$TargetPath) {
    $items = New-Object System.Collections.Generic.List[string]
    # Stream copy joins paused segments without decoding or re-encoding.
    # Omitting faststart avoids an additional full-file rewrite.
    foreach ($item in @("-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", $ConcatPath, "-map", "0", "-c", "copy", $TargetPath)) {
        $items.Add([string]$item)
    }
    return (Join-Arguments $items)
}

function Test-RecordingSegmentReadable([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $pathToFFmpeg = Find-FFmpeg $ffmpegPath.Text
    if (-not $pathToFFmpeg) { return $false }
    $items = New-Object System.Collections.Generic.List[string]
    foreach ($item in @("-hide_banner", "-loglevel", "error", "-i", $Path, "-map", "0:v:0", "-frames:v", "1", "-f", "null", "NUL")) {
        $items.Add([string]$item)
    }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $pathToFFmpeg
    $info.Arguments = Join-Arguments $items
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardError = $true
    Use-Utf8StandardError $info
    try {
        $process = [System.Diagnostics.Process]::Start($info)
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            try { $process.Kill() } catch {}
            return $false
        }
        $null = $errorTask.Result
        return ($process.ExitCode -eq 0)
    }
    catch {
        return $false
    }
}

function Get-FFmpegErrorSummary([string]$Log, [int]$ExitCode) {
    $errorLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Log -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed -match '^frame=') { continue }
        if ($trimmed -match '(?i)(error|failed|invalid|cannot|unable|outside|broken|拒絕|失敗|錯誤)') {
            $errorLines.Add($trimmed)
        }
    }
    if ($errorLines.Count -eq 0) {
        return "FFmpeg 錄影程序意外結束（結束代碼：$ExitCode），紀錄中沒有可辨識的錯誤原因。"
    }
    $startIndex = [Math]::Max(0, $errorLines.Count - 10)
    $lastLines = @($errorLines | Select-Object -Skip $startIndex)
    return "FFmpeg 錄影程序意外結束（結束代碼：$ExitCode）。`r`n`r`n" + ($lastLines -join "`r`n")
}

function Format-RecordingDuration([TimeSpan]$Duration) {
    return "{0:00}:{1:00}:{2:00}" -f [int]$Duration.TotalHours, $Duration.Minutes, $Duration.Seconds
}

function Reset-RecordingSessionUi {
    Stop-VoiceCaptures
    Stop-LoopbackCaptures
    Hide-ProcessingProgress
    $script:Recording = $false
    $script:Paused = $false
    $script:PendingAction = ""
    $script:RecorderProcess = $null
    $script:ErrorTask = $null
    $script:CurrentSegmentPath = $null
    $script:RecordingDevices = @()
    $script:RecordingSegments.Clear()
    $script:SessionDirectory = $null
    $script:RecordingStopwatch.Reset()
    $script:StopRequestedAt = [DateTime]::MinValue
    $script:StopWaitNoticeShown = $false
    $script:StopForced = $false
    $timerLabel.Text = "00:00:00"
    $overlayLabel.Text = "00:00:00"
    $record.Enabled = $true
    Set-RecordingControls $false
    Update-TransportControls
    $selector.Show()
    $selector.BringToFront()
}

function Start-RecordingSegment {
    $path = Find-FFmpeg $ffmpegPath.Text
    if (-not $path) { return $false }
    $segmentNumber = $script:RecordingSegments.Count + 1
    # Matroska writes its recording metadata incrementally and closes much
    # faster than a normal MP4 if the encoder has to stop unexpectedly.
    $segmentPath = Join-Path $script:SessionDirectory ("segment_{0:D4}.mkv" -f $segmentNumber)
    try {
        Start-LoopbackCaptures $script:RecordingDevices
        Start-VoiceCaptures $script:RecordingDevices $path
        $arguments = Build-RecorderArguments $script:RecordingDevices $segmentPath
    }
    catch {
        Stop-VoiceCaptures
        Stop-LoopbackCaptures
        [System.Windows.Forms.MessageBox]::Show($recordingOverlay, $_.Exception.Message, "錄影來源無效", "OK", "Error") | Out-Null
        return $false
    }

    if ($selector.Visible) {
        $selector.Hide()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 250
    }

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $path
    $info.Arguments = $arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardError = $true
    Use-Utf8StandardError $info
    try {
        $script:RecorderProcess = [System.Diagnostics.Process]::Start($info)
        try { $script:RecorderProcess.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::AboveNormal } catch {}
        $script:ErrorTask = $script:RecorderProcess.StandardError.ReadToEndAsync()
        Wait-LoopbackCaptures
        Wait-VoiceCaptures
        $script:CurrentSegmentPath = $segmentPath
        $script:Recording = $true
        $script:Paused = $false
        $script:PendingAction = ""
        $script:StartedAt = [DateTime]::Now
        $script:StopRequestedAt = [DateTime]::MinValue
        $script:StopWaitNoticeShown = $false
        $script:StopForced = $false
        $script:RecordingStopwatch.Start()
        $record.Enabled = $true
        Set-RecordingControls $true
        Update-TransportControls
        Show-RecordingOverlay
        $status.Text = "錄影中（片段 $segmentNumber）：$($script:LastOutput)"
        return $true
    }
    catch {
        if ($script:RecorderProcess -and -not $script:RecorderProcess.HasExited) {
            try { $script:RecorderProcess.StandardInput.WriteLine("q") } catch {}
            try {
                if (-not $script:RecorderProcess.WaitForExit(2000)) { $script:RecorderProcess.Kill() }
            } catch {}
        }
        Stop-VoiceCaptures
        Stop-LoopbackCaptures
        $script:Recording = $false
        $script:Paused = ($script:RecordingSegments.Count -gt 0)
        $script:CurrentSegmentPath = $null
        Update-TransportControls
        [System.Windows.Forms.MessageBox]::Show($recordingOverlay, $_.Exception.Message, "FFmpeg 啟動失敗", "OK", "Error") | Out-Null
        return $false
    }
}

function Start-Recording {
    if ($script:Recording -or $script:Paused) { return }
    $path = Find-FFmpeg $ffmpegPath.Text
    if (-not $path) {
        [System.Windows.Forms.MessageBox]::Show($recordingOverlay, "找不到 FFmpeg，請先完成安裝或選擇 ffmpeg.exe。", "無法開始", "OK", "Error") | Out-Null
        return
    }
    $folder = $outputPath.Text.Trim()
    try { [System.IO.Directory]::CreateDirectory($folder) | Out-Null }
    catch {
        [System.Windows.Forms.MessageBox]::Show($recordingOverlay, $_.Exception.Message, "儲存資料夾無效", "OK", "Error") | Out-Null
        return
    }
    $devices = New-Object System.Collections.Generic.List[object]
    foreach ($combo in @($audioOne, $audioTwo)) {
        if ($combo.SelectedItem -and $combo.SelectedItem.ToString() -ne $script:NoAudio) {
            $displayName = $combo.SelectedItem.ToString()
            if (-not $script:AudioDeviceMap.ContainsKey($displayName)) {
                [System.Windows.Forms.MessageBox]::Show($recordingOverlay, "選取的音訊裝置已失效，請重新偵測。", "找不到音訊裝置", "OK", "Error") | Out-Null
                return
            }
            $selectedDevice = $script:AudioDeviceMap[$displayName]
            if (@($devices | Where-Object { $_.Backend -eq $selectedDevice.Backend -and $_.Name -eq $selectedDevice.Name }).Count -gt 0) {
                [System.Windows.Forms.MessageBox]::Show($recordingOverlay, "音訊來源 1 與音訊來源 2 不可選擇相同裝置。", "音訊來源重複", "OK", "Error") | Out-Null
                return
            }
            $devices.Add($selectedDevice)
        }
    }
    foreach ($device in $devices) {
        $status.Text = "正在確認音訊裝置：$($device.Display)…"
        $recordingOverlay.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        [System.Windows.Forms.Application]::DoEvents()
        $audioTest = Test-AudioDevice $path $device
        $recordingOverlay.Cursor = [System.Windows.Forms.Cursors]::Default
        if (-not $audioTest.Success) {
            $details = $audioTest.Error
            if ($details.Length -gt 2500) { $details = $details.Substring($details.Length - 2500) }
            [System.Windows.Forms.MessageBox]::Show($recordingOverlay, "無法開啟所選音訊裝置。請確認 Windows 麥克風權限，並關閉可能獨佔該裝置的程式。`r`n`r`n$details", "音訊裝置測試失敗", "OK", "Error") | Out-Null
            $status.Text = "音訊裝置無法使用；尚未開始錄影。"
            return
        }
        $device.SampleRate = $audioTest.SampleRate
        if ($audioTest.PSObject.Properties["Channels"] -and $audioTest.Channels) { $device.Channels = $audioTest.Channels }
        if ($audioTest.PSObject.Properties["InputFormat"] -and $audioTest.InputFormat) { $device.InputFormat = $audioTest.InputFormat }
    }

    $script:LastOutput = Join-Path $folder ("螢幕錄影_{0}.mp4" -f [DateTime]::Now.ToString("yyyyMMdd_HHmmss"))
    $script:SessionDirectory = Join-Path $folder (".錄影暫存_" + [Guid]::NewGuid().ToString("N"))
    try { [System.IO.Directory]::CreateDirectory($script:SessionDirectory) | Out-Null }
    catch {
        [System.Windows.Forms.MessageBox]::Show($recordingOverlay, $_.Exception.Message, "無法建立錄影暫存資料夾", "OK", "Error") | Out-Null
        return
    }
    $script:RecordingDevices = @($devices.ToArray())
    $script:RecordingSegments.Clear()
    $script:RecordingStopwatch.Reset()
    Set-RecordingControls $true
    if (-not (Start-RecordingSegment)) {
        if ((Test-Path -LiteralPath $script:SessionDirectory) -and @(Get-ChildItem -LiteralPath $script:SessionDirectory -Force).Count -eq 0) {
            [System.IO.Directory]::Delete($script:SessionDirectory, $false)
        }
        Reset-RecordingSessionUi
    }
}

function Pause-Recording {
    if ($script:Paused -and [string]::IsNullOrEmpty($script:PendingAction)) {
        $status.Text = "正在繼續錄影…"
        if (-not (Start-RecordingSegment)) {
            $status.Text = "無法繼續錄影；已保留先前片段，可按停止進行合併。"
        }
        return
    }
    if ($script:Recording -and $script:RecorderProcess -and -not $script:RecorderProcess.HasExited -and [string]::IsNullOrEmpty($script:PendingAction)) {
        $script:PendingAction = "Pause"
        $script:RecordingStopwatch.Stop()
        $status.Text = "正在暫停並完成目前片段…"
        Show-ProcessingProgress "正在暫停並封裝目前片段，請稍候…" $true 1
        $miniPause.Enabled = $false
        $miniStop.Enabled = $false
        $record.Enabled = $false
        Request-RecorderProcessStop
    }
}

function Stop-Recording {
    if ($script:Paused -and [string]::IsNullOrEmpty($script:PendingAction)) {
        $script:PendingAction = "Finalize"
        $miniPause.Enabled = $false
        $miniStop.Enabled = $false
        $record.Enabled = $false
        Finalize-RecordingSession
        return
    }
    if ($script:Recording -and $script:RecorderProcess -and -not $script:RecorderProcess.HasExited -and [string]::IsNullOrEmpty($script:PendingAction)) {
        $script:PendingAction = "Finalize"
        $script:RecordingStopwatch.Stop()
        $record.Enabled = $false
        $miniPause.Enabled = $false
        $miniStop.Enabled = $false
        $status.Text = "正在完成目前片段，請稍候…"
        Show-ProcessingProgress "正在封裝目前片段，請稍候…" $true 1
        Request-RecorderProcessStop
    }
}

function Finalize-RecordingSession {
    $segments = @($script:RecordingSegments.ToArray())
    $sessionDirectory = $script:SessionDirectory
    $recordedDuration = $script:RecordingStopwatch.Elapsed
    $recordedDurationText = Format-RecordingDuration $recordedDuration
    $success = $false
    $mergeError = ""
    if ($segments.Count -le 1) {
        $status.Text = "正在快速封裝 MP4（不重新編碼）…"
        $overlayLabel.Text = "快速封裝…"
        Update-ProcessingProgress "正在快速封裝 MP4（不重新編碼）…" 25
    }
    else {
        $status.Text = "正在快速合併 $($segments.Count) 個片段（不重新編碼）…"
        $overlayLabel.Text = "快速合併…"
        Update-ProcessingProgress "正在快速合併 $($segments.Count) 個片段（不重新編碼）…" 25
    }
    [System.Windows.Forms.Application]::DoEvents()
    try {
        if ($segments.Count -eq 0) { throw "沒有可儲存的錄影片段。" }
        [long]$totalSegmentBytes = 0
        foreach ($segment in $segments) {
            if (Test-Path -LiteralPath $segment) { $totalSegmentBytes += (Get-Item -LiteralPath $segment).Length }
        }
        $processingMessage = if ($segments.Count -eq 1) { "正在快速封裝 MP4（不重新編碼）…" } else { "正在快速合併 $($segments.Count) 個片段（不重新編碼）…" }
        $concatPath = Join-Path $sessionDirectory "concat.txt"
        [string[]]$concatLines = @(Get-ConcatListLines $segments)
        [System.IO.File]::WriteAllLines($concatPath, $concatLines, (New-Object System.Text.UTF8Encoding($false)))
        $mergeInfo = New-Object System.Diagnostics.ProcessStartInfo
        $mergeInfo.FileName = (Find-FFmpeg $ffmpegPath.Text)
        $mergeInfo.Arguments = Build-ConcatArguments $concatPath $script:LastOutput
        $mergeInfo.UseShellExecute = $false
        $mergeInfo.CreateNoWindow = $true
        $mergeInfo.RedirectStandardError = $true
        Use-Utf8StandardError $mergeInfo
        $mergeProcess = [System.Diagnostics.Process]::Start($mergeInfo)
        try { $mergeProcess.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::AboveNormal } catch {}
        $mergeErrorTask = $mergeProcess.StandardError.ReadToEndAsync()
        $lastProgress = 25
        while (-not $mergeProcess.HasExited) {
            try {
                if ($totalSegmentBytes -gt 0 -and (Test-Path -LiteralPath $script:LastOutput)) {
                    $outputBytes = (Get-Item -LiteralPath $script:LastOutput).Length
                    $mergeProgress = [Math]::Min(95, [Math]::Max(25, (25 + [int](($outputBytes * 70.0) / $totalSegmentBytes))))
                    if ($mergeProgress -ne $lastProgress) {
                        $lastProgress = $mergeProgress
                        Update-ProcessingProgress $processingMessage $mergeProgress
                    }
                }
            } catch {}
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 50
        }
        $mergeError = $mergeErrorTask.Result
        if ($mergeProcess.ExitCode -ne 0) { throw $mergeError }
        Update-ProcessingProgress "影片檔案已完成，正在驗證…" 95
        $success = (Test-Path -LiteralPath $script:LastOutput) -and ((Get-Item -LiteralPath $script:LastOutput).Length -gt 0)
        if (-not $success) { throw "合併完成後找不到有效的 MP4 檔案。" }
        Update-ProcessingProgress "影片處理完成。" 100
        Start-Sleep -Milliseconds 120
    }
    catch {
        if ([string]::IsNullOrWhiteSpace($mergeError)) { $mergeError = $_.Exception.Message }
    }

    if ($success) {
        foreach ($segment in $segments) {
            if (Test-Path -LiteralPath $segment) { [System.IO.File]::Delete($segment) }
        }
        $concatPath = Join-Path $sessionDirectory "concat.txt"
        if (Test-Path -LiteralPath $concatPath) { [System.IO.File]::Delete($concatPath) }
        if ((Test-Path -LiteralPath $sessionDirectory) -and @(Get-ChildItem -LiteralPath $sessionDirectory -Force).Count -eq 0) {
            [System.IO.Directory]::Delete($sessionDirectory, $false)
        }
    }

    $temporaryLocation = $sessionDirectory
    Reset-RecordingSessionUi
    if ($success) {
        $status.Text = "錄影完成；計時已歸零。已儲存：$($script:LastOutput)"
        if (-not $script:CloseAfterStop -and $env:RECORDER_PAUSE_DIAGNOSTICS -ne "1") {
            $completionMessage = "錄影已停止並完成儲存。`r`n`r`n錄製時間：$recordedDurationText`r`n計時器：已重新歸零為 00:00:00`r`n儲存位置：$($script:LastOutput)"
            [System.Windows.Forms.MessageBox]::Show($recordingOverlay, $completionMessage, "錄影完成", "OK", "Information") | Out-Null
        }
    }
    else {
        $status.Text = "錄影合併失敗；計時已歸零，原始片段保留於：$temporaryLocation"
        if ($mergeError.Length -gt 7000) { $mergeError = $mergeError.Substring($mergeError.Length - 7000) }
        [System.Windows.Forms.MessageBox]::Show($recordingOverlay, "$mergeError`r`n`r`n計時器已重新歸零。`r`n原始片段保留於：$temporaryLocation", "錄影儲存失敗", "OK", "Error") | Out-Null
    }
    if ($script:CloseAfterStop) { $main.Close() }
}

function Complete-Recording {
    Stop-VoiceCaptures
    Stop-LoopbackCaptures
    $action = $script:PendingAction
    $exitCode = $script:RecorderProcess.ExitCode
    $errorLog = if ($script:ErrorTask) { $script:ErrorTask.Result } else { "" }
    $segmentPath = $script:CurrentSegmentPath
    $script:Recording = $false
    $script:RecordingStopwatch.Stop()
    $validFile = $segmentPath -and (Test-Path -LiteralPath $segmentPath) -and ((Get-Item -LiteralPath $segmentPath).Length -gt 0)
    $recoveredSegment = $false
    if ($exitCode -ne 0 -and $validFile) {
        $status.Text = "錄影程序異常結束，正在檢查並搶救片段…"
        Update-ProcessingProgress "正在檢查可搶救的錄影片段…" 25
        [System.Windows.Forms.Application]::DoEvents()
        $recoveredSegment = Test-RecordingSegmentReadable $segmentPath
    }
    if (($exitCode -eq 0 -or $recoveredSegment) -and $validFile) {
        $script:RecordingSegments.Add($segmentPath)
        $script:RecorderProcess = $null
        $script:ErrorTask = $null
        $script:CurrentSegmentPath = $null
        if ($action -eq "Pause") {
            $script:Paused = $true
            $script:PendingAction = ""
            $record.Enabled = $true
            if ($script:CloseAfterStop) {
                $script:PendingAction = "Finalize"
                Finalize-RecordingSession
            }
            else {
                Hide-ProcessingProgress
                $status.Text = "已暫停；按「▶ 繼續」接續錄影，或按「停止」合併並儲存。"
                Update-TransportControls
            }
        }
        else {
            Finalize-RecordingSession
        }
        return
    }

    $temporaryLocation = $script:SessionDirectory
    $errorLogPath = $null
    if ($temporaryLocation -and (Test-Path -LiteralPath $temporaryLocation)) {
        try {
            $errorLogPath = Join-Path $temporaryLocation ("ffmpeg_error_{0}.log" -f [DateTime]::Now.ToString("yyyyMMdd_HHmmss"))
            [System.IO.File]::WriteAllText($errorLogPath, $errorLog, (New-Object System.Text.UTF8Encoding($false)))
        } catch { $errorLogPath = $null }
    }
    $errorSummary = Get-FFmpegErrorSummary $errorLog $exitCode
    Reset-RecordingSessionUi
    $status.Text = "錄影失敗；計時已歸零，已完成的片段保留於：$temporaryLocation"
    $logMessage = if ($errorLogPath) { "`r`n完整錯誤紀錄：$errorLogPath" } else { "" }
    [System.Windows.Forms.MessageBox]::Show($recordingOverlay, "$errorSummary`r`n`r`n計時器已重新歸零。`r`n可用片段保留於：$temporaryLocation$logMessage", "錄影失敗", "OK", "Error") | Out-Null
    if ($script:CloseAfterStop) { $main.Close() }
}

$uiTimer = New-Object System.Windows.Forms.Timer
$uiTimer.Interval = 250
$uiTimer.Add_Tick({
    $dateTimeLabel.Text = [DateTime]::Now.ToString("yyyy年MM月dd日 HH:mm:ss")
    if ($script:Recording -or $script:Paused) {
        $elapsed = $script:RecordingStopwatch.Elapsed
        $elapsedText = "{0:00}:{1:00}:{2:00}" -f [int]$elapsed.TotalHours, $elapsed.Minutes, $elapsed.Seconds
        $timerLabel.Text = $elapsedText
        if ($script:PendingAction -notin @("Pause", "Finalize")) { $overlayLabel.Text = $elapsedText }
        if ($script:Recording -and $script:PendingAction -in @("Pause", "Finalize") -and $script:RecorderProcess -and -not $script:RecorderProcess.HasExited -and $processingForm.Visible) {
            if ($processingBar.Value -lt 24) {
                Update-ProcessingProgress $script:ProcessingMessage ([Math]::Min(24, ($processingBar.Value + 1)))
            }
            $stopWait = [DateTime]::UtcNow - $script:StopRequestedAt
            if ($stopWait.TotalSeconds -ge 6 -and -not $script:StopWaitNoticeShown) {
                $script:StopWaitNoticeShown = $true
                $status.Text = "FFmpeg 正在結束輸入；若未回應，程式會自動保全目前片段。"
                Update-ProcessingProgress "正在等待 FFmpeg 完成片段…" 24
            }
            if ($stopWait.TotalSeconds -ge 10 -and -not $script:StopForced) {
                $script:StopForced = $true
                $status.Text = "FFmpeg 停止逾時，正在保全並搶救目前片段…"
                Update-ProcessingProgress "停止逾時，正在搶救可用片段…" 24
                try { $script:RecorderProcess.Kill() } catch {}
            }
        }
        if ($script:Recording -and $script:RecorderProcess.HasExited) { Complete-Recording }
    }
})
$uiTimer.Start()

$refresh.Add_Click({ Refresh-AudioDevices })
$record.Add_Click({ if ($script:Recording -or $script:Paused) { Stop-Recording } else { Start-Recording } })
$miniRecord.Add_Click({ Start-Recording })
$miniPause.Add_Click({ Pause-Recording })
$miniStop.Add_Click({ Stop-Recording })
$customSelect.Add_Click({ Start-CustomSelection })
$screenshotButton.Add_Click({ Capture-Screenshot })
$fitScreen.Add_Click({
    $targetScreen = [System.Windows.Forms.Screen]::FromRectangle($selector.Bounds)
    $script:SuppressCaptureSizeStatus = $true
    try { $selector.Bounds = $targetScreen.Bounds }
    finally { $script:SuppressCaptureSizeStatus = $false }
    Set-CaptureSizeStatus $false
    $selector.Show()
    $selector.BringToFront()
    $main.BringToFront()
})
$browseOutput.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.SelectedPath = $outputPath.Text
    if ($dialog.ShowDialog($main) -eq "OK") { $outputPath.Text = $dialog.SelectedPath }
    $dialog.Dispose()
})
$browseFFmpeg.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "FFmpeg 執行檔|ffmpeg.exe|執行檔|*.exe"
    if ($dialog.ShowDialog($main) -eq "OK") { $ffmpegPath.Text = $dialog.FileName; Refresh-AudioDevices }
    $dialog.Dispose()
})
$installFFmpeg.Add_Click({
    $detectedFFmpeg = Find-FFmpeg $ffmpegPath.Text
    if ($detectedFFmpeg) {
        $ffmpegPath.Text = $detectedFFmpeg
        [System.Windows.Forms.MessageBox]::Show($main, "FFmpeg已安裝。", "FFmpeg偵測安裝", "OK", "Information") | Out-Null
        return
    }
    $installFFmpeg.Enabled = $false
    $main.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $script:LastFFmpegInstallError = ""
        $installedFFmpeg = Install-BundledFFmpeg "" @()
        if ($installedFFmpeg) {
            $ffmpegPath.Text = $installedFFmpeg
            [System.Windows.Forms.MessageBox]::Show($main, "FFmpeg安裝完成。", "FFmpeg偵測安裝", "OK", "Information") | Out-Null
        }
        else {
            $details = if ($script:LastFFmpegInstallError) { "`r`n`r`n$($script:LastFFmpegInstallError)" } else { "" }
            [System.Windows.Forms.MessageBox]::Show($main, "找不到可用的本機安裝來源，請重新執行 JH錄影程式安裝檔_v$($script:AppVersion).exe。$details", "FFmpeg安裝失敗", "OK", "Error") | Out-Null
        }
    }
    finally {
        $main.Cursor = [System.Windows.Forms.Cursors]::Default
        $installFFmpeg.Enabled = $true
    }
})
$openFolder.Add_Click({
    try {
        [System.IO.Directory]::CreateDirectory($outputPath.Text) | Out-Null
        Start-Process "explorer.exe" -ArgumentList ('"' + $outputPath.Text + '"')
    } catch { $status.Text = $_.Exception.Message }
})
$main.Add_FormClosing({
    if ($script:Recording -or $script:Paused) {
        $answer = [System.Windows.Forms.MessageBox]::Show($main, "要停止錄影、完成 MP4 檔案後離開嗎？", "仍在錄影", "YesNo", "Question")
        if ($answer -ne "Yes") { $_.Cancel = $true; return }
        $_.Cancel = $true
        $script:CloseAfterStop = $true
        Stop-Recording
    }
})
$main.Add_FormClosed({
    Dispose-SelectionBitmap
    $uiTimer.Stop()
    $toolbarTip.Dispose()
    $selectionOverlay.Dispose()
    $processingForm.Dispose()
    $recordingOverlay.Dispose()
    $selector.Dispose()
    if ($script:AppIcon) {
        $script:AppIcon.Dispose()
        $script:AppIcon = $null
    }
    if ($script:InstanceMutex) {
        try { $script:InstanceMutex.ReleaseMutex() } catch {}
        $script:InstanceMutex.Dispose()
        $script:InstanceMutex = $null
    }
})
$main.Add_Shown({
    $selector.Show()
    Show-RecordingOverlay
    $main.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $main.BringToFront()
    $main.Activate()
})

$foundFFmpeg = Find-FFmpeg ""
if ($foundFFmpeg) {
    $ffmpegPath.Text = $foundFFmpeg
    Refresh-AudioDevices
    $status.Text += "　已自動偵測主螢幕：$($screenArea.Width) × $($screenArea.Height)。"
}
else {
    $audioOne.Items.Add($script:NoAudio) | Out-Null
    $audioTwo.Items.Add($script:NoAudio) | Out-Null
    $audioOne.SelectedIndex = 0
    $audioTwo.SelectedIndex = 0
    $status.Text = "找不到內附的 FFmpeg，請重新安裝程式或手動選擇執行檔。"
}

if ($SmokeTest) {
    if ($installFFmpeg.Text -ne "偵測安裝") {
        throw "FFmpeg 離線模式煙霧測試失敗。"
    }
    if ($dateTimeLabel.Text -notmatch '^\d{4}年\d{2}月\d{2}日 \d{2}:\d{2}:\d{2}$') {
        throw "左上角日期時間顯示煙霧測試失敗。"
    }
    if ($dateTimeLabel.Font.Size -lt 15 -or $dateTimeLabel.PreferredSize.Width -gt $dateTimeLabel.Width) {
        throw "左上角日期時間字體或寬度煙霧測試失敗。"
    }
    if ($main.ClientSize.Width -ne 690 -or $main.ClientSize.Height -ne 575) {
        throw "主設定視窗內容區大小煙霧測試失敗。"
    }
    if ($main.ClientRectangle.Right -lt 690 -or $main.ClientRectangle.Bottom -lt 575 -or $captureSizeStatus.Bottom -gt $main.ClientSize.Height -or $fitScreen.Right -gt $main.ClientSize.Width) {
        throw "主設定視窗元件超出內容區煙霧測試失敗。"
    }
    if (($main.ClientSize.Height - $captureSizeStatus.Bottom) -gt 10) {
        throw "主設定視窗底部留白過多煙霧測試失敗。"
    }
    $expectedAutomaticFps = (Get-RecommendedFrameRate).ToString()
    if ($fps.SelectedItem -ne $expectedAutomaticFps -or $fpsLabel.Text -ne "幀數" -or $script:FrameRateManuallySelected) {
        throw "依設備自動選擇 FPS 煙霧測試失敗。"
    }
    $autoFpsTestBounds = $selector.Bounds
    $selector.Size = New-Object System.Drawing.Size(1280, 720)
    $expectedSmallAreaFps = (Get-RecommendedFrameRate).ToString()
    if ($fps.SelectedItem -ne $expectedSmallAreaFps) { throw "錄影範圍變更後自動調整 FPS 煙霧測試失敗。" }
    $selector.Bounds = $autoFpsTestBounds
    if ($fps.SelectedItem -ne $expectedAutomaticFps) { throw "恢復錄影範圍後自動調整 FPS 煙霧測試失敗。" }
    $expectedAutomaticSize = "偵測視窗大小: $($selector.Width)*$($selector.Height)"
    if ($captureSizeStatus.Text -ne $expectedAutomaticSize -or $captureSizeStatus.Parent -ne $main -or $status.Parent) {
        throw "底部自動偵測尺寸文字煙霧測試失敗。"
    }
    Set-CaptureSizeStatus $true
    if ($captureSizeStatus.Text -ne "偵測視窗大小: $($selector.Width)*$($selector.Height)") {
        throw "底部手動調整尺寸文字煙霧測試失敗。"
    }
    Set-CaptureSizeStatus $false
    $testDevices = @(
        [PSCustomObject]@{ Backend = "dshow"; Name = "Microphone Test"; VoiceFiltered = $true; PipePath = "\\.\pipe\VoiceFilterSmoke1"; InputFormat = "s16le"; SampleRate = 48000; Channels = 1 },
        [PSCustomObject]@{ Backend = "openal"; Name = "OpenAL Soft on Microphone Test"; VoiceFiltered = $true; PipePath = "\\.\pipe\VoiceFilterSmoke2"; InputFormat = "s16le"; SampleRate = 48000; Channels = 1 }
    )
    $testArguments = Build-RecorderArguments $testDevices (Join-Path $script:ProjectRoot "smoke test.mp4")
    if ($testArguments -notmatch "amix=inputs=2" -or $testArguments -notmatch "alimiter=limit=0.80" -or $testArguments -notmatch 'VoiceFilterSmoke1' -or $testArguments -notmatch 'VoiceFilterSmoke2') {
        throw "錄影指令煙霧測試失敗。"
    }
    if ($testArguments -notmatch 'asetpts=N/SR/TB' -or $testArguments -notmatch '-thread_queue_size 4096' -or $testArguments -notmatch '-max_muxing_queue_size 4096') {
        throw "音訊連續性保護煙霧測試失敗。"
    }
    if (-not $script:VoiceFilterAvailable -or -not $noiseSuppression.Checked -or $noiseSuppression.Text -ne "只錄製人聲（RNNoise＋VAD）" -or $testArguments -match 'afftdn=' -or $testArguments -match 'agate=') {
        throw "RNNoise＋WebRTC VAD 人聲模式煙霧測試失敗。"
    }
    $systemOnlyTestDevice = @([PSCustomObject]@{ Backend = "wasapi-loopback"; Name = "DefaultPlayback"; PipePath = "\\.\pipe\NoiseSuppressionSmokeTest"; InputFormat = "f32le"; SampleRate = 48000; Channels = 2 })
    $systemOnlyArguments = Build-RecorderArguments $systemOnlyTestDevice (Join-Path $script:ProjectRoot "system audio smoke test.mp4")
    if ($systemOnlyArguments -match 'afftdn=' -or $systemOnlyArguments -match 'agate=' -or $systemOnlyArguments -match 'VoiceFilter') {
        throw "系統播放音訊不應套用麥克風人聲過濾。"
    }
    $expectedDefaultQueue = if ($fps.SelectedItem -eq "60") { "256" } else { "128" }
    if ($testArguments -notmatch "-thread_queue_size $expectedDefaultQueue -rtbufsize 512M -f gdigrab") {
        throw "自動 FPS 影像佇列煙霧測試失敗。"
    }
    if (($selector.Width * $selector.Height) -ge (1920 * 1080) -and $testArguments -notmatch '-preset superfast') {
        throw "Full HD 即時編碼保護煙霧測試失敗。"
    }
    if ($testArguments -match '-f openal -use_wallclock_as_timestamps' -or $testArguments -match '-use_wallclock_as_timestamps 1 -f openal') {
        throw "OpenAL 時間戳保護煙霧測試失敗。"
    }
    $savedFps = $fps.SelectedItem
    $script:FrameRateSelectionInternal = $true
    try {
        $fps.SelectedItem = "60"
        $highLoadArguments = Build-RecorderArguments $testDevices (Join-Path $script:ProjectRoot "smoke test.mp4")
        $fps.SelectedItem = $savedFps
    }
    finally { $script:FrameRateSelectionInternal = $false }
    if ($highLoadArguments -notmatch '-preset superfast') { throw "全螢幕 60 FPS 即時編碼保護煙霧測試失敗。" }
    if ($highLoadArguments -notmatch '-thread_queue_size 256 -rtbufsize 512M -f gdigrab') {
        throw "60 FPS 短影像佇列煙霧測試失敗。"
    }
    $directOpenAlDevice = @([PSCustomObject]@{ Backend = "openal"; Name = "OpenAL Soft on Microphone Test"; SampleRate = 48000; Channels = 1 })
    $directOpenAlArguments = Build-RecorderArguments $directOpenAlDevice (Join-Path $script:ProjectRoot "direct microphone smoke test.mp4")
    if ($directOpenAlArguments -notmatch '-f openal -channels 1 -sample_rate 48000 -sample_size 16') {
        throw "OpenAL 單聲道格式煙霧測試失敗。"
    }
    if (-not $script:WasapiLoopbackAvailable) { throw "WASAPI 系統音訊元件載入失敗：$($script:WasapiLoopbackError)" }
    $loopbackFormat = [RecorderLoopbackPipe]::Probe()
    $loopbackDevice = [PSCustomObject]@{
        Backend = "wasapi-loopback"
        Name = "DefaultPlayback"
        PipePath = "\\.\pipe\RecorderSmokeTest"
        InputFormat = $loopbackFormat.InputFormat
        SampleRate = $loopbackFormat.SampleRate
        Channels = $loopbackFormat.Channels
    }
    $loopbackArguments = Build-RecorderArguments @($loopbackDevice) (Join-Path $script:ProjectRoot "smoke loopback.mp4")
    if ($loopbackArguments -notmatch '-f f32le' -or $loopbackArguments -notmatch '-ar 48000' -or $loopbackArguments -notmatch 'RecorderSmokeTest') {
        throw "WASAPI 系統播放音訊指令煙霧測試失敗。"
    }
    $voicePipelineResult = Test-VoiceFilterPipeline $ffmpegPath.Text
    if (-not $voicePipelineResult.Success -or $voicePipelineResult.TotalBytes -ne 96000 -or $voicePipelineResult.SilentFrames -ne 50) {
        throw "RNNoise＋WebRTC VAD 連續管線測試失敗：$($voicePipelineResult.Error)"
    }
    $concatArguments = Build-ConcatArguments "C:\測試 路徑\concat.txt" "C:\測試 路徑\完成影片.mp4"
    if ($concatArguments -notmatch '-f concat' -or $concatArguments -notmatch '-c copy' -or $concatArguments -match 'faststart' -or $concatArguments -notmatch '"C:\\測試 路徑\\完成影片.mp4"') {
        throw "暫停片段無損合併指令煙霧測試失敗。"
    }
    if ($testArguments -match 'faststart') { throw "停止後快速處理煙霧測試失敗。" }
    if ((Format-RecordingDuration ([TimeSpan]::FromSeconds(3661))) -ne "01:01:01") {
        throw "錄影完成時間格式煙霧測試失敗。"
    }
    $errorSummaryTest = Get-FFmpegErrorSummary "frame= 120 fps=30`r`nError opening input: Invalid argument" 1
    if ($errorSummaryTest -notmatch 'Error opening input' -or $errorSummaryTest -match 'frame=') {
        throw "FFmpeg 精簡錯誤訊息煙霧測試失敗。"
    }
    [string[]]$concatLines = @(Get-ConcatListLines @("C:\測試 路徑\segment 1.mp4", "C:\測試 路徑\segment 2.mp4"))
    if ($concatLines.Count -ne 2 -or $concatLines[0] -ne "file 'C:/測試 路徑/segment 1.mp4'") {
        throw "暫停片段清單煙霧測試失敗。"
    }
    $originalBounds = $selector.Bounds
    $virtualDesktop = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $selector.Bounds = New-Object System.Drawing.Rectangle(($virtualDesktop.Left - 9), ($virtualDesktop.Top - 9), ($virtualDesktop.Width + 18), ($virtualDesktop.Height + 18))
    $edgeCapture = Get-CaptureRectangle
    if ($edgeCapture.Left -lt $virtualDesktop.Left -or $edgeCapture.Top -lt $virtualDesktop.Top -or $edgeCapture.Right -gt $virtualDesktop.Right -or $edgeCapture.Bottom -gt $virtualDesktop.Bottom) {
        throw "全螢幕錄影範圍邊界煙霧測試失敗。"
    }
    $selector.Bounds = $originalBounds
    $primaryBounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $selector.Bounds = $primaryBounds
    $fullScreenCapture = Get-CaptureRectangle
    if ($fullScreenCapture.Left -ne $primaryBounds.Left -or $fullScreenCapture.Top -ne $primaryBounds.Top -or $fullScreenCapture.Width -gt $primaryBounds.Width -or $fullScreenCapture.Height -gt $primaryBounds.Height) {
        throw "主螢幕大小自動偵測煙霧測試失敗。"
    }
    $selector.Bounds = $originalBounds
    if ($selector.TransparencyKey -ne [System.Drawing.Color]::Fuchsia -or $selector.Opacity -ne 1.0) {
        throw "錄影範圍透明化煙霧測試失敗。"
    }
    if ($selector.FormBorderStyle -ne [System.Windows.Forms.FormBorderStyle]::None -or $selectorTopBorder.BackColor -ne [System.Drawing.Color]::Red -or $selectorBottomBorder.BackColor -ne [System.Drawing.Color]::Red -or $selectorLeftBorder.BackColor -ne [System.Drawing.Color]::Red -or $selectorRightBorder.BackColor -ne [System.Drawing.Color]::Red) {
        throw "無標題列紅色錄影範圍煙霧測試失敗。"
    }
    if ($selector.TopMost -or $main.TopMost) { throw "視窗分層煙霧測試失敗。" }
    $dragRectangle = Get-NormalizedSelectionRectangle (New-Object System.Drawing.Point(300, 200)) (New-Object System.Drawing.Point(100, 50))
    if ($dragRectangle.X -ne 100 -or $dragRectangle.Y -ne 50 -or $dragRectangle.Width -ne 200 -or $dragRectangle.Height -ne 150) {
        throw "自訂拖曳框選幾何煙霧測試失敗。"
    }
    if ($selectionOverlay.FormBorderStyle -ne "None" -or -not $selectionOverlay.TopMost -or $selectionOverlay.Cursor -ne [System.Windows.Forms.Cursors]::Cross) {
        throw "自訂框選畫面煙霧測試失敗。"
    }
    $selectionDesktop = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $selectionTestSource = New-Object System.Drawing.Bitmap($selectionDesktop.Width, $selectionDesktop.Height)
    try {
        $main.Show()
        $selector.Show()
        Show-RecordingOverlay
        Start-SelectionOverlay "screenshot" $selectionTestSource
        if ($main.Visible -or $selector.Visible -or $recordingOverlay.Visible -or -not $selectionOverlay.Visible -or $script:SelectionPurpose -ne "screenshot") {
            throw "截圖框選時隱藏錄影介面煙霧測試失敗：Main=$($main.Visible) Selector=$($selector.Visible) Toolbar=$($recordingOverlay.Visible) Overlay=$($selectionOverlay.Visible) Purpose=$($script:SelectionPurpose)"
        }
        Cancel-CustomSelection
        if (-not $main.Visible -or -not $selector.Visible -or -not $recordingOverlay.Visible -or $selectionOverlay.Visible -or $script:SelectionPurpose -ne "recording") {
            throw "取消截圖後恢復介面煙霧測試失敗。"
        }
    }
    finally {
        $selectionTestSource.Dispose()
        $selectionOverlay.Hide()
        Dispose-SelectionBitmap
    }
    $selectionOverlay.Size = New-Object System.Drawing.Size(400, 300)
    $script:SelectionBitmap = New-Object System.Drawing.Bitmap(400, 300)
    $script:SelectionRectangle = New-Object System.Drawing.Rectangle(50, 50, 200, 120)
    $selectionCrop = Copy-SelectionBitmapRegion $script:SelectionRectangle
    try {
        if ($selectionCrop.Width -ne 200 -or $selectionCrop.Height -ne 120) {
            throw "截圖框選裁切尺寸煙霧測試失敗。"
        }
    }
    finally { $selectionCrop.Dispose() }
    $renderedSelection = New-Object System.Drawing.Bitmap(400, 300)
    try {
        $selectionOverlay.DrawToBitmap($renderedSelection, (New-Object System.Drawing.Rectangle(0, 0, 400, 300)))
    }
    finally {
        $renderedSelection.Dispose()
        Dispose-SelectionBitmap
    }
    Position-RecordingOverlay
    if (-not $recordingOverlay.TopMost -or $recordingOverlay.Width -ne 500 -or $recordingOverlay.Location.X -gt $primaryBounds.Right) {
        throw "迷你錄影工具列位置煙霧測試失敗。"
    }
    if ($toolbarGrip.Cursor -ne [System.Windows.Forms.Cursors]::SizeAll -or $miniPause.Text -notlike "⏸*" -or $miniRecord.Text -notlike "●*" -or $miniStop.Text -notlike "■*") {
        throw "迷你錄影工具列控制項煙霧測試失敗。"
    }
    if ($overlayLabel.Font.Size -gt 13 -or $miniRecord.ForeColor -ne [System.Drawing.Color]::Red -or -not $miniRecord.Font.Bold) {
        throw "迷你錄影工具列紅色粗體樣式煙霧測試失敗。"
    }
    if ($main.WindowState -ne [System.Windows.Forms.FormWindowState]::Normal -or $main.TopMost) {
        throw "主設定視窗啟動前景及可切換煙霧測試失敗。"
    }
    if ($main.FormBorderStyle -ne [System.Windows.Forms.FormBorderStyle]::FixedSingle -or $main.MaximizeBox -or $main.MinimumSize -ne $main.MaximumSize) {
        throw "主設定視窗固定大小煙霧測試失敗。"
    }
    if ($record.Left -le $timerLabel.Right -or $record.Right -ge $openFolder.Left) {
        throw "開始錄影按鈕位置煙霧測試失敗。"
    }
    if ($record.Size -ne $browseFFmpeg.Size -or $record.Size -ne $openFolder.Size -or $record.Left -ne $browseFFmpeg.Left -or $record.Top -ne $openFolder.Top) {
        throw "開始錄影按鈕大小及對齊煙霧測試失敗。"
    }
    if ($screenshotButton.Text -ne "擷取截圖" -or $screenshotButton.Size -ne $record.Size -or $screenshotButton.Right -ge $record.Left -or $screenshotButton.Top -ne $record.Top) {
        throw "獨立截圖按鈕版面煙霧測試失敗。"
    }
    if ($timerLabel.TextAlign -ne [System.Drawing.ContentAlignment]::MiddleCenter) {
        throw "錄製時間置中煙霧測試失敗。"
    }
    $screenshotTestPath = Join-Path ([IO.Path]::GetTempPath()) ("JHCameraScreenshotSmoke_" + [Guid]::NewGuid().ToString("N") + ".png")
    try {
        $screenshotTestRectangle = New-Object System.Drawing.Rectangle(0, 0, 32, 24)
        $screenshotTestSource = New-Object System.Drawing.Bitmap(32, 24)
        try {
            $screenshotTestGraphics = [System.Drawing.Graphics]::FromImage($screenshotTestSource)
            try { $screenshotTestGraphics.Clear([System.Drawing.Color]::CornflowerBlue) }
            finally { $screenshotTestGraphics.Dispose() }
            Save-ScreenRectangleAsPng $screenshotTestRectangle $screenshotTestPath $screenshotTestSource
        }
        finally { $screenshotTestSource.Dispose() }
        if (-not (Test-Path -LiteralPath $screenshotTestPath -PathType Leaf)) { throw "截圖檔案未建立。" }
        $screenshotTestImage = [System.Drawing.Image]::FromFile($screenshotTestPath)
        try {
            if ($screenshotTestImage.Width -ne 32 -or $screenshotTestImage.Height -ne 24 -or $screenshotTestImage.RawFormat.Guid -ne [System.Drawing.Imaging.ImageFormat]::Png.Guid) {
                throw "截圖 PNG 尺寸或格式不正確。"
            }
        }
        finally { $screenshotTestImage.Dispose() }
    }
    finally {
        if (Test-Path -LiteralPath $screenshotTestPath -PathType Leaf) { Remove-Item -LiteralPath $screenshotTestPath -Force }
    }
    Set-RecordingControls $true
    if ($screenshotButton.Enabled) { throw "錄影期間截圖按鈕停用煙霧測試失敗。" }
    Set-RecordingControls $false
    $script:Recording = $true
    $script:Paused = $false
    $script:PendingAction = ""
    Update-TransportControls
    if ($miniRecord.Enabled -or -not $miniPause.Enabled -or -not $miniStop.Enabled) {
        throw "錄影中工具列狀態煙霧測試失敗。"
    }
    $script:Recording = $false
    $script:Paused = $true
    Update-TransportControls
    if ($miniPause.Text -notlike "▶*" -or -not $miniStop.Enabled) {
        throw "暫停中工具列狀態煙霧測試失敗。"
    }
    $script:Paused = $false
    Update-TransportControls
    Show-ProcessingProgress "正在封裝目前片段，請稍候…" $true 7
    if (-not $processingForm.Visible -or $processingBar.Style -ne [System.Windows.Forms.ProgressBarStyle]::Continuous -or $processingBar.Value -ne 7 -or $processingLabel.Text -notmatch '7%') {
        throw "影片封裝百分比進度條煙霧測試失敗。"
    }
    Update-ProcessingProgress "正在快速合併測試片段…" 42
    if ($processingBar.Style -ne [System.Windows.Forms.ProgressBarStyle]::Continuous -or $processingBar.Value -ne 42 -or $processingLabel.Text -notmatch '42%' -or $processingDetail.Text -notmatch '42%') {
        throw "影片合併百分比進度條煙霧測試失敗。"
    }
    Hide-ProcessingProgress
    if ($processingForm.Visible) { throw "影片處理進度條隱藏煙霧測試失敗。" }
    Show-RecordingOverlay
    [System.Windows.Forms.Application]::DoEvents()
    if (-not $recordingOverlay.Visible) { throw "迷你錄影工具列顯示測試失敗。" }
    $recordingOverlay.Hide()
    if ($recordingOverlay.Visible) { throw "迷你錄影工具列隱藏測試失敗。" }
    if ($status.Text -like "音訊裝置偵測失敗：*") { throw $status.Text }
    if ($script:WasapiLoopbackAvailable) {
        $selectedSystemAudio = $script:AudioDeviceMap[$audioOne.SelectedItem.ToString()]
        if (-not $selectedSystemAudio -or $selectedSystemAudio.Backend -ne "wasapi-loopback") {
            throw "系統播放聲音自動選取煙霧測試失敗。"
        }
    }
    $availableMicrophones = @($script:AudioDeviceMap.Values | Where-Object { $_.Backend -in @("dshow", "openal") })
    if ($availableMicrophones.Count -gt 0) {
        $selectedMicrophone = $script:AudioDeviceMap[$audioTwo.SelectedItem.ToString()]
        if (-not $selectedMicrophone -or $selectedMicrophone.Backend -notin @("dshow", "openal")) {
            throw "麥克風自動選取煙霧測試失敗。"
        }
    }
    if ($main.Text -ne "JH Camera錄影程式 v$($script:AppVersion)" -or @($main.Controls | Where-Object { $_ -is [System.Windows.Forms.Label] -and ($_.Text -eq "高畫質螢幕錄影＋錄音" -or $_.Text -like "版本號：v*") }).Count -ne 0) {
        throw "程式名稱與標題移除煙霧測試失敗。"
    }
    if ($dateTimeLabel.Location -ne (New-Object System.Drawing.Point(25, 30)) -or $timerLabel.Location -ne (New-Object System.Drawing.Point(80, 425))) {
        throw "匯入 UI 設定位置煙霧測試失敗。"
    }
    if ($processingForm.ClientSize.Width -ne 470 -or $processingForm.ClientSize.Height -ne 155) {
        throw "影片處理視窗內容區大小煙霧測試失敗。"
    }
    if (-not $script:AppIcon -or -not $main.Icon) {
        throw "JH Camera 應用程式圖示煙霧測試失敗。"
    }
    Write-Output "WinForms 煙霧測試通過；FFmpeg=$($ffmpegPath.Text)；主視窗=$($main.Width)x$($main.Height)；錄影範圍=$($selector.Width)x$($selector.Height)；自動FPS=$($fps.SelectedItem)"
    Dispose-SelectionBitmap
    $selectionOverlay.Dispose()
    $selector.Dispose()
    $processingForm.Dispose()
    $recordingOverlay.Dispose()
    $main.Dispose()
    exit 0
}

if ($env:RECORDER_PAUSE_DIAGNOSTICS -eq "1") {
    $diagnosticId = [Guid]::NewGuid().ToString("N")
    $diagnosticDirectory = Join-Path $script:ProjectRoot (".pause_diagnostics_" + $diagnosticId)
    $diagnosticOutput = Join-Path $script:ProjectRoot ("pause_diagnostics_" + $diagnosticId + ".mp4")
    [System.IO.Directory]::CreateDirectory($diagnosticDirectory) | Out-Null
    try {
        foreach ($index in @(1, 2)) {
            $segment = Join-Path $diagnosticDirectory ("segment_{0:D4}.mkv" -f $index)
            $tone = if ($index -eq 1) { "440" } else { "660" }
            $items = New-Object System.Collections.Generic.List[string]
            foreach ($item in @("-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=0x203050:s=320x240:r=30:d=0.45", "-f", "lavfi", "-i", "sine=frequency=$tone`:sample_rate=48000:duration=0.45", "-shortest", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-ar", "48000", $segment)) {
                $items.Add([string]$item)
            }
            $diagnosticInfo = New-Object System.Diagnostics.ProcessStartInfo
            $diagnosticInfo.FileName = $ffmpegPath.Text
            $diagnosticInfo.Arguments = Join-Arguments $items
            $diagnosticInfo.UseShellExecute = $false
            $diagnosticInfo.CreateNoWindow = $true
            $diagnosticInfo.RedirectStandardError = $true
            Use-Utf8StandardError $diagnosticInfo
            $diagnosticProcess = [System.Diagnostics.Process]::Start($diagnosticInfo)
            $diagnosticError = $diagnosticProcess.StandardError.ReadToEnd()
            $diagnosticProcess.WaitForExit()
            if ($diagnosticProcess.ExitCode -ne 0) { throw $diagnosticError }
            $script:RecordingSegments.Add($segment)
        }
        $script:SessionDirectory = $diagnosticDirectory
        $script:LastOutput = $diagnosticOutput
        $script:Paused = $true
        $script:PendingAction = "Finalize"
        $processingStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Finalize-RecordingSession
        $processingStopwatch.Stop()
        if (-not (Test-Path -LiteralPath $diagnosticOutput) -or (Get-Item -LiteralPath $diagnosticOutput).Length -le 0) {
            throw "暫停片段合併後未產生有效影片。"
        }
        if (-not (Test-RecordingSegmentReadable $diagnosticOutput)) {
            throw "快速封裝後的 MP4 無法解碼。"
        }
        if ($timerLabel.Text -ne "00:00:00" -or $overlayLabel.Text -ne "00:00:00") {
            throw "停止後計時器歸零測試失敗。"
        }
        Write-Output "暫停／繼續快速合併及計時歸零測試通過；處理時間=$($processingStopwatch.ElapsedMilliseconds) ms；輸出大小=$((Get-Item -LiteralPath $diagnosticOutput).Length) bytes"
    }
    finally {
        if (Test-Path -LiteralPath $diagnosticOutput) { [System.IO.File]::Delete($diagnosticOutput) }
        if ((Test-Path -LiteralPath $diagnosticDirectory) -and @(Get-ChildItem -LiteralPath $diagnosticDirectory -Force).Count -eq 0) {
            [System.IO.Directory]::Delete($diagnosticDirectory, $false)
        }
        Dispose-SelectionBitmap
        $selectionOverlay.Dispose()
        $selector.Dispose()
        $processingForm.Dispose()
        $recordingOverlay.Dispose()
        $main.Dispose()
    }
    exit 0
}

if ($AudioDiagnostics) {
    $audioDevices = @($script:AudioDeviceMap.Values)
    if ($audioDevices.Count -eq 0) { throw "沒有可測試的音訊裝置。" }
    if ($script:WasapiLoopbackAvailable) {
        $pipelineResult = Test-WasapiLoopbackPipeline $ffmpegPath.Text
        Write-Output "WASAPI 連續管線：Success=$($pipelineResult.Success)，Duration=$($pipelineResult.DurationMilliseconds) ms，Stop=$($pipelineResult.StopMilliseconds) ms"
        if (-not $pipelineResult.Success) { Write-Output $pipelineResult.Error; exit 1 }
    }
    if ($script:VoiceFilterAvailable) {
        $voicePipelineResult = Test-VoiceFilterPipeline $ffmpegPath.Text
        Write-Output "RNNoise＋VAD 連續管線：Success=$($voicePipelineResult.Success)，Bytes=$($voicePipelineResult.TotalBytes)，SilentFrames=$($voicePipelineResult.SilentFrames)"
        if (-not $voicePipelineResult.Success) { Write-Output $voicePipelineResult.Error; exit 1 }
        $diagnosticMicrophone = @($audioDevices | Where-Object { $_.Backend -in @("dshow", "openal") } | Select-Object -First 1)
        if ($diagnosticMicrophone.Count -gt 0) {
            $microphonePipelineResult = Test-VoiceMicrophonePipeline $ffmpegPath.Text $diagnosticMicrophone[0]
            Write-Output "實體麥克風人聲管線：Success=$($microphonePipelineResult.Success)，Bytes=$($microphonePipelineResult.TotalBytes)，Voiced=$($microphonePipelineResult.VoicedFrames)，Silent=$($microphonePipelineResult.SilentFrames)"
            if (-not $microphonePipelineResult.Success) { Write-Output $microphonePipelineResult.Error; exit 1 }
        }
    }
    foreach ($device in $audioDevices) {
        $result = Test-AudioDevice $ffmpegPath.Text $device
        Write-Output "$($device.Display)：Success=$($result.Success)，SampleRate=$($result.SampleRate)"
        if (-not $result.Success) { Write-Output $result.Error; exit 1 }
    }
    Dispose-SelectionBitmap
    $selectionOverlay.Dispose()
    $selector.Dispose()
    $processingForm.Dispose()
    $recordingOverlay.Dispose()
    $main.Dispose()
    exit 0
}

[System.Windows.Forms.Application]::Run($main)
