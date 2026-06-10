namespace PackageManager.Ostree;

public class OstreeRepositoryRef
{
    public string RepoPath { get; set; } = "";
    
    public string Remote { get; set; } = "";

    public string Ref { get; set; } = "";
    
    public string Commit { get; set; } = "";
    
    public string FullRef =>
        $"{Remote}:{Ref}";
}
