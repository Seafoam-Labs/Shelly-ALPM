
namespace Shelly_CLI.Commands.Standard.Models;

public record RssModel
{
    public string? Title { get; init; }
    public string? Link { get; init; }
    public string? Description { get; init; }
    public string? PubDate { get; init; }
}