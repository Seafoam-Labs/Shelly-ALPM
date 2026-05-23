namespace PackageManager.Alpm.Questions;

public record ProviderOption(string Name, string? Description , bool IsInstalled,bool IsSelected = false);