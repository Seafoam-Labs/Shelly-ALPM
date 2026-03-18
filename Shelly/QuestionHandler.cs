using PackageManager.Alpm;

namespace Shelly;

public class QuestionHandler
{
    private static bool IsInteractiveTerminal()
    {
        try
        {
            return !Console.IsInputRedirected
                && !Console.IsOutputRedirected
                && Console.WindowWidth > 0;
        }
        catch
        {
            return false;
        }
    }

    public static void HandleReplacePkg(AlpmReplacesEventArgs replaceArgs, bool uiMode = false, bool noConfirm = false)
    {
        if (uiMode)
        {
            foreach (var replace in replaceArgs.Replaces)
            {
                if (noConfirm)
                {
                    Console.Error.WriteLine(
                        $"Replacement: {replaceArgs.Repository}/{replaceArgs.PackageName} replaces {replace}");
                    continue;
                }

                Console.Error.WriteLine(
                    $"[ALPM_QUESTION_REPLACEPKG]{replaceArgs.Repository}/{replaceArgs.PackageName} replaces {replace}");
                Console.Error.Flush();
                var input = Console.ReadLine();
                Console.WriteLine($"Received: {input}");
            }
            return;
        }

        if (noConfirm)
        {
            foreach (var replace in replaceArgs.Replaces)
            {
                Console.WriteLine(
                    $"Replacement: {replaceArgs.Repository}/{replaceArgs.PackageName} replaces {replace}");
            }
            return;
        }

        var toRemove = new List<string>();
        foreach (var replace in replaceArgs.Replaces)
        {
            var accepted = IsInteractiveTerminal()
                ? ShowYesNoSelection($"Replace {replace} with {replaceArgs.Repository}/{replaceArgs.PackageName}?")
                : ShowConfirmPrompt($"Replace {replace} with {replaceArgs.Repository}/{replaceArgs.PackageName}?");
            if (!accepted)
            {
                toRemove.Add(replace);
            }
        }

        foreach (var replace in toRemove)
        {
            replaceArgs.Replaces.Remove(replace);
        }
    }
    public static void HandleQuestion(AlpmQuestionEventArgs question, bool uiMode = false, bool noConfirm = false)
    {
        switch (question.QuestionType)
        {
            case AlpmQuestionType.SelectProvider:
                HandleProviderSelection(question, uiMode, noConfirm);
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
    
    private static int ShowSelectionPrompt(string title, IList<string> choices)
    {
        int selected = 0;
        bool done = false;
        string numberBuffer = "";

        Console.CursorVisible = false;
        Console.WriteLine(title);
        int startRow = Console.CursorTop;

        void Render()
        {
            Console.SetCursorPosition(0, startRow);
            for (int i = 0; i < choices.Count; i++)
            {
                if (i == selected)
                {
                    Console.ForegroundColor = ConsoleColor.Black;
                    Console.BackgroundColor = ConsoleColor.Cyan;
                    Console.Write($" > {i + 1}) {choices[i]}");
                    Console.ResetColor();
                    Console.Write(new string(' ', Math.Max(0, Console.WindowWidth - Console.CursorLeft)));
                    Console.WriteLine();
                }
                else
                {
                    Console.Write($"   {i + 1}) {choices[i]}");
                    Console.Write(new string(' ', Math.Max(0, Console.WindowWidth - Console.CursorLeft)));
                    Console.WriteLine();
                }
            }

            if (numberBuffer.Length > 0)
                Console.Write($"  # {numberBuffer}");
            else
                Console.Write(new string(' ', 20));

            Console.SetCursorPosition(0, startRow + choices.Count);
        }

        Render();

        while (!done)
        {
            var key = Console.ReadKey(intercept: true);

            switch (key.Key)
            {
                case ConsoleKey.UpArrow:
                    numberBuffer = "";
                    selected = (selected - 1 + choices.Count) % choices.Count;
                    break;
                case ConsoleKey.DownArrow:
                    numberBuffer = "";
                    selected = (selected + 1) % choices.Count;
                    break;
                case ConsoleKey.Enter:
                    done = true;
                    break;
                case ConsoleKey.Backspace:
                    if (numberBuffer.Length > 0)
                        numberBuffer = numberBuffer[..^1];
                    break;
                default:
                    if (char.IsDigit(key.KeyChar))
                    {
                        numberBuffer += key.KeyChar;
                        if (int.TryParse(numberBuffer, out int num) && num >= 1 && num <= choices.Count)
                        {
                            selected = num - 1;
                        }
                    }
                    break;
            }

            Render();
        }

        Console.CursorVisible = true;
        Console.WriteLine();
        return selected;
    }


    private static bool ShowYesNoSelection(string title, bool defaultValue = true)
    {
        bool selected = defaultValue;
        bool done = false;

        Console.CursorVisible = false;
        Console.WriteLine(title);
        int startRow = Console.CursorTop;

        void Render()
        {
            Console.SetCursorPosition(0, startRow);

            if (selected)
            {
                Console.ForegroundColor = ConsoleColor.Black;
                Console.BackgroundColor = ConsoleColor.Cyan;
                Console.Write(" > Yes");
                Console.ResetColor();
                Console.Write("   No");
            }
            else
            {
                Console.Write("   Yes");
                Console.ForegroundColor = ConsoleColor.Black;
                Console.BackgroundColor = ConsoleColor.Cyan;
                Console.Write(" > No");
                Console.ResetColor();
            }

            Console.Write(new string(' ', Math.Max(0, Console.WindowWidth - Console.CursorLeft)));
            Console.SetCursorPosition(0, startRow);
        }

        Render();

        while (!done)
        {
            var key = Console.ReadKey(intercept: true);

            switch (key.Key)
            {
                case ConsoleKey.LeftArrow:
                    selected = true;
                    break;
                case ConsoleKey.RightArrow:
                    selected = false;
                    break;
                case ConsoleKey.Enter:
                    done = true;
                    break;
                case ConsoleKey.Y:
                    selected = true;
                    done = true;
                    break;
                case ConsoleKey.N:
                    selected = false;
                    done = true;
                    break;
            }

            Render();
        }

        Console.CursorVisible = true;
        Console.WriteLine();
        return selected;
    }

    private static bool ShowConfirmPrompt(string title, bool defaultValue = true)
    {
        string hint = defaultValue ? "[Y/n]" : "[y/N]";
        Console.Write($"{title} {hint} ");

        while (true)
        {
            var key = Console.ReadKey(intercept: true);
            switch (key.KeyChar)
            {
                case 'y' or 'Y':
                    Console.WriteLine("y");
                    return true;
                case 'n' or 'N':
                    Console.WriteLine("n");
                    return false;
                default:
                    if (key.Key == ConsoleKey.Enter)
                    {
                        Console.WriteLine(defaultValue ? "y" : "n");
                        return defaultValue;
                    }
                    break;
            }
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
            return;
        }

        if (noConfirm)
        {
            question.SetResponse(0);
            return;
        }

        var selectedIndex = IsInteractiveTerminal()
            ? ShowSelectionPrompt(question.QuestionText ?? "Select a provider:", question.ProviderOptions!)
            : ShowSimpleSelectionPrompt(question.QuestionText ?? "Select a provider:", question.ProviderOptions!);
        question.SetResponse(selectedIndex);
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

        var response = IsInteractiveTerminal()
            ? ShowYesNoSelection(question.QuestionText ?? "Confirm?", defaultValue: true)
            : ShowConfirmPrompt(question.QuestionText ?? "Confirm?", defaultValue: true);
        question.SetResponse(response ? 1 : 0);
    }

    private static int ShowSimpleSelectionPrompt(string title, IList<string> choices)
    {
        Console.WriteLine(title);
        for (int i = 0; i < choices.Count; i++)
        {
            Console.WriteLine($"  {i + 1}) {choices[i]}");
        }

        while (true)
        {
            Console.Write($"Enter a number (1-{choices.Count}): ");
            var input = Console.ReadLine();
            if (int.TryParse(input?.Trim(), out int num) && num >= 1 && num <= choices.Count)
            {
                return num - 1;
            }
            Console.WriteLine("Invalid selection, try again.");
        }
    }
}