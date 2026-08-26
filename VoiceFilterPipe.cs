using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using WebRtcVadSharp;

public sealed class RecorderVoiceFilterPipe : IDisposable
{
    private const int OutputSampleRate = 48000;
    private const int FrameMilliseconds = 20;
    private const int FrameBytes = OutputSampleRate * FrameMilliseconds / 1000 * 2;
    private const int PreRollFrames = 5;
    private const int HangoverFrames = 12;
    private const int FadeSamples = 240;

    private readonly NamedPipeServerStream pipe;
    private readonly Thread worker;
    private readonly ManualResetEvent ready = new ManualResetEvent(false);
    private readonly string ffmpegPath;
    private readonly string backend;
    private readonly string deviceName;
    private readonly int inputSampleRate;
    private readonly string modelPath;
    private volatile bool stopping;
    private volatile bool disposed;
    private Process sourceProcess;
    private string errorMessage = String.Empty;
    private long voicedFrames;
    private long silentFrames;

    private sealed class PendingFrame
    {
        internal readonly byte[] Data;
        internal bool Speech;

        internal PendingFrame(byte[] data)
        {
            Data = data;
        }
    }

    public RecorderVoiceFilterPipe(string pipeName, string ffmpegPath, string backend, string deviceName, int inputSampleRate, string modelPath)
    {
        if (String.IsNullOrWhiteSpace(pipeName)) throw new ArgumentNullException("pipeName");
        if (!File.Exists(ffmpegPath)) throw new FileNotFoundException("找不到 FFmpeg。", ffmpegPath);
        if (String.IsNullOrWhiteSpace(backend)) throw new ArgumentNullException("backend");
        if (String.IsNullOrWhiteSpace(deviceName)) throw new ArgumentNullException("deviceName");
        if (!File.Exists(modelPath)) throw new FileNotFoundException("找不到 RNNoise 模型。", modelPath);

        this.ffmpegPath = ffmpegPath;
        this.backend = backend;
        this.deviceName = deviceName;
        this.inputSampleRate = inputSampleRate > 0 ? inputSampleRate : OutputSampleRate;
        this.modelPath = modelPath;
        PipePath = @"\\.\pipe\" + pipeName;
        pipe = new NamedPipeServerStream(pipeName, PipeDirection.Out, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 65536, 65536);
        worker = new Thread(Run);
        worker.Name = "JH Camera RNNoise + WebRTC VAD";
        worker.IsBackground = true;
        worker.Start();
    }

    public string PipePath { get; private set; }
    public string ErrorMessage { get { return errorMessage; } }
    public long VoicedFrames { get { return Interlocked.Read(ref voicedFrames); } }
    public long SilentFrames { get { return Interlocked.Read(ref silentFrames); } }

    public bool WaitUntilReady(int milliseconds)
    {
        if (!ready.WaitOne(milliseconds)) return false;
        return String.IsNullOrWhiteSpace(errorMessage) && pipe.IsConnected && sourceProcess != null;
    }

    public void PrepareToStop()
    {
        stopping = true;
        Process process = sourceProcess;
        if (process == null) return;
        try
        {
            if (!process.HasExited)
            {
                process.StandardInput.WriteLine("q");
                process.StandardInput.Flush();
                process.StandardInput.Close();
            }
        }
        catch { }
    }

    private void Run()
    {
        Task<string> stderrTask = null;
        try
        {
            pipe.WaitForConnection();
            if (stopping) return;

            ProcessStartInfo info = new ProcessStartInfo();
            info.FileName = ffmpegPath;
            info.Arguments = BuildSourceArguments();
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.RedirectStandardInput = true;
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = true;
            sourceProcess = Process.Start(info);
            if (sourceProcess == null) throw new InvalidOperationException("無法啟動麥克風 RNNoise 處理程序。");
            try { sourceProcess.PriorityClass = ProcessPriorityClass.AboveNormal; } catch { }
            stderrTask = sourceProcess.StandardError.ReadToEndAsync();
            ready.Set();

            using (WebRtcVad vad = new WebRtcVad())
            {
                vad.OperatingMode = OperatingMode.Aggressive;
                Queue<PendingFrame> pending = new Queue<PendingFrame>();
                int hangover = 0;
                bool previousOutputSpeech = false;
                Stream input = sourceProcess.StandardOutput.BaseStream;
                byte[] frame;
                while (!stopping && TryReadFrame(input, out frame))
                {
                    PendingFrame current = new PendingFrame(frame);
                    pending.Enqueue(current);
                    bool hasSpeech = vad.HasSpeech(frame, SampleRate.Is48kHz, FrameLength.Is20ms);
                    if (hasSpeech)
                    {
                        foreach (PendingFrame buffered in pending) buffered.Speech = true;
                        hangover = HangoverFrames;
                    }
                    else if (hangover > 0)
                    {
                        current.Speech = true;
                        hangover--;
                    }

                    if (pending.Count > PreRollFrames)
                    {
                        PendingFrame output = pending.Dequeue();
                        bool nextSpeech = pending.Count > 0 && pending.Peek().Speech;
                        WriteFrame(output, previousOutputSpeech, nextSpeech);
                        previousOutputSpeech = output.Speech;
                    }
                }

                while (pending.Count > 0)
                {
                    PendingFrame output = pending.Dequeue();
                    bool nextSpeech = pending.Count > 0 && pending.Peek().Speech;
                    WriteFrame(output, previousOutputSpeech, nextSpeech);
                    previousOutputSpeech = output.Speech;
                }
            }

            try
            {
                pipe.Flush();
                // A finite diagnostic/file source must deliver every queued
                // PCM frame before the pipe closes. During a user-requested
                // stop we intentionally skip this wait so shutdown stays fast.
                if (!stopping) pipe.WaitForPipeDrain();
            }
            catch { }
            if (!sourceProcess.WaitForExit(3000))
            {
                try { sourceProcess.Kill(); } catch { }
                sourceProcess.WaitForExit();
            }
            if (!stopping && sourceProcess.ExitCode != 0)
            {
                string details = stderrTask != null ? stderrTask.Result : String.Empty;
                throw new InvalidOperationException("麥克風 RNNoise 處理程序異常結束。\r\n" + details);
            }
        }
        catch (Exception exception)
        {
            if (!stopping) errorMessage = exception.Message;
            ready.Set();
        }
        finally
        {
            try { if (pipe.IsConnected) pipe.Disconnect(); } catch { }
            Process process = sourceProcess;
            if (process != null)
            {
                try { if (!process.HasExited) process.Kill(); } catch { }
                try { process.Dispose(); } catch { }
            }
            ready.Set();
        }
    }

    private void WriteFrame(PendingFrame frame, bool previousSpeech, bool nextSpeech)
    {
        byte[] output;
        if (!frame.Speech)
        {
            output = new byte[FrameBytes];
            Interlocked.Increment(ref silentFrames);
        }
        else
        {
            output = (byte[])frame.Data.Clone();
            if (!previousSpeech) ApplyFade(output, true);
            if (!nextSpeech) ApplyFade(output, false);
            Interlocked.Increment(ref voicedFrames);
        }
        pipe.Write(output, 0, output.Length);
    }

    private static void ApplyFade(byte[] audio, bool fadeIn)
    {
        int samples = Math.Min(FadeSamples, audio.Length / 2);
        int firstSample = fadeIn ? 0 : (audio.Length / 2 - samples);
        for (int index = 0; index < samples; index++)
        {
            int sampleIndex = firstSample + index;
            int byteIndex = sampleIndex * 2;
            short value = (short)(audio[byteIndex] | (audio[byteIndex + 1] << 8));
            double gain = fadeIn ? (index + 1.0) / samples : (samples - index - 1.0) / samples;
            short adjusted = (short)Math.Round(value * gain);
            audio[byteIndex] = (byte)(adjusted & 0xff);
            audio[byteIndex + 1] = (byte)((adjusted >> 8) & 0xff);
        }
    }

    private static bool TryReadFrame(Stream input, out byte[] frame)
    {
        frame = new byte[FrameBytes];
        int offset = 0;
        while (offset < frame.Length)
        {
            int read = input.Read(frame, offset, frame.Length - offset);
            if (read <= 0) break;
            offset += read;
        }
        if (offset == 0) return false;
        if (offset < frame.Length) Array.Clear(frame, offset, frame.Length - offset);
        return true;
    }

    private string BuildSourceArguments()
    {
        List<string> items = new List<string>();
        Add(items, "-hide_banner", "-loglevel", "error", "-nostats", "-thread_queue_size", "4096", "-rtbufsize", "256M");
        if (String.Equals(backend, "dshow", StringComparison.OrdinalIgnoreCase))
        {
            Add(items, "-use_wallclock_as_timestamps", "1", "-f", "dshow", "-i", "audio=" + deviceName);
        }
        else if (String.Equals(backend, "openal", StringComparison.OrdinalIgnoreCase))
        {
            Add(items, "-f", "openal", "-channels", "1", "-sample_rate", inputSampleRate.ToString(), "-sample_size", "16", "-i", deviceName);
        }
        else if (String.Equals(backend, "lavfi", StringComparison.OrdinalIgnoreCase))
        {
            Add(items, "-f", "lavfi", "-i", deviceName);
        }
        else if (String.Equals(backend, "file", StringComparison.OrdinalIgnoreCase))
        {
            Add(items, "-i", deviceName);
        }
        else
        {
            throw new InvalidOperationException("不支援的麥克風後端：" + backend);
        }

        string model = modelPath.Replace('\\', '/').Replace(":", "\\:").Replace("'", "\\'");
        // RNNoise receives one 48 kHz channel on every microphone. Explicit
        // mono conversion also covers DirectShow microphone arrays that expose
        // a stereo capture format on other PCs.
        string filter = "aresample=48000,aformat=channel_layouts=mono,arnndn=m='" + model + "'";
        Add(items, "-vn", "-af", filter, "-ac", "1", "-ar", OutputSampleRate.ToString(), "-c:a", "pcm_s16le", "-f", "s16le", "pipe:1");
        return JoinArguments(items);
    }

    private static void Add(List<string> items, params string[] values)
    {
        foreach (string value in values) items.Add(value);
    }

    private static string JoinArguments(List<string> items)
    {
        StringBuilder result = new StringBuilder();
        foreach (string item in items)
        {
            if (result.Length > 0) result.Append(' ');
            result.Append(QuoteArgument(item));
        }
        return result.ToString();
    }

    private static string QuoteArgument(string value)
    {
        StringBuilder result = new StringBuilder();
        result.Append('"');
        int slashes = 0;
        foreach (char character in value)
        {
            if (character == '\\')
            {
                slashes++;
                continue;
            }
            if (character == '"')
            {
                result.Append('\\', slashes * 2 + 1);
                result.Append('"');
            }
            else
            {
                if (slashes > 0) result.Append('\\', slashes);
                result.Append(character);
            }
            slashes = 0;
        }
        if (slashes > 0) result.Append('\\', slashes * 2);
        result.Append('"');
        return result.ToString();
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        PrepareToStop();
        // Closing the server first also releases a worker that is still
        // waiting for FFmpeg to connect, avoiding a needless 3-second delay.
        try { pipe.Dispose(); } catch { }
        try { if (!worker.Join(3000)) { Process process = sourceProcess; if (process != null && !process.HasExited) process.Kill(); } } catch { }
        ready.Dispose();
    }
}
