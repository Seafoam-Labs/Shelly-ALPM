using System.Text.Json;
using PackageManager.Alpm;
using PackageManager.Alpm.Questions;
using PackageManager.Aur;
using PackageManager.Utilities.PkgBuild;
using Pastel;
using Shelly.Cli.Interactions;
using Shelly.Utilities.Eventing;

namespace Shelly.Cli;

public static class QuestionHandler
{
    /// <summary>
    /// Overload allowing every command to wire <c>manager.PkgbuildDiffRequest</c> through
    /// the same single entry point as the ALPM <c>Question</c> event.
    /// </summary>
    public static void HandleQuestion(PkgbuildDiffRequestEventArgs args, bool uiMode = false, bool noConfirm = false)
        => HandlePkgbuildDiff(args, uiMode, noConfirm);

    public static void HandlePkgbuildDiff(PkgbuildDiffRequestEventArgs args, bool uiMode, bool noConfirm)
    {
        if (noConfirm)
        {
            PrintWarnings(args.Warnings);
            args.ProceedWithUpdate = args.Warnings.Count <= 0;
            return;
        }

        if (!uiMode)
        {
            PackageBuilderDiffGenerator.PrintUnifiedDiff(args.OldPkgbuild, args.NewPkgbuild, isUiMode: false);
            PrintWarnings(args.Warnings);
            args.ProceedWithUpdate = Confirm.Execute(
                $"Proceed with update to {args.PackageName}?",
                // A careless Enter must not auto-approve a risky scriptlet.
                defaultValue: args.Warnings.Count == 0);
            return;
        }

        // UiMode: emit a framed PkgbuildDiffQuestionDto on stdout, block on the matching answer.
        var warnings = args.Warnings
            .Select(w => new PkgbuildWarningDto(
                w.Tool, w.Severity.ToString(), w.Hook, w.MatchedLine, w.Message))
            .ToList();

        var id = Guid.NewGuid().ToString("N");
        var diffLines = PackageBuilderDiffGenerator.BuildUnifiedDiffLines(args.OldPkgbuild, args.NewPkgbuild).ToList();
        JsonPackFrame.WriteToStdout<QuestionRequest>(new PkgbuildDiffQuestionDto(
            id, args.PackageName, args.OldPkgbuild, args.NewPkgbuild, warnings, diffLines));

        var resp = ReadAnswer<PkgbuildDiffAnswer>(id);
        args.ProceedWithUpdate = resp.ProceedWithUpdate;
    }

    /// <summary>
    /// Renders PostInstallValidator findings (npm/curl/etc. used in post_install)
    /// next to the diff so the interactive user sees them before confirming.
    /// </summary>
    private static void PrintWarnings(IReadOnlyList<ValidationFinding> warnings)
    {
        if (warnings.Count == 0) return;

        var supportsAnsi = AnsiUtilities.SupportsAnsi;
        var header =
            "Install scriptlet warnings \u2014 these commands fetch/execute code outside pacman's control:";
        Console.WriteLine(supportsAnsi ? header.Pastel(ConsoleColor.Red) : header);

        foreach (var w in warnings)
        {
            var color = w.Severity == ValidationSeverity.Critical ? ConsoleColor.Red : ConsoleColor.Yellow;
            var line = $"  \u2022 {w.Tool} used in {w.Hook}";
            Console.WriteLine(supportsAnsi ? line.Pastel(color) : line);
            if (!string.IsNullOrWhiteSpace(w.Message))
                Console.WriteLine($"    {w.Message}");
            var matched = $"    {w.MatchedLine}";
            Console.WriteLine(supportsAnsi ? matched.Pastel(ConsoleColor.Gray) : matched);
        }
    }

    /// <summary>
    /// Blocking loop on stdin — discards frames whose <c>QuestionId</c> does not match,
    /// returning the first matching answer of the expected type.
    /// </summary>
    private static T ReadAnswer<T>(string id) where T : QuestionResponseDto
    {
        while (true)
        {
            var resp = JsonPackFrame.ReadFromStdin<QuestionResponseDto>();
            if (resp is T t && t.QuestionId == id) return t;
            // Stale or unknown answer — ignore and keep reading.
        }
    }

    public static void HandleQuestion(AlpmQuestionEventArgs question, bool uiMode = false, bool noConfirm = false)
    {
        //This makes questions work for now till we can convert over to standard eventing.
        //There is something broken in the log priming on one of the sides that prevents this from working well
        Console.WriteLine($"Presenting Question.");
        switch (question.QuestionType)
        {
            case AlpmQuestionType.SelectProvider:
                HandleProviderSelection(question, uiMode, noConfirm);
                break;
            case AlpmQuestionType.SelectOptionalDeps:
                HandleOptionalDependencySelection(question, uiMode, noConfirm);
                break;
            case AlpmQuestionType.ReplacePkg:
            case AlpmQuestionType.ConflictPkg:
            case AlpmQuestionType.InstallIgnorePkg:
            case AlpmQuestionType.CorruptedPkg:
            case AlpmQuestionType.ImportKey:
            default:
                HandleYesNoQuestion(question, uiMode, noConfirm);
                break;
        }
    }

    private static void HandleOptionalDependencySelection(AlpmQuestionEventArgs question, bool uiMode = false,
        bool noConfirm = false)
    {
        if (question.ProviderOptions is null)
        {
            throw new ArgumentNullException(nameof(question.ProviderOptions),
                "Cannot have a selection while provider options is null!");
        }

        var visible = question.ProviderOptions
            .Select((o, i) => (Option: o, OriginalIndex: i))
            .Where(t => !t.Option.IsInstalled)
            .ToList();

        if (visible.Count == 0)
        {
            var none = question.ProviderOptions
                .Select(o => o with { IsSelected = false })
                .ToList();
            question.SetResponse(new QuestionResponse(0, none));
            return;
        }

        if (uiMode)
        {
            if (noConfirm)
            {
                var noneSelected = question.ProviderOptions
                    .Select(o => o with { IsSelected = false })
                    .ToList();
                question.SetResponse(new QuestionResponse(0, noneSelected));
                return;
            }

            Console.Error.WriteLine($"[ALPM_SELECT_OPTDEPS]{question.DependencyName}");
            for (var i = 0; i < question.ProviderOptions.Count; i++)
            {
                var o = question.ProviderOptions[i];
                var desc = o.Description ?? string.Empty;
                var installed = o.IsInstalled ? "1" : "0";
                var selected = o.IsSelected ? "1" : "0";
                Console.Error.WriteLine(
                    $"[ALPM_OPTDEPS_OPTION]{i}\u001F{o.Name}\u001F{desc}\u001F{installed}\u001F{selected}");
            }

            Console.Error.WriteLine("[ALPM_OPTDEPS_END]");
            Console.Error.Flush();
            var input = Console.ReadLine();
            var selectedIndices = ParseSelectedIndices(input);
            var uiSelected = question.ProviderOptions
                .Select((o, i) => o with { IsSelected = selectedIndices.Contains(i) && !o.IsInstalled })
                .ToList();
            question.SetResponse(new QuestionResponse(0, uiSelected));
            return;
        }

        if (noConfirm)
        {
            var noneSelected = question.ProviderOptions
                .Select(o => o with { IsSelected = false })
                .ToList();
            question.SetResponse(new QuestionResponse(0, noneSelected));
            return;
        }

        var visiblOptions = visible.Select(t => t.Option).ToList();
        var selection = DependussyMultiSelect.Execute("Select optional dependencies", visiblOptions);

        var selectedNames = selection
            .Where(o => o.IsSelected)
            .Select(o => o.Name)
            .ToHashSet();
        var selectedOptions = question.ProviderOptions
            .Select(o => o with { IsSelected = selectedNames.Contains(o.Name) && !o.IsInstalled })
            .ToList();

        question.SetResponse(new QuestionResponse(0, selectedOptions));
    }

    private static HashSet<int> ParseSelectedIndices(string? input)
    {
        if (string.IsNullOrWhiteSpace(input)) return [];
        try
        {
            var arr = JsonSerializer.Deserialize(input!, ShellyCliJsonContext.Default.Int32Array);
            return arr is null ? new HashSet<int>() : new HashSet<int>(arr);
        }
        catch
        {
            return [];
        }
    }

    private static void HandleProviderSelection(AlpmQuestionEventArgs question, bool uiMode = false,
        bool noConfirm = false)
    {
        if (question.ProviderOptions is null)
            throw new ArgumentNullException(nameof(question.ProviderOptions),
                "Cannot have a selection while provider options is null!");
        if (uiMode)
        {
            if (noConfirm)
            {
                question.SetResponse(new QuestionResponse(0, question.ProviderOptions));
                return;
            }

            Console.Error.WriteLine($"[ALPM_SELECT_PROVIDER]{question.DependencyName}");
            for (int i = 0; i < question.ProviderOptions.Count; i++)
            {
                Console.Error.WriteLine($"[ALPM_PROVIDER_OPTION]{i}\u001F{question.ProviderOptions[i].Name}");
            }

            Console.Error.WriteLine("[ALPM_PROVIDER_END]");
            Console.Error.Flush();
            var input = Console.ReadLine();
            if (int.TryParse(input?.Trim(), out var idx))
            {
                question.SetResponse(new QuestionResponse(idx, question.ProviderOptions));
            }
            else
            {
                // If input is empty or invalid, we don't call SetResponse
                // The underlying ALPM logic should decide how to handle timeout or abort
                // But in UI mode, we usually expect a response
                // For safety, we could set a default if needed, but the UI shouldn't send empty input
            }

            return;
        }

        if (noConfirm)
        {
            question.SetResponse(new QuestionResponse(0, question.ProviderOptions));
            return;
        }

        var providerNames = question.ProviderOptions.Select(o => o.Name).ToList();
        var selection = BasicSelection.Execute("Select provider", providerNames);
        question.SetResponse(new QuestionResponse(selection, question.ProviderOptions));
    }


    private static void HandleYesNoQuestion(AlpmQuestionEventArgs question, bool uiMode = false,
        bool noConfirm = false)
    {
        if (uiMode)
        {
            if (noConfirm)
            {
                question.SetResponse(new QuestionResponse(1, null));
                return;
            }

            switch (question.QuestionType)
            {
                case AlpmQuestionType.ConflictPkg:
                    Console.Error.WriteLine($"[ALPM_QUESTION_CONFLICT]{question.QuestionText}");
                    break;
                case AlpmQuestionType.ReplacePkg:
                    Console.Error.WriteLine($"[ALPM_QUESTION_REPLACEPKG]{question.QuestionText}");
                    break;
                case AlpmQuestionType.CorruptedPkg:
                    Console.Error.WriteLine($"[ALPM_QUESTION_CORRUPTEDPKG]{question.QuestionText}");
                    break;
                case AlpmQuestionType.ImportKey:
                    Console.Error.WriteLine($"[ALPM_QUESTION_IMPORTKEY]{question.QuestionText}");
                    break;
                case AlpmQuestionType.SelectProvider:
                    throw new Exception("Select provider is never a y / n question and is being invoked as one.");
                case AlpmQuestionType.RemovePkgs:
                    Console.Error.WriteLine($"[ALPM_QUESTION_REMOVEPKG]{question.QuestionText}");
                    break;
                case AlpmQuestionType.InstallIgnorePkg:
                default:
                    Console.Error.WriteLine($"[ALPM_QUESTION]{question.QuestionText}");
                    break;
            }

            Console.Error.Flush();
            var input = Console.ReadLine();
            Console.WriteLine($"Received: {input}");
            if (input is "y" or "Y")
            {
                question.SetResponse(new QuestionResponse(1, null));
            }
            else if (input is "n" or "N")
            {
                question.SetResponse(new QuestionResponse(0, null));
            }

            return;
        }

        if (noConfirm)
        {
            question.SetResponse(new QuestionResponse(1, null));
            return;
        }

        var response = Confirm.Execute(question.QuestionText);
        question.SetResponse(new QuestionResponse(response ? 1 : 0, null));
    }
}