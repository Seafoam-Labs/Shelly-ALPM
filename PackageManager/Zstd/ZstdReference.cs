using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace PackageManager.Zstd;

internal static partial class ZstdReference
{
    public const string LibName = "libzstd";

    public static nint EnsureZstdSuccess(this nint ptr)
    {
        return ptr == 0
            ? throw new InvalidOperationException("zstd returned a null pointer")
            : ptr;
    }

    public static nuint EnsureZstdSuccess(this nuint code)
    {
        if (IsError(code) == 0) return code;

        var errorName = Marshal.PtrToStringAnsi(GetErrorName(code)) ?? "Unknown zstd error";
        throw new InvalidOperationException(errorName);
    }

    [LibraryImport(LibName, EntryPoint = "ZSTD_createDStream")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    public static partial nint CreateDStream();

    [LibraryImport(LibName, EntryPoint = "ZSTD_freeDStream")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    public static partial nuint FreeDStream(nint zds);

    [LibraryImport(LibName, EntryPoint = "ZSTD_DCtx_reset")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    public static partial nuint DCtxReset(nint dctx, ZstdResetDirective reset);

    [LibraryImport(LibName, EntryPoint = "ZSTD_decompressStream")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    public static partial nuint DecompressStream(nint zds, ref ZstdBuffer output, ref ZstdBuffer input);

    [LibraryImport(LibName, EntryPoint = "ZSTD_DStreamInSize")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    public static partial nuint DStreamInSize();

    [LibraryImport(LibName, EntryPoint = "ZSTD_isError")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    public static partial uint IsError(nuint code);

    [LibraryImport(LibName, EntryPoint = "ZSTD_getErrorName")]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    public static partial nint GetErrorName(nuint code);

    public enum ZstdResetDirective
    {
        ZstdResetSessionOnly = 1,
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ZstdBuffer(nuint pos, nuint size)
    {
        public nint buffer = 0;
        public nuint size = size;
        public nuint pos = pos;

        public bool IsFullyConsumed => pos >= size;
    }
}