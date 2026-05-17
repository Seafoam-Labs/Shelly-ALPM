using System.Diagnostics.CodeAnalysis;
using PackageManager.Zstd;

namespace PackageManager.Tests.Zstd;

[TestFixture]
[TestOf(typeof(ZstdDecompressStream))]
[SuppressMessage("Reliability", "CA2022:Avoid inexact read with \'Stream.Read\'")]
public class ZstdDecompressStreamTests
{
    [Test]
    public void SuccessfullyResolvesZstdLibrary()
    {
        var isAvailable = NativeResolver.IsLibraryAvailable(ZstdReference.LibName);
        Assert.That(isAvailable, Is.True);
    }

    [Test]
    public void CreateDStreamReturnsNonNullHandle()
    {
        var handle = ZstdReference.CreateDStream();

        try
        {
            Assert.That(handle, Is.Not.EqualTo(0));
        }
        finally
        {
            if (handle != 0) ZstdReference.FreeDStream(handle);
        }
    }

    [Test]
    public void EnsureZstdSuccessThrowsForErrorCode()
    {
        var ex = Assert.Throws<InvalidOperationException>(() => { _ = UIntPtr.MaxValue.EnsureZstdSuccess(); });

        Assert.That(ex, Is.Not.Null);
        Assert.That(ex!.Message, Is.Not.Empty);
    }

    [Test]
    public void ConstructorThrowsForNullStream()
    {
        var ex = Assert.Throws<ArgumentNullException>(() => { _ = new ZstdDecompressStream(null!); });

        Assert.That(ex!.ParamName, Is.EqualTo("stream"));
    }

    [Test]
    public void ConstructorThrowsForUnreadableStream()
    {
        using var stream = new WriteOnlyStream();

        var ex = Assert.Throws<ArgumentException>(() => { _ = new ZstdDecompressStream(stream); });

        Assert.That(ex, Is.Not.Null);
        Assert.That(ex!.ParamName, Is.EqualTo("stream"));
    }

    [Test]
    public void ReadThrowsObjectDisposedExceptionAfterDispose()
    {
        using var inner = new MemoryStream();
        var stream = new ZstdDecompressStream(inner);
        stream.Dispose();

        var buffer = new byte[16];

        Assert.Throws<ObjectDisposedException>(() => stream.ReadExactly(buffer, 0, buffer.Length));
    }

    [Test]
    public void ReadThrowsArgumentNullExceptionForNullBuffer()
    {
        using var inner = new MemoryStream();
        using var stream = new ZstdDecompressStream(inner);

        var ex = Assert.Throws<ArgumentNullException>(() => stream.ReadExactly(null!, 0, 1));
        Assert.That(ex!.ParamName, Is.EqualTo("buffer"));
    }

    [Test]
    public void ReadThrowsArgumentOutOfRangeExceptionForNegativeOffset()
    {
        using var inner = new MemoryStream();
        using var stream = new ZstdDecompressStream(inner);

        var buffer = new byte[4];

        var ex = Assert.Throws<ArgumentOutOfRangeException>(() => stream.ReadExactly(buffer, -1, 1));
        Assert.That(ex!.ParamName, Is.EqualTo("offset"));
    }

    [Test]
    public void ReadThrowsArgumentOutOfRangeExceptionForNegativeCount()
    {
        using var inner = new MemoryStream();
        using var stream = new ZstdDecompressStream(inner);

        var buffer = new byte[4];

        var ex = Assert.Throws<ArgumentOutOfRangeException>(() => stream.Read(buffer, 0, -1));
        Assert.That(ex!.ParamName, Is.EqualTo("count"));
    }

    [Test]
    public void ReadThrowsArgumentExceptionWhenOffsetAndCountExceedBuffer()
    {
        using var inner = new MemoryStream();
        using var stream = new ZstdDecompressStream(inner);

        var buffer = new byte[4];

        var ex = Assert.Throws<ArgumentOutOfRangeException>(() => stream.Read(buffer, 3, 2));
        Assert.That(ex!.Message, Does.Contain("count ('2') must be less than or equal to '1'."));
    }

    [Test]
    public void ReadFromEmptyInnerStreamReturnsZero()
    {
        using var inner = new MemoryStream([]);
        using var stream = new ZstdDecompressStream(inner);

        var buffer = new byte[32];
        var bytesRead = stream.Read(buffer, 0, buffer.Length);

        Assert.That(bytesRead, Is.EqualTo(0));
    }

    private sealed class WriteOnlyStream : Stream
    {
        public override bool CanRead => false;
        public override bool CanSeek => false;
        public override bool CanWrite => true;

        public override long Length => throw new NotSupportedException();

        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override void Flush()
        {
        }

        public override int Read(byte[] buffer, int offset, int count) =>
            throw new NotSupportedException();

        public override long Seek(long offset, SeekOrigin origin) =>
            throw new NotSupportedException();

        public override void SetLength(long value) =>
            throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count)
        {
        }
    }
}