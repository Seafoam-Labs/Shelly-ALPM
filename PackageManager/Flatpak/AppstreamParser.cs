using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Xml.Linq;

namespace PackageManager.Flatpak;

/// <summary>
/// Parser for Flatpak appstream XML metadata
/// </summary>
public class AppstreamParser
{
    /// <summary>
    /// Parses appstream XML from a file path (supports both .xml and .xml.gz)
    /// </summary>
    /// <param name="filePath">Path to the appstream file</param>
    /// <returns>List of parsed applications</returns>
    public List<AppstreamApp> ParseFile(string filePath)
    {
        if (!File.Exists(filePath))
        {
            throw new FileNotFoundException($"Appstream file not found: {filePath}");
        }

        Stream stream;
        if (filePath.EndsWith(".gz", StringComparison.OrdinalIgnoreCase))
        {
            stream = new GZipStream(File.OpenRead(filePath), CompressionMode.Decompress);
        }
        else
        {
            stream = File.OpenRead(filePath);
        }

        using (stream)
        {
            return ParseStream(stream);
        }
    }

    /// <summary>
    /// Parses appstream XML from a stream
    /// </summary>
    /// <param name="stream">Stream containing appstream XML data</param>
    /// <returns>List of parsed applications</returns>
    private List<AppstreamApp> ParseStream(Stream stream)
    {
        var apps = new List<AppstreamApp>();
        var doc = XDocument.Load(stream);

        var components = doc.Root?.Elements("component");
        if (components == null)
        {
            return apps;
        }

        foreach (var component in components)
        {
            var app = ParseComponent(component);
            if (app != null)
            {
                apps.Add(app);
            }
        }

        return apps;
    }

    /// <summary>
    /// Parses a single component element
    /// </summary>
    private AppstreamApp? ParseComponent(XElement component)
    {
        var type = component.Attribute("type")?.Value;

        // Only parse desktop applications by default
        if (type != "desktop-application" && type != "console-application")
        {
            return null;
        }

        var app = new AppstreamApp
        {
            Type = type,
            Id = component.Element("id")?.Value ?? string.Empty,
            Name = component.Elements("name")
                .FirstOrDefault(e => e.Attribute(XNamespace.Xml + "lang") == null)?.Value ?? string.Empty,
            Summary = component.Elements("summary")
                .FirstOrDefault(e => e.Attribute(XNamespace.Xml + "lang") == null)?.Value ?? string.Empty,
            ProjectLicense = component.Element("project_license")?.Value ?? string.Empty,
            DeveloperName = component.Element("developer_name")?.Value
                ?? component.Element("developer")?.Element("name")?.Value
                ?? string.Empty,
        };

        // Parse description
        var descriptionElement = component.Elements("description")
            .FirstOrDefault(e => e.Attribute(XNamespace.Xml + "lang") == null);

        if (descriptionElement != null)
        {
            app.Description = ParseDescription(descriptionElement);
        }

        // Parse categories
        var categoriesElement = component.Element("categories");
        if (categoriesElement != null)
        {
            app.Categories = categoriesElement.Elements("category")
                .Select(c => c.Value)
                .ToList();
        }

        // Parse keywords
        var keywordsElement = component.Element("keywords");
        if (keywordsElement != null)
        {
            app.Keywords = keywordsElement.Elements("keyword")
                .Select(k => k.Value)
                .ToList();
        }

        // Parse URLs
        foreach (var url in component.Elements("url"))
        {
            var urlType = url.Attribute("type")?.Value;
            if (!string.IsNullOrEmpty(urlType))
            {
                app.Urls[urlType] = url.Value;
            }
        }

        // Parse icons
        app.Icons = component.Elements("icon")
            .Select(ParseIcon)
            .Where(i => i != null)
            .Cast<AppstreamIcon>()
            .ToList();

        // Parse screenshots
        app.Screenshots = component.Elements("screenshots")
            .SelectMany(s => s.Elements("screenshot"))
            .Select(ParseScreenshot)
            .ToList();

        // Parse releases
        var releasesElement = component.Element("releases");
        if (releasesElement != null)
        {
            app.Releases = releasesElement.Elements("release")
                .Select(ParseRelease)
                .ToList();
        }

        // Parse custom verification metadata (Flathub-specific)
        var customElement = component.Element("custom");
        if (customElement != null)
        {
            var verifiedValue = customElement.Elements("value")
                .FirstOrDefault(v => v.Attribute("key")?.Value == "flathub::verification::verified");

            if (verifiedValue != null && verifiedValue.Value.Equals("true", StringComparison.OrdinalIgnoreCase))
            {
                app.IsVerified = true;

                var methodValue = customElement.Elements("value")
                    .FirstOrDefault(v => v.Attribute("key")?.Value == "flathub::verification::method");
                if (methodValue != null)
                {
                    app.VerificationMethod = methodValue.Value;
                }
            }
        }

        return app;
    }

    /// <summary>
    /// Parses description element and converts to plain text
    /// </summary>
    private string ParseDescription(XElement description)
    {
        var parts = new List<string>();

        foreach (var element in description.Elements())
        {
            if (element.Name == "p")
            {
                parts.Add(element.Value.Trim());
            }
            else if (element.Name == "ul")
            {
                foreach (var li in element.Elements("li"))
                {
                    parts.Add("• " + li.Value.Trim());
                }
            }
            else if (element.Name == "ol")
            {
                var index = 1;
                foreach (var li in element.Elements("li"))
                {
                    parts.Add($"{index}. " + li.Value.Trim());
                    index++;
                }
            }
        }

        return string.Join("\n\n", parts);
    }

    /// <summary>
    /// Parses an icon element
    /// </summary>
    private AppstreamIcon? ParseIcon(XElement icon)
    {
        var type = icon.Attribute("type")?.Value;
        if (string.IsNullOrEmpty(type))
        {
            return null;
        }

        var appIcon = new AppstreamIcon
        {
            Type = type,
            Url = icon.Value
        };

        if (int.TryParse(icon.Attribute("width")?.Value, out var width))
        {
            appIcon.Width = width;
        }

        if (int.TryParse(icon.Attribute("height")?.Value, out var height))
        {
            appIcon.Height = height;
        }

        if (int.TryParse(icon.Attribute("scale")?.Value, out var scale))
        {
            appIcon.Scale = scale;
        }

        return appIcon;
    }

    /// <summary>
    /// Parses a screenshot element
    /// </summary>
    private AppstreamScreenshot ParseScreenshot(XElement screenshot)
    {
        var shot = new AppstreamScreenshot
        {
            IsDefault = screenshot.Attribute("type")?.Value == "default",
            Caption = screenshot.Element("caption")?.Value ?? string.Empty,
            Images = screenshot.Elements("image")
                .Select(ParseImage)
                .ToList()
        };

        return shot;
    }

    /// <summary>
    /// Parses an image element
    /// </summary>
    private AppstreamImage ParseImage(XElement image)
    {
        var img = new AppstreamImage
        {
            Type = image.Attribute("type")?.Value ?? string.Empty,
            Url = image.Value
        };

        if (int.TryParse(image.Attribute("width")?.Value, out var width))
        {
            img.Width = width;
        }

        if (int.TryParse(image.Attribute("height")?.Value, out var height))
        {
            img.Height = height;
        }

        return img;
    }

    /// <summary>
    /// Parses a release element
    /// </summary>
    private AppstreamRelease ParseRelease(XElement release)
    {
        var rel = new AppstreamRelease
        {
            Version = release.Attribute("version")?.Value ?? string.Empty,
            Type = release.Attribute("type")?.Value ?? string.Empty
        };

        if (long.TryParse(release.Attribute("timestamp")?.Value, out var timestamp))
        {
            rel.Timestamp = timestamp;
        }

        var descriptionElement = release.Element("description");
        if (descriptionElement != null)
        {
            rel.Description = ParseDescription(descriptionElement);
        }

        return rel;
    }
}
