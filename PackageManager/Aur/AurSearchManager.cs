using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using PackageManager.Aur.Models;

namespace PackageManager.Aur;

public class AurSearchManager : IAurSearchManager, IDisposable
{
    private readonly HttpClient _httpClient;
    private const string BaseUrl = "https://aur.archlinux.org/rpc/";

    public AurSearchManager(HttpClient httpClient)
    {
        _httpClient = httpClient;
    }

    public async Task<AurResponse<AurPackageDto>> SearchAsync(string query,
        CancellationToken cancellationToken = default)
    {
        var url = $"{BaseUrl}?v=5&type=search&arg={Uri.EscapeDataString(query)}&by=name-desc";
        var response =
            await _httpClient.GetFromJsonAsync(url, AurJsonContext.Default.AurResponseAurPackageDto, cancellationToken);
        return response ?? new AurResponse<AurPackageDto> { Type = "error", Error = "Empty response" };
    }

    public async Task<List<string>> SuggestAsync(string query,
        CancellationToken cancellationToken = default)
    {
        var url = $"{BaseUrl}?v=5&type=suggest&arg={Uri.EscapeDataString(query)}";
        return await _httpClient.GetFromJsonAsync(url, AurJsonContext.Default.ListString, cancellationToken) ?? [];
    }

    public async Task<List<string>>SuggestByPackageBaseNamesAsync(string query,
        CancellationToken cancellationToken = default)
    {
        var url = $"{BaseUrl}?v=5&type=suggest-pkgbase&arg={Uri.EscapeDataString(query)}";
        return await _httpClient.GetFromJsonAsync(url, AurJsonContext.Default.ListString, cancellationToken) ?? [];
    }

    public async Task<AurResponse<AurPackageDto>> GetInfoAsync(IEnumerable<string> packageNames,
        CancellationToken cancellationToken = default)
    {
        var names = packageNames.ToList();
        if (names.Count == 0)
        {
            return new AurResponse<AurPackageDto> { Type = "info", Results = [] };
        }

        const int chunkSize = 100;
        var allResults = new List<AurPackageDto>();
        var resultType = "info";

        for (var i = 0; i < names.Count; i += chunkSize)
        {
            var chunk = names.Skip(i).Take(chunkSize).ToList();

            var form = new List<KeyValuePair<string, string>>(chunk.Count + 2)
            {
                new("v", "5"),
                new("type", "info"),
            };
            foreach (var name in chunk)
            {
                form.Add(new KeyValuePair<string, string>("arg[]", name));
            }

            using var content = new FormUrlEncodedContent(form);

            AurResponse<AurPackageDto>? response;
            try
            {
                using var httpResponse = await _httpClient.PostAsync(BaseUrl, content, cancellationToken);
                httpResponse.EnsureSuccessStatusCode();

                response = await httpResponse.Content.ReadFromJsonAsync(
                    AurJsonContext.Default.AurResponseAurPackageDto, cancellationToken);
            }
            catch (HttpRequestException ex)
            {
                await Console.Error.WriteLineAsync($"AUR RPC request failed: {ex.Message}");
                return new AurResponse<AurPackageDto>
                {
                    Type = "error",
                    Error = ex.Message,
                    Results = allResults,
                    ResultCount = allResults.Count,
                };
            }
            catch (TaskCanceledException ex)
            {
                await Console.Error.WriteLineAsync($"AUR RPC request timed out: {ex.Message}");
                return new AurResponse<AurPackageDto>
                {
                    Type = "error",
                    Error = "timeout",
                    Results = allResults,
                    ResultCount = allResults.Count,
                };
            }
            catch (JsonException ex)
            {
                await Console.Error.WriteLineAsync($"AUR RPC returned non-JSON body: {ex.Message}");
                return new AurResponse<AurPackageDto>
                {
                    Type = "error",
                    Error = ex.Message,
                    Results = allResults,
                    ResultCount = allResults.Count,
                };
            }

            if (response == null) continue;

            if (response.Type == "error")
            {
                return response;
            }

            resultType = response.Type;
            if (response.Results != null)
            {
                allResults.AddRange(response.Results);
            }
        }

        return new AurResponse<AurPackageDto>
        {
            Type = resultType,
            ResultCount = allResults.Count,
            Results = allResults
        };
    }

    public async Task<string> GetPackageBaseAsync(string pkgname, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(pkgname))
        {
            return pkgname;
        }

        try
        {
            var response = await GetInfoAsync([pkgname], cancellationToken);
            var first = response.Results?.FirstOrDefault();
            if (first is not null && !string.IsNullOrEmpty(first.PackageBase))
            {
                return first.PackageBase;
            }
        }
        catch (Exception ex)
        {
            await Console.Error.WriteLineAsync(
                $"AUR RPC pkgbase lookup failed for '{pkgname}': {ex.Message}");
        }

        return pkgname;
    }

    public async Task<List<string>> FindProvidersAsync(string name, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            return new List<string>();
        }

        
        try
        {
            var info = await GetInfoAsync([name], cancellationToken);
            var direct = info.Results?.FirstOrDefault();
            if (direct is not null && !string.IsNullOrEmpty(direct.Name))
            {
                return new List<string> { direct.Name };
            }
        }
        catch (Exception ex)
        {
            await Console.Error.WriteLineAsync(
                $"AUR RPC info lookup failed for '{name}': {ex.Message}");
        }

        
        var url = $"{BaseUrl}?v=5&type=search&by=provides&arg={Uri.EscapeDataString(name)}";
        try
        {
            var response = await _httpClient.GetFromJsonAsync(
                url, AurJsonContext.Default.AurResponseAurPackageDto, cancellationToken);
            return response?.Results?
                .Select(r => r.Name)
                .Where(n => !string.IsNullOrEmpty(n))
                .Distinct()
                .ToList() ?? new List<string>();
        }
        catch (Exception ex)
        {
            await Console.Error.WriteLineAsync(
                $"AUR RPC provides search failed for '{name}': {ex.Message}");
            return new List<string>();
        }
    }

    public void Dispose()
    {
        _httpClient.Dispose();
    }
}