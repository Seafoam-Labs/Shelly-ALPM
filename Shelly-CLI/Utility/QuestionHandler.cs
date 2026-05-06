using PackageManager.Alpm;
using Spectre.Console;

namespace Shelly_CLI.Utility;

public static class QuestionHandler
{
    public static void HandleQuestion(AlpmQuestionEventArgs question, bool uiMode = false, bool noConfirm = false)
    {
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
        var bitmask = 0;
        if (question.ProviderOptions is null)
        {
            throw new ArgumentNullException(nameof(question.ProviderOptions),
                "Cannot have a selection while provider options is null!");
        }

        if (uiMode)
        {
            if (noConfirm)
            {
                question.SetResponse((int)((1L << 31) - 1));
                return;
            }

            Console.Error.WriteLine($"[ALPM_SELECT_OPTDEPS]{question.DependencyName}");
            for (var i = 0; i < question.ProviderOptions.Count; i++)
            {
                Console.Error.WriteLine($"[ALPM_OPTDEPS_OPTION]{i}:{question.ProviderOptions[i]}");
            }

            Console.Error.WriteLine("[ALPM_OPTDEPS_END]");
            Console.Error.Flush();
            var input = Console.ReadLine();
            var splitInput = input?.Split(" ");
            for (var i = 0; i < question.ProviderOptions.Count; i++)
            {
                if (splitInput.Contains(question.ProviderOptions[i]))
                {
                    bitmask |= (1 << i);
                }
            }

            question.SetResponse(bitmask);
            return;
        }

        var selection = AnsiConsole.Prompt(
            new MultiSelectionPrompt<string>()
                .Title($"[yellow]{question.QuestionText}[/]")
                .NotRequired()                       // <-- allow zero selections
                .InstructionsText(
                    "[grey](Press [blue]<space>[/] to toggle, " +
                    "[green]<enter>[/] to accept — leave empty to install none)[/]")
                .AddChoices(question.ProviderOptions!));
        for (var i = 0; i < question.ProviderOptions.Count; i++)
        {
            if (selection.Contains(question.ProviderOptions[i]))
            {
                bitmask |= (1 << i);
            }
        }

        question.SetResponse(bitmask);
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
                question.SetResponse(0);
                return;
            }

            Console.Error.WriteLine($"[ALPM_SELECT_PROVIDER]{question.DependencyName}");
            for (int i = 0; i < question.ProviderOptions.Count; i++)
            {
                Console.Error.WriteLine($"[ALPM_PROVIDER_OPTION]{i}:{question.ProviderOptions[i]}");
            }

            Console.Error.WriteLine("[ALPM_PROVIDER_END]");
            Console.Error.Flush();
            var input = Console.ReadLine();
            if (int.TryParse(input?.Trim(), out var idx))
            {
                question.SetResponse(idx);
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

        var selection = AnsiConsole.Prompt(
            new SelectionPrompt<string>()
                .Title($"[yellow]{question.QuestionText}[/]")
                .AddChoices(question.ProviderOptions!));
        question.SetResponse(question.ProviderOptions!.IndexOf(selection));
    }


    private static void HandleYesNoQuestion(AlpmQuestionEventArgs question, bool uiMode = false,
        bool noConfirm = false)
    {
        if (uiMode)
        {
            if (noConfirm)
            {
                question.SetResponse(1);
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
                question.SetResponse(1);
            }
            else if (input is "n" or "N")
            {
                question.SetResponse(0);
            }

            return;
        }

        if (noConfirm)
        {
            question.SetResponse(1);
            return;
        }

        var response = AnsiConsole.Confirm($"[yellow]{question.QuestionText}[/]", defaultValue: true);
        question.SetResponse(response ? 1 : 0);
    }
}