using ConsoleAppFramework;

using Shelly;


var app = ConsoleApp.Create();
app.ConfigureGlobalOptions((ref builder) =>
{
    var verbose = builder.AddGlobalOption<bool>("-v|--verbose");
    var uiMode = builder.AddGlobalOption<bool>("--ui-mode");
    return new GlobalOptions(verbose, uiMode);
});

await app.RunAsync(args);