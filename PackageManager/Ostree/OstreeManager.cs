using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using PackageManager.Flatpak;
using PackageManager.Ostree.Enums;

namespace PackageManager.Ostree;

public class OstreeManager()
{
    public List<OstreeRepositoryRef> ListRefs(string repoPath)
    {
        
        var refs = new List<OstreeRepositoryRef>();
        
        if (string.IsNullOrWhiteSpace(repoPath))
        {
            return refs;
        }

        if (!Directory.Exists(repoPath))
        {
            return refs;
        }

        var file = OstreeReference.GFileNewForPath(repoPath);

        if (file == IntPtr.Zero)
        {
            return refs;
        }

        try
        {
            var repo = OstreeReference.RepoNew(file);

            if (repo == IntPtr.Zero)
            {
                return refs;
            }

            try
            {
                if (!OstreeReference.RepoOpen(
                        repo,
                        IntPtr.Zero,
                        out var error))
                {
                    if (error != IntPtr.Zero)
                    {
                        OstreeReference.GErrorFree(error);
                    }

                    return refs;
                }

                if (!OstreeReference.RepoListRefs(
                        repo,
                        null,
                        out var refsTable,
                        IntPtr.Zero,
                        out error))
                {
                    if (error != IntPtr.Zero)
                    {
                        OstreeReference.GErrorFree(error);
                    }

                    return refs;
                }

                refs.AddRange(
                    ParseRefsTable(refsTable, repoPath));
            }
            finally
            {
                OstreeReference.GObjectUnref(repo);
            }
        }
        finally
        {
            OstreeReference.GObjectUnref(file);
        }

        return refs;
    }
    
    private List<OstreeRepositoryRef> ParseRefsTable(
        IntPtr refsTable, string repoPath)
    {
        var refs = new List<OstreeRepositoryRef>();

        OstreeReference.GHashTableIterInit(
            out var iter,
            refsTable);

        while (OstreeReference.GHashTableIterNext(
                   ref iter,
                   out var keyPtr,
                   out var valuePtr))
        {
            var fullRef =
                Marshal.PtrToStringUTF8(keyPtr);

            if (string.IsNullOrWhiteSpace(fullRef))
            {
                continue;
            }

            var split =
                fullRef.Split(':', 2);

            if (split.Length != 2)
            {
                continue;
            }

            var reference = split[1];

            if (!reference.StartsWith("app/") &&
                !reference.StartsWith("runtime/"))
            {
                continue;
            }

            refs.Add(new OstreeRepositoryRef
            {
                Remote = split[0],
                Ref = split[1],
                RepoPath = repoPath
            });
        }

        return refs;
    }
    
    public string? GetCommitForRef(
        string repoPath,
        string fullRef)
    {
        var file = OstreeReference.GFileNewForPath(repoPath);

        if (file == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            var repo = OstreeReference.RepoNew(file);

            if (repo == IntPtr.Zero)
            {
                return null;
            }

            try
            {
                if (!OstreeReference.RepoOpen(
                        repo,
                        IntPtr.Zero,
                        out var error))
                {
                    if (error != IntPtr.Zero)
                    {
                        OstreeReference.GErrorFree(error);
                    }

                    return null;
                }

                if (!OstreeReference.RepoResolveRev(
                        repo,
                        fullRef,
                        false,
                        out var revisionPtr,
                        IntPtr.Zero,
                        out error))
                {
                    if (error != IntPtr.Zero)
                    {
                        OstreeReference.GErrorFree(error);
                    }

                    return null;
                }

                if (revisionPtr == IntPtr.Zero)
                {
                    return null;
                }

                try
                {
                    return Marshal.PtrToStringUTF8(revisionPtr);
                }
                finally
                {
                    OstreeReference.GFree(revisionPtr);
                }
            }
            finally
            {
                OstreeReference.GObjectUnref(repo);
            }
        }
        finally
        {
            OstreeReference.GObjectUnref(file);
        }
    }
    
    public FsckResult FsckCommit(
        string repoPath,
        string commit)
    {
        var result = new FsckResult
        {
            Commit = commit,
            MissingObjects = [],
            InvalidObjects = []
        };

        var repo = OpenRepo(repoPath);

        if (repo == null)
        {
            result.Status =
                FsckStatus.UnknownError;

            result.ErrorMessage =
                "Failed to open OSTree repo";

            return result;
        }

        try
        {
            var success =
                OstreeReference.RepoFsckObject(
                    repo.Value,
                    (int)OstreeObjectType.Commit,
                    commit,
                    IntPtr.Zero,
                    out var error);

            if (success)
            {
                result.Status =
                    FsckStatus.Ok;

                return result;
            }

            var errorMessage =
                FlatpakReference.GetErrorMessage(error);

            result.ErrorMessage =
                errorMessage;

            if (errorMessage.Contains(
                    "No such metadata object"))
            {
                result.Status =
                    FsckStatus.MissingObjects;

                result.MissingObjects.Add(commit);
            }
            else if (errorMessage.Contains(
                         "corrupted"))
            {
                result.Status =
                    FsckStatus.CorruptedCommit;

                result.InvalidObjects.Add(commit);
            }
            else
            {
                result.Status =
                    FsckStatus.UnknownError;
            }

            if (error != IntPtr.Zero)
            {
                OstreeReference.GErrorFree(error);
            }

            return result;
        }
        finally
        {
            OstreeReference.GObjectUnref(repo.Value);
        }
    }
    
    private static IntPtr? OpenRepo(string repoPath)
    {
        var file =
            OstreeReference.GFileNewForPath(repoPath);

        if (file == IntPtr.Zero)
        {
            return null;
        }

        var repo =
            OstreeReference.RepoNew(file);

        OstreeReference.GObjectUnref(file);

        if (repo == IntPtr.Zero)
        {
            return null;
        }

        if (!OstreeReference.RepoOpen(
                repo,
                IntPtr.Zero,
                out var error))
        {
            if (error != IntPtr.Zero)
            {
                OstreeReference.GErrorFree(error);
            }

            OstreeReference.GObjectUnref(repo);

            return null;
        }

        return repo;
    }
    
    public OstreePruneResult Prune(string repoPath)
    {
        var result = new OstreePruneResult();

        var repo = OpenRepo(repoPath);

        if (repo == null)
        {
            result.Success = false;
            result.ErrorMessage = "Failed to open repo";

            return result;
        }

        try
        {
            var success = OstreeReference.RepoPrune(
                repo.Value,
                (int)OstreeRepoPruneFlags.None,
                -1,
                out var total,
                out var pruned,
                out var size,
                IntPtr.Zero,
                out var error);

            result.Success = success;
            result.ObjectsTotal = total;
            result.ObjectsPruned = pruned;
            result.PrunedBytes = size;

            if (!success && error != IntPtr.Zero)
            {
                result.ErrorMessage =
                    FlatpakReference.GetErrorMessage(error);

                OstreeReference.GErrorFree(error);
            }

            return result;
        }
        finally
        {
            OstreeReference.GObjectUnref(repo.Value);
        }
    }
}