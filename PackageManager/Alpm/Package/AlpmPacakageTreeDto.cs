using System.Collections.Generic;

namespace PackageManager.Alpm.Package;

public partial record AlpmPackageTreeDto(string Name)
{
    public List<AlpmPackageTreeDto> Files { get; } = [];
}