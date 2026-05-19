using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using PackageManager.Alpm;
using PackageManager.Aur.Models;

namespace PackageManager.Aur;

public interface IAurPackageManager : IDisposable
{
    Task Initialize(bool root = false, bool useTempPath = false, bool useChroot = false,
        string chrootPath = "/var/lib/shelly/chroot", string tempPath = "", bool showHiddenPackages = false,
        bool noCheck = true);

    Task<List<AurPackageDto>> GetInstalledPackages();
    Task<List<AurPackageDto>> SearchPackages(string query);

    Task<List<AurUpdateDto>> GetPackagesNeedingUpdate(bool checkDevel = true);

    Task UpdatePackages(List<string> packageNames);

    Task InstallPackages(List<string> packageNames);

    Task RemovePackages(List<string> packageNames, AlpmTransFlag flags = AlpmTransFlag.None, bool removeOptionalDeps = false);
}