using System.Collections.Frozen;
using System.Runtime.CompilerServices;
using Shelly.Gtk.UiModels.PackageManagerObjects;

namespace Shelly.Gtk.Services.PackageTraversal;

public static class PackageTraversalService
{
    public static List<string> FetchInverseFullDependencyPackageInformation(
        string rootPackageName,
        List<AlpmPackageDto> packages,
        int depth = 1)
    {
        var reverseDeps = new Dictionary<string, List<string>>(packages.Count, StringComparer.OrdinalIgnoreCase);
        var providesMap = new Dictionary<string, List<string>>(packages.Count, StringComparer.OrdinalIgnoreCase);

        foreach (var pkg in packages)
        {
            foreach (var provide in pkg.Provides)
            {
                var provideSpan = provide.AsSpan();
                var eq = provideSpan.IndexOf('=');
                var key = (eq >= 0 ? provideSpan[..eq] : provideSpan).Trim().ToString();

                if (!providesMap.TryGetValue(key, out var providers))
                    providesMap[key] = providers = new List<string>(2);
                providers.Add(pkg.Name);
            }

            foreach (var dep in pkg.Depends)
            {
                var depSpan = dep.AsSpan();
                var end = depSpan.IndexOfAny(['>', '<', '=', ' ']);
                var key = (end >= 0 ? depSpan[..end] : depSpan).ToString();

                AppendReverseDep(key, pkg.Name, reverseDeps);

                if (!providesMap.TryGetValue(key, out var resolvedProviders)) continue;
                foreach (var provider in resolvedProviders)
                    AppendReverseDep(provider, pkg.Name, reverseDeps);
            }
        }

        var frozenReverseDeps = reverseDeps.ToFrozenDictionary(
            kvp => kvp.Key, kvp => kvp.Value, StringComparer.OrdinalIgnoreCase);

        var queue = new Queue<(string Name, int CurrentDepth)>(64);
        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { rootPackageName };
        var result = new List<string>();

        queue.Enqueue((rootPackageName, 0));

        while (queue.TryDequeue(out var item))
        {
            if (item.CurrentDepth >= depth) continue;
            if (!frozenReverseDeps.TryGetValue(item.Name, out var dependents)) continue;

            foreach (var dependent in dependents)
            {
                if (!visited.Add(dependent)) continue;
                result.Add(dependent);
                queue.Enqueue((dependent, item.CurrentDepth + 1));
            }
        }

        return result;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void AppendReverseDep(
        string packageName,
        string dependentName,
        Dictionary<string, List<string>> reverseDeps)
    {
        if (!reverseDeps.TryGetValue(packageName, out var list))
            reverseDeps[packageName] = list = new List<string>(4);
        list.Add(dependentName);
    }
}