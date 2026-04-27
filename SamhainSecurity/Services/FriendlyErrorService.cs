namespace SamhainSecurity.Services;

public static class FriendlyErrorService
{
    public static string ToUserMessage(CommandResult result)
    {
        if (result.IsSuccess)
        {
            return "Готово";
        }

        var text = result.CombinedOutput.ToLowerInvariant();
        if (string.IsNullOrWhiteSpace(text))
        {
            return "Не удалось выполнить действие";
        }

        if (text.Contains("access is denied", StringComparison.Ordinal)
            || text.Contains("administrator", StringComparison.Ordinal)
            || text.Contains("elevation", StringComparison.Ordinal)
            || text.Contains("отказано", StringComparison.Ordinal))
        {
            return "Нужен запуск от администратора";
        }

        if (text.Contains("not found", StringComparison.Ordinal)
            || text.Contains("could not find", StringComparison.Ordinal)
            || text.Contains("не найден", StringComparison.Ordinal))
        {
            return "Не найден нужный движок или файл";
        }

        if (text.Contains("timeout", StringComparison.Ordinal)
            || text.Contains("timed out", StringComparison.Ordinal)
            || text.Contains("таймаут", StringComparison.Ordinal))
        {
            return "Сервер не ответил вовремя";
        }

        if (text.Contains("network", StringComparison.Ordinal)
            || text.Contains("unreachable", StringComparison.Ordinal)
            || text.Contains("no such host", StringComparison.Ordinal))
        {
            return "Проверьте сеть или выберите другой сервер";
        }

        if (text.Contains("invalid", StringComparison.Ordinal)
            || text.Contains("required", StringComparison.Ordinal)
            || text.Contains("некоррект", StringComparison.Ordinal))
        {
            return "Проверьте параметры профиля";
        }

        if (text.Contains("service", StringComparison.Ordinal)
            || text.Contains("служб", StringComparison.Ordinal))
        {
            return "Служба требует внимания";
        }

        return "Действие не выполнено, подробности в журнале";
    }
}
