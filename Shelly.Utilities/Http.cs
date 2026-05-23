using System.Net.Http.Headers;
using System.Reflection;

namespace Shelly.Utilities;

public static class Http
{
    private static readonly string
        Version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(4) ?? "0.0.0.0";

    public static readonly ProductInfoHeaderValue UserAgent = new("Shelly-ALPM", Version);
}