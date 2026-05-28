namespace PackageManager.Alpm;

public record struct DowngradeOptionDto(
    string Name,
    string Filename,
    string Location,
    bool IsInstalled
);