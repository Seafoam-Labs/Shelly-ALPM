namespace Shelly.Cli.Shortcodes;

public static class ShortcodeTranslator
{
    public static string[] Translate(string[] args)
    {
        if (args.Length == 0)
            return args;

        var token = args[0];

        if (token.Length < 3 || token[0] != '-')
            return args;

        var type = token[1];

        if (!ShortcodeMaps.Types.TryGetValue(type, out var group))
            return args;

        var action = token[2];

        if (!char.IsLetter(action))
            return args;

        var rest = args.Skip(1).ToArray();
        var modifiers = token[3..];

        if (type == 'K')
            return TranslateKeyring(action, modifiers, rest);

        if (!ShortcodeMaps.Actions.TryGetValue((type, action), out var verb))
            throw new ShortcodeException(
                $"Unknown shortcode action '{action}' for type '{type}'. Valid actions: {ValidActions(type)}");

        var allowed = ShortcodeMaps.Modifiers[(type, action)];

        var result = new List<string>();

        if (!string.IsNullOrEmpty(group))
            result.Add(group);

        result.Add(verb);

        foreach (var modifier in modifiers)
        {
            if (!allowed.Contains(modifier))
                throw new ShortcodeException(
                    $"Unknown modifier '{modifier}' for '{verb}'. Valid modifiers: {ValidModifiers(allowed)}");

            result.Add($"-{modifier}");
        }

        result.AddRange(rest);

        return result.ToArray();
    }

    private static string[] TranslateKeyring(char action, string modifiers, string[] rest)
    {
        if (modifiers.Length > 0)
            throw new ShortcodeException("Keyring shortcodes do not accept modifiers.");

        if (!ShortcodeMaps.KeyringActions.TryGetValue(action, out var keyringAction))
            throw new ShortcodeException(
                $"Unknown keyring action '{action}'. Valid actions: {string.Join(", ", ShortcodeMaps.KeyringActions.Keys)}");

        var result = new List<string> { "keyring", keyringAction };
        result.AddRange(rest);

        return result.ToArray();
    }

    private static string ValidActions(char type)
    {
        var actions = ShortcodeMaps.Actions.Keys
            .Where(key => key.Item1 == type)
            .Select(key => key.Item2.ToString());

        return string.Join(", ", actions);
    }

    private static string ValidModifiers(IReadOnlySet<char> allowed)
    {
        return allowed.Count == 0 ? "(none)" : string.Join(", ", allowed);
    }
}
