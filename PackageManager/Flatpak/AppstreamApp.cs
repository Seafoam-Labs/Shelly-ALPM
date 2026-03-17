using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace PackageManager.Flatpak;

/// <summary>
/// Represents an application from Flatpak appstream metadata
/// </summary>
public class AppstreamApp
{
    public string Id { get; set; } = string.Empty;

    public string Name { get; set; } = string.Empty;

    public string Summary { get; set; } = string.Empty;
    
    public string Description { get; set; } = string.Empty;
    
    public string Type { get; set; } = string.Empty;

    public string ProjectLicense { get; set; } = string.Empty;
    
    public string DeveloperName { get; set; } = string.Empty;

    public List<string> Categories { get; set; } = new();
    
    public List<string> Keywords { get; set; } = new();
    
    public List<AppstreamIcon> Icons { get; set; } = new();

    public List<AppstreamScreenshot> Screenshots { get; set; } = new();

    public List<AppstreamRelease> Releases { get; set; } = new();

    public Dictionary<string, string> Urls { get; set; } = new();
    
    public bool IsVerified { get; set; }

    public string VerificationMethod { get; set; } = string.Empty;

    public List<FlatpakRemoteDto> Remotes { get; set; } = [];
}

/// <summary>
/// Represents an icon for an appstream application
/// </summary>
public class AppstreamIcon
{
    public string Type { get; set; } = string.Empty;

    public string Url { get; set; } = string.Empty;

    public int Width { get; set; }

    public int Height { get; set; }

    public int Scale { get; set; } = 1;
}

/// <summary>
/// Represents a screenshot for an appstream application
/// </summary>
public class AppstreamScreenshot
{
    public string Caption { get; set; } = string.Empty;

    public bool IsDefault { get; set; }

    public List<AppstreamImage> Images { get; set; } = new();
}

/// <summary>
/// Represents an image in a screenshot
/// </summary>
public class AppstreamImage
{
    public string Type { get; set; } = string.Empty;
    
    public string Url { get; set; } = string.Empty;
    
    public int Width { get; set; }
    
    public int Height { get; set; }
}

/// <summary>
/// Represents a release/version entry for an appstream application
/// </summary>
public class AppstreamRelease
{
    public string Version { get; set; } = string.Empty;
    
    public string Type { get; set; } = string.Empty;

    public long Timestamp { get; set; }
    
    public string Description { get; set; } = string.Empty;
}