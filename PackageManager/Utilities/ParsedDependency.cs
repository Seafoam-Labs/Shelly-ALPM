using System.Text.RegularExpressions;

namespace PackageManager.Utilities;

public record ParsedDependency(string Name, string? Operator, string? Version)
{
    private static readonly Regex Pattern = new(@"^([a-zA-Z0-9@._+\-]+)(>=|<=|=|>|<)(.+)$");

    public static ParsedDependency Parse(string dependency)
    {
        var match = Pattern.Match(dependency);
        return match.Success
            ? new ParsedDependency(match.Groups[1].Value.Trim(), match.Groups[2].Value.Trim(), match.Groups[3].Value.Trim())
            : new ParsedDependency(dependency.Trim(), null, null);
    }

    public bool IsSatisifiedBy(string installedVersion)
    {
        if (Operator is null)
        {
            return true;
        }

        var compare = VersionComparer.Compare(installedVersion, Version);
        return Operator switch
        {
            ">=" => compare >= 0,
            "<=" => compare <= 0,
            ">" => compare > 0,
            "<" => compare < 0,
            "=" => compare == 0,
            _ => true
        };
    }

    public override string ToString() =>
        Operator is null || Version is null ? Name : $"{Name}{Operator}{Version}";
}