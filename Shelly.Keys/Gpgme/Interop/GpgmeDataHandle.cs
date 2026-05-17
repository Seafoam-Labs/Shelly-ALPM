using System;
using System.Runtime.InteropServices;

namespace Shelly.Keys.Gpgme.Interop;

public sealed class GpgmeDataHandle : SafeHandle
{
    public GpgmeDataHandle() : base(IntPtr.Zero, true)
    {
    }

    public override bool IsInvalid => handle == IntPtr.Zero;

    protected override bool ReleaseHandle()
    {
        if (handle != IntPtr.Zero)
        {
            GpgmeImports.gpgme_data_release(handle);
            handle = IntPtr.Zero;
        }
        return true;
    }
}
