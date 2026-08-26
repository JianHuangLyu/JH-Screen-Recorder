using System;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Threading;
using NAudio.Wave;

public sealed class RecorderLoopbackFormat
{
    public int SampleRate { get; internal set; }
    public int Channels { get; internal set; }
    public int BitsPerSample { get; internal set; }
    public int BlockAlign { get; internal set; }
    public string InputFormat { get; internal set; }
}

public sealed class RecorderLoopbackPipe : IDisposable
{
    // Windows may deliver loopback packets late when the desktop encoder is
    // busy. Keep enough latency before synthesizing silence so real samples
    // are not mistaken for a gap and discarded as an overlap.
    private const int SilenceLagMilliseconds = 600;
    private static readonly Guid PcmSubFormat = new Guid("00000001-0000-0010-8000-00aa00389b71");
    private static readonly Guid FloatSubFormat = new Guid("00000003-0000-0010-8000-00aa00389b71");

    private readonly object writeGate = new object();
    private readonly ManualResetEvent connectionReady = new ManualResetEvent(false);
    private readonly byte[] silenceBuffer = new byte[65536];
    private readonly NamedPipeServerStream pipe;
    private readonly WasapiLoopbackCapture capture;
    private readonly Thread worker;
    private readonly Stopwatch elapsed = new Stopwatch();
    private long writtenFrames;
    private volatile bool stopRequested;
    private volatile bool preparedToStop;
    private bool connected;
    private bool disposed;
    private Exception failure;

    public int SampleRate { get; private set; }
    public int Channels { get; private set; }
    public int BitsPerSample { get; private set; }
    public int BlockAlign { get; private set; }
    public string InputFormat { get; private set; }
    public string ErrorMessage { get { return failure == null ? "" : failure.Message; } }

    public RecorderLoopbackPipe(string pipeName)
    {
        if (String.IsNullOrWhiteSpace(pipeName)) throw new ArgumentException("Pipe name is required.", "pipeName");
        capture = new WasapiLoopbackCapture();
        ApplyFormat(capture.WaveFormat);
        pipe = new NamedPipeServerStream(
            pipeName,
            PipeDirection.Out,
            1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous,
            0,
            4194304);
        capture.DataAvailable += OnDataAvailable;
        capture.RecordingStopped += OnRecordingStopped;
        worker = new Thread(CaptureWorker);
        worker.IsBackground = true;
        worker.Name = "Recorder WASAPI loopback";
        worker.Start();
    }

    public static RecorderLoopbackFormat Probe()
    {
        using (var probe = new WasapiLoopbackCapture())
        {
            string inputFormat = ResolveInputFormat(probe.WaveFormat);
            return new RecorderLoopbackFormat {
                SampleRate = probe.WaveFormat.SampleRate,
                Channels = probe.WaveFormat.Channels,
                BitsPerSample = probe.WaveFormat.BitsPerSample,
                BlockAlign = probe.WaveFormat.BlockAlign,
                InputFormat = inputFormat
            };
        }
    }

    public bool WaitUntilConnected(int milliseconds)
    {
        if (!connectionReady.WaitOne(milliseconds)) return false;
        return connected && failure == null;
    }

    public void PrepareToStop()
    {
        if (preparedToStop) return;
        preparedToStop = true;
        try { capture.StopRecording(); } catch { }
        if (connected)
        {
            lock (writeGate)
            {
                try
                {
                    WriteSilenceUntilNoLock(ElapsedFrames());
                    pipe.Flush();
                }
                catch (Exception ex)
                {
                    if (!stopRequested) failure = ex;
                }
            }
        }
        // Closing the writer is intentional: FFmpeg must receive EOF on the
        // raw-audio input. Keeping an idle pipe open can leave it waiting
        // forever even though the video segment has already been written.
        try { pipe.Dispose(); } catch { }
    }

    private void CaptureWorker()
    {
        try
        {
            pipe.WaitForConnection();
            if (stopRequested) return;
            elapsed.Restart();
            capture.StartRecording();
            connected = true;
            connectionReady.Set();
            while (!stopRequested && !preparedToStop)
            {
                long targetFrames = ((elapsed.ElapsedMilliseconds - SilenceLagMilliseconds) * (long)SampleRate) / 1000L;
                if (targetFrames > 0)
                {
                    lock (writeGate) { WriteSilenceUntilNoLock(targetFrames); }
                }
                Thread.Sleep(10);
            }
        }
        catch (Exception ex)
        {
            if (!stopRequested) failure = ex;
            connectionReady.Set();
        }
    }

    private void OnDataAvailable(object sender, WaveInEventArgs eventArgs)
    {
        if (stopRequested || preparedToStop || eventArgs.BytesRecorded <= 0) return;
        try
        {
            lock (writeGate)
            {
                if (stopRequested || preparedToStop) return;
                long packetFrames = eventArgs.BytesRecorded / BlockAlign;
                long packetEnd = ElapsedFrames();
                long packetStart = Math.Max(0L, packetEnd - packetFrames);
                if (writtenFrames < packetStart) WriteSilenceUntilNoLock(packetStart);
                // The callback clock can jitter relative to the audio sample
                // clock. Never delete genuine samples merely because their
                // estimated wall-clock range overlaps silence already written
                // by a few milliseconds; that produced audible, rapid gaps.
                // Appending the complete captured packet keeps the source
                // stream continuous. Silence is inserted only before packets.
                pipe.Write(eventArgs.Buffer, 0, eventArgs.BytesRecorded);
                writtenFrames += packetFrames;
            }
        }
        catch (Exception ex)
        {
            if (!stopRequested) failure = ex;
        }
    }

    private void OnRecordingStopped(object sender, StoppedEventArgs eventArgs)
    {
        if (eventArgs.Exception != null && !stopRequested && !preparedToStop) failure = eventArgs.Exception;
    }

    private long ElapsedFrames()
    {
        return (elapsed.ElapsedTicks * (long)SampleRate) / Stopwatch.Frequency;
    }

    private void WriteSilenceUntilNoLock(long targetFrames)
    {
        while (!stopRequested && writtenFrames < targetFrames)
        {
            long remainingFrames = targetFrames - writtenFrames;
            int framesThisWrite = (int)Math.Min(remainingFrames, silenceBuffer.Length / BlockAlign);
            int bytesThisWrite = framesThisWrite * BlockAlign;
            pipe.Write(silenceBuffer, 0, bytesThisWrite);
            writtenFrames += framesThisWrite;
        }
    }

    private void ApplyFormat(WaveFormat format)
    {
        SampleRate = format.SampleRate;
        Channels = format.Channels;
        BitsPerSample = format.BitsPerSample;
        BlockAlign = format.BlockAlign;
        InputFormat = ResolveInputFormat(format);
    }

    private static string ResolveInputFormat(WaveFormat format)
    {
        bool isFloat = format.Encoding == WaveFormatEncoding.IeeeFloat;
        bool isPcm = format.Encoding == WaveFormatEncoding.Pcm;
        var extensible = format as WaveFormatExtensible;
        if (extensible != null)
        {
            isFloat = extensible.SubFormat == FloatSubFormat;
            isPcm = extensible.SubFormat == PcmSubFormat;
        }
        if (isFloat && format.BitsPerSample == 32) return "f32le";
        if (isPcm && format.BitsPerSample == 16) return "s16le";
        if (isPcm && format.BitsPerSample == 24) return "s24le";
        if (isPcm && format.BitsPerSample == 32) return "s32le";
        throw new NotSupportedException("Unsupported WASAPI mix format: " + format);
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        try { PrepareToStop(); } catch { }
        stopRequested = true;
        connectionReady.Set();
        try { pipe.Dispose(); } catch { }
        if (worker != null && worker.IsAlive) worker.Join(1000);
        capture.DataAvailable -= OnDataAvailable;
        capture.RecordingStopped -= OnRecordingStopped;
        capture.Dispose();
        connectionReady.Dispose();
    }
}
