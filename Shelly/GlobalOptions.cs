namespace Shelly;

/// <summary>
/// Global
/// </summary>
/// <param name="Verbose">-v, full logging output</param>
/// <param name="UiMode">responds with only basic text and console inputs.</param>
public record GlobalOptions(bool Verbose = false, bool UiMode = false);