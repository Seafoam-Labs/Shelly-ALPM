using System.Text;
using System.Text.RegularExpressions;
using System.Xml;

namespace Shelly_CLI.Utility;

internal static partial class HtmlToMarkdown
{
    public static string Convert(string html)
    {
        return new Converter().ConvertInternal(html);
    }

    [GeneratedRegex(@"\s+")]
    private static partial Regex SpaceRegex();

    private sealed class Converter
    {
        private readonly List<(string Id, string Url)> _references = [];
        private int _refCounter;

        public string ConvertInternal(string html)
        {
            var xml = $"<root>{html}</root>";
            var settings = new XmlReaderSettings
            {
                IgnoreWhitespace = false,
                DtdProcessing = DtdProcessing.Prohibit
            };

            var sb = new StringBuilder();

            using var reader = XmlReader.Create(new StringReader(xml), settings);
            ReadDocument(reader, sb);

            AppendReferences(sb);
            return sb.ToString().TrimEnd();
        }

        private void ReadDocument(XmlReader reader, StringBuilder sb)
        {
            while (reader.Read())
                switch (reader.NodeType)
                {
                    case XmlNodeType.Element:
                        if (reader.LocalName != "root")
                            AppendBlock(sb, ReadBlock(reader));
                        break;

                    case XmlNodeType.Text:
                    case XmlNodeType.CDATA:
                        sb.Append(reader.Value);
                        break;
                }
        }

        private string ReadBlock(XmlReader reader)
        {
            return reader.LocalName switch
            {
                "p" => ReadInlineContent(reader, "p"),
                "ul" => ReadList(reader, "ul", false),
                "ol" => ReadList(reader, "ol", true),
                "blockquote" => ReadBlockquote(reader),
                "h1" or "h2" or "h3" or "h4" or "h5" or "h6" => ReadHeading(reader),
                "a" => ReadAnchor(reader),
                "strong" or "b" => $"**{ReadInlineContent(reader, reader.LocalName)}**",
                "em" or "i" => $"*{ReadInlineContent(reader, reader.LocalName)}*",
                "code" => $"`{ReadInlineContent(reader, reader.LocalName)}`",
                _ => ReadInlineContent(reader, reader.LocalName)
            };
        }

        private static void AppendBlock(StringBuilder sb, string content)
        {
            if (string.IsNullOrEmpty(content))
                return;

            if (sb.Length > 0)
            {
                sb.AppendLine();
                sb.AppendLine();
            }

            sb.Append(content);
        }

        private string ReadInlineContent(XmlReader reader, string elementName)
        {
            var sb = new StringBuilder();

            while (reader.Read())
            {
                if (reader.NodeType == XmlNodeType.EndElement && reader.LocalName == elementName)
                    break;

                switch (reader.NodeType)
                {
                    case XmlNodeType.Element:
                        sb.Append(ReadInlineElement(reader));
                        break;

                    case XmlNodeType.Text:
                    case XmlNodeType.CDATA:
                        sb.Append(NormalizeWhitespace(reader.Value));
                        break;
                }
            }

            return sb.ToString();
        }

        private string ReadInlineElement(XmlReader reader)
        {
            return reader.LocalName switch
            {
                "strong" or "b" => $"**{ReadInlineContent(reader, reader.LocalName)}**",
                "em" or "i" => $"*{ReadInlineContent(reader, reader.LocalName)}*",
                "code" => $"`{ReadInlineContent(reader, reader.LocalName)}`",
                "a" => ReadAnchor(reader),
                _ => ReadInlineContent(reader, reader.LocalName)
            };
        }

        private string ReadAnchor(XmlReader reader)
        {
            var href = reader.GetAttribute("href");
            var text = ReadInlineContent(reader, "a");

            if (string.IsNullOrWhiteSpace(href))
                return text;

            var refId = (++_refCounter).ToString();
            _references.Add((refId, href));
            return $"[{text}][{refId}]";
        }

        private string ReadList(XmlReader reader, string listElement, bool ordered)
        {
            var sb = new StringBuilder();
            var index = 1;

            while (reader.Read())
            {
                if (reader.NodeType == XmlNodeType.EndElement && reader.LocalName == listElement)
                    break;

                if (reader is not { NodeType: XmlNodeType.Element, LocalName: "li" })
                    continue;

                var prefix = ordered ? $"{index}. " : "- ";
                var content = ReadInlineContent(reader, "li").Trim();
                AppendListItem(sb, prefix, content);

                if (ordered)
                    index++;
            }

            return sb.ToString().TrimEnd();
        }

        private static void AppendListItem(StringBuilder sb, string prefix, string content)
        {
            var lines = content.Split('\n');

            for (var i = 0; i < lines.Length; i++)
                if (i == 0)
                    sb.AppendLine($"{prefix}{lines[i]}");
                else
                    sb.AppendLine($"  {lines[i]}");
        }

        private string ReadBlockquote(XmlReader reader)
        {
            var sb = new StringBuilder();

            while (reader.Read())
            {
                if (reader is { NodeType: XmlNodeType.EndElement, LocalName: "blockquote" })
                    break;

                switch (reader.NodeType)
                {
                    case XmlNodeType.Element:
                        AppendBlock(sb, ReadBlock(reader));
                        break;

                    case XmlNodeType.Text:
                    case XmlNodeType.CDATA:
                        sb.Append(NormalizeWhitespace(reader.Value));
                        break;
                }
            }

            return PrefixBlockquote(sb.ToString().TrimEnd());
        }

        private string ReadHeading(XmlReader reader)
        {
            var level = reader.LocalName[1] - '0';
            var hashes = new string('#', level);
            var content = ReadInlineContent(reader, reader.LocalName).Trim();
            return $"{hashes} {content}";
        }

        private void AppendReferences(StringBuilder sb)
        {
            if (_references.Count == 0)
                return;

            sb.AppendLine();
            sb.AppendLine();

            foreach (var (id, url) in _references)
                sb.AppendLine($"[{id}]: {url}");
        }

        private static string PrefixBlockquote(string content)
        {
            var lines = content.Split('\n');
            var sb = new StringBuilder();

            foreach (var raw in lines)
            {
                var line = raw.TrimEnd('\r');
                sb.Append("> ");

                if (!string.IsNullOrWhiteSpace(line))
                    sb.Append(line);

                sb.AppendLine();
            }

            return sb.ToString().TrimEnd();
        }

        private static string NormalizeWhitespace(string value)
        {
            return SpaceRegex().Replace(value, " ");
        }
    }
}