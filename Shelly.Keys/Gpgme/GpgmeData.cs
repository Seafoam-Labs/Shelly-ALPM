using System;
using System.Runtime.InteropServices;
using Shelly.Keys.Gpgme.Interop;

namespace Shelly.Keys.Gpgme;

public sealed class GpgmeData : IDisposable
{
    private GpgmeDataHandle _handle;
    private bool _disposed;

    internal GpgmeDataHandle Handle => _handle;

    public GpgmeData()
    {
        uint err = GpgmeImports.gpgme_data_new_from_mem(out _handle, IntPtr.Zero, UIntPtr.Zero, 0);
        GpgmeHelpers.ThrowIfErrorString(err);
    }

    public static GpgmeData FromMemory(byte[] buffer)
    {
        var data = new GpgmeData();
        data.Write(buffer);
        data.Seek(0, 0); // SEEK_SET
        return data;
    }

    public static GpgmeData FromFileDescriptor(int fd)
    {
        var data = new GpgmeData { _handle = null! };
        uint err = GpgmeImports.gpgme_data_new_from_fd(out data._handle, fd);
        GpgmeHelpers.ThrowIfErrorString(err);
        return data;
    }

    public unsafe int Write(ReadOnlySpan<byte> buffer)
    {
        fixed (byte* ptr = buffer)
        {
            IntPtr result = GpgmeImports.gpgme_data_write(_handle, (IntPtr)ptr, (UIntPtr)buffer.Length);
            return (int)result;
        }
    }

    public unsafe int Read(Span<byte> buffer)
    {
        fixed (byte* ptr = buffer)
        {
            IntPtr result = GpgmeImports.gpgme_data_read(_handle, (IntPtr)ptr, (UIntPtr)buffer.Length);
            return (int)result;
        }
    }

    public long Seek(long offset, int whence)
    {
        return GpgmeImports.gpgme_data_seek(_handle, offset, whence);
    }

    public byte[] ToArray()
    {
        Seek(0, 0); // SEEK_SET
        
        // This is a naive implementation that assumes the data fits in memory.
        // For very large data, this could be problematic.
        var result = new System.Collections.Generic.List<byte>();
        var buffer = new byte[4096];
        int read;
        while ((read = Read(buffer)) > 0)
        {
            var span = new ReadOnlySpan<byte>(buffer, 0, read);
            result.AddRange(span.ToArray());
        }
        return result.ToArray();
    }
    
    public string ToStringUtf8()
    {
        var bytes = ToArray();
        return System.Text.Encoding.UTF8.GetString(bytes);
    }

    private void Dispose(bool disposing)
    {
        if (!_disposed)
        {
            if (disposing)
            {
                _handle?.Dispose();
            }
            _disposed = true;
        }
    }

    public void Dispose()
    {
        Dispose(true);
        GC.SuppressFinalize(this);
    }
}
