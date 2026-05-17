using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using PackageManager.Aur.Models;

namespace PackageManager.Aur;

public interface IAurSearchManager
{
    Task<AurResponse<AurPackageDto>> SearchAsync(string query, CancellationToken cancellationToken = default);

    Task<List<string>> SuggestAsync(string query, CancellationToken cancellationToken = default);

    Task<List<string>> SuggestByPackageBaseNamesAsync(string query,
        CancellationToken cancellationToken = default);

    Task<AurResponse<AurPackageDto>> GetInfoAsync(IEnumerable<string> packageNames,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Resolves a <c>pkgname</c> to its <c>pkgbase</c> via the AUR RPC <c>info</c> endpoint.
    /// For split packages the AUR git repository is hosted under the <c>pkgbase</c> name,
    /// so all clone / cgit URL building must use the resolved base.
    /// Falls back to the supplied <paramref name="pkgname"/> when the lookup fails or
    /// the package isn't a split package (i.e. <c>pkgbase == pkgname</c>).
    /// </summary>
    Task<string> GetPackageBaseAsync(string pkgname, CancellationToken cancellationToken = default);

    /// <summary>
    /// Resolves an AUR-side dependency name to one or more provider package names.
    /// If a real AUR package exists by <paramref name="name"/>, returns a single-element
    /// list containing that name. Otherwise queries the AUR RPC
    /// <c>type=search&amp;by=provides</c> endpoint and returns every AUR package whose
    /// <c>provides=</c> list includes <paramref name="name"/>. Returns an empty list
    /// when nothing matches (or on transport failure).
    /// </summary>
    Task<List<string>> FindProvidersAsync(string name, CancellationToken cancellationToken = default);
}