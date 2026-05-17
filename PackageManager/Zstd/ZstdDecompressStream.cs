using System;
using System.Buffers;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using static PackageManager.Zstd.ZstdReference;

namespace PackageManager.Zstd;

public sealed class ZstdDecompressStream : Stream
{
    private readonly nuint _bufferSize;
    private readonly Stream _innerStream;
    private readonly byte[] _inputBuffer;
    private readonly Memory<byte> _inputMemory;
    private readonly bool _leaveOpen;

    private nint _dStream;
    private nuint _inputPosition;
    private nuint _inputSize;

    public ZstdDecompressStream(Stream stream, bool leaveOpen = false)
    {
        ArgumentNullException.ThrowIfNull(stream);
        if (!stream.CanRead) throw new ArgumentException("Stream is not readable", nameof(stream));

        _innerStream = stream;
        _leaveOpen = leaveOpen;

        _dStream = CreateDStream().EnsureZstdSuccess();
        DCtxReset(_dStream, ZstdResetDirective.ZstdResetSessionOnly).EnsureZstdSuccess();

        _bufferSize = DStreamInSize().EnsureZstdSuccess();
        _inputBuffer = ArrayPool<byte>.Shared.Rent((int)_bufferSize);
        _inputMemory = new Memory<byte>(_inputBuffer, 0, (int)_bufferSize);

        _inputPosition = _inputSize = _bufferSize;
    }

    public override bool CanRead => _dStream != 0 && _innerStream.CanRead;
    public override bool CanSeek => false;
    public override bool CanWrite => false;

    public override long Length => throw new NotSupportedException();

    public override long Position
    {
        get => throw new NotSupportedException();
        set => throw new NotSupportedException();
    }

    public override int Read(Span<byte> buffer)
    {
        EnsureNotDisposed();
        return buffer.Length == 0
            ? 0
            : ReadInternal(buffer);
    }

    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        EnsureNotDisposed();
        return buffer.Length == 0
            ? ValueTask.FromResult(0)
            : ReadInternalAsync(buffer, cancellationToken);
    }

    public override int Read(byte[] buffer, int offset, int count)
    {
        EnsureParamsValid(buffer, offset, count);
        EnsureNotDisposed();
        return buffer.Length == 0
            ? 0
            : ReadInternal(new Span<byte>(buffer, offset, count));
    }

    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
    {
        EnsureParamsValid(buffer, offset, count);
        EnsureNotDisposed();
        return buffer.Length == 0
            ? Task.FromResult(0)
            : ReadInternalAsync(new Memory<byte>(buffer, offset, count), cancellationToken).AsTask();
    }

    private int ReadInternal(Span<byte> buffer)
    {
        var input = new ZstdBuffer(_inputPosition, _inputSize);
        var output = new ZstdBuffer(0, (nuint)buffer.Length);

        var inputSpan = new Span<byte>(_inputBuffer, 0, (int)_bufferSize);

        while (!output.IsFullyConsumed && (!input.IsFullyConsumed || FillInputBuffer(inputSpan, ref input) > 0))
            Decompress(buffer, ref output, ref input);

        _inputPosition = input.pos;
        _inputSize = input.size;

        return (int)output.pos;
    }

    private async ValueTask<int> ReadInternalAsync(Memory<byte> buffer, CancellationToken cancellationToken)
    {
        var input = new ZstdBuffer(_inputPosition, _inputSize);
        var output = new ZstdBuffer(0, (nuint)buffer.Length);

        while (!output.IsFullyConsumed)
        {
            if (input.IsFullyConsumed)
            {
                var bytesRead = await _innerStream.ReadAsync(_inputMemory, cancellationToken).ConfigureAwait(false);
                if (bytesRead == 0) break;

                input.size = (nuint)bytesRead;
                input.pos = 0;
            }

            Decompress(buffer.Span, ref output, ref input);
        }

        _inputPosition = input.pos;
        _inputSize = input.size;

        return (int)output.pos;
    }

    private unsafe void Decompress(Span<byte> buffer, ref ZstdBuffer output, ref ZstdBuffer input)
    {
        fixed (void* inputBufferHandle = &_inputBuffer[0])
        fixed (void* outputBufferHandle = &MemoryMarshal.GetReference(buffer))
        {
            input.buffer = new IntPtr(inputBufferHandle);
            output.buffer = new IntPtr(outputBufferHandle);

            DecompressStream(_dStream, ref output, ref input).EnsureZstdSuccess();
        }
    }

    private int FillInputBuffer(Span<byte> inputSpan, ref ZstdBuffer input)
    {
        var bytesRead = _innerStream.Read(inputSpan);

        input.size = (nuint)bytesRead;
        input.pos = 0;

        return bytesRead;
    }

    protected override void Dispose(bool disposing)
    {
        if (_dStream == 0) return;

        var dstream = _dStream;
        _dStream = 0;

        try
        {
            _ = FreeDStream(dstream);
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(_inputBuffer);

            if (disposing && !_leaveOpen) _innerStream.Dispose();

            base.Dispose(disposing);
        }
    }

    private static void EnsureParamsValid(byte[] buffer, int offset, int count)
    {
        ArgumentNullException.ThrowIfNull(buffer);
        ArgumentOutOfRangeException.ThrowIfNegative(offset);
        ArgumentOutOfRangeException.ThrowIfNegative(count);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(count, buffer.Length - offset);
    }

    private void EnsureNotDisposed()
    {
        if (_dStream != 0) return;
        throw new ObjectDisposedException(nameof(ZstdDecompressStream));
    }

    public override void Flush()
    {
        EnsureNotDisposed();
    }

    public override long Seek(long offset, SeekOrigin origin)
    {
        throw new NotSupportedException();
    }

    public override void SetLength(long value)
    {
        throw new NotSupportedException();
    }

    public override void Write(byte[] buffer, int offset, int count)
    {
        throw new NotSupportedException();
    }
}