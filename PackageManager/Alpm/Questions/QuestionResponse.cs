using System.Collections.Generic;

namespace PackageManager.Alpm.Questions;

public record QuestionResponse(int Response, List<ProviderOption>?  ProviderOptions);