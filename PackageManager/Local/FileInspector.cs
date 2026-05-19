using System;
using System.Collections.Generic;
using System.Formats.Tar;
using System.IO;
using System.IO.Compression;
using System.Threading.Tasks;
using PackageManager.Zstd;

namespace PackageManager.Local;

public static class FileInspector
{
    public static async Task<bool> IsArchPackage(string filePath)
    {
        await using var fileStream = File.OpenRead(filePath);
        switch (Path.GetExtension(filePath))
        {
            case ".zst":
            {
                await using var zStdStream = new ZstdDecompressStream(fileStream);
                await using var zstTarReader = new TarReader(zStdStream);
                while (await zstTarReader.GetNextEntryAsync() is { } entry)
                    if (entry.Name.Contains("PKGINFO", StringComparison.OrdinalIgnoreCase))
                        return true;

                break;
            }
            case ".gz":
            {
                await using var gzStream = new GZipStream(fileStream, CompressionMode.Decompress);
                await using var gzTarReader = new TarReader(gzStream);
                while (await gzTarReader.GetNextEntryAsync() is { } entry)
                    if (entry.Name.Contains("PKGINFO", StringComparison.OrdinalIgnoreCase))
                        return true;

                break;
            }
        }

        return false;
    }

    public static async Task<bool> IsBinariesPackage(string filePath)
    {
        await using var fileStream = File.OpenRead(filePath);
        await using Stream decompressedStream = Path.GetExtension(filePath) switch
        {
            ".gz" => new GZipStream(fileStream, CompressionMode.Decompress),
            ".zst" => new ZstdDecompressStream(fileStream),
            _ => throw new NotSupportedException("Unsupported file extension")
        };
        await using var tarReader = new TarReader(decompressedStream);
        while (await tarReader.GetNextEntryAsync() is { } entry)
        {
            if (entry.EntryType != TarEntryType.RegularFile || entry.DataStream is null) continue;
            if (await IsElfBinary(entry.DataStream)) return true;
        }

        return false;
    }

    public static bool IsIcon(string i)
    {
        return i is ".png" or ".svg";
    }

    public static async Task<bool> IsElfBinary(Stream stream)
    {
        if (stream.CanSeek) stream.Seek(0, SeekOrigin.Begin);

        var magic = new byte[4];
        var bytesRead = await stream.ReadAsync(magic);

        return bytesRead >= 4 &&
               magic[0] == 0x7F && magic[1] == 0x45 &&
               magic[2] == 0x4C && magic[3] == 0x46;
    }

    public static async Task<List<FileInfo>> FindElfBinaries(List<FileInfo> files)
    {
        var result = new List<FileInfo>();
        foreach (var info in files)
        {
            await using var fs = File.OpenRead(info.FullName);
            if (await IsElfBinary(fs)) result.Add(info);
        }

        return result;
    }
}