using System.IO;
using SamhainSecurity.Models;

namespace SamhainSecurity.Services;

public sealed record ReleaseReadinessItem(string Name, bool IsOk, string Message);

public sealed record ReleaseReadinessReport(bool IsReady, string Summary, IReadOnlyList<ReleaseReadinessItem> Items)
{
    public string Details => string.Join(Environment.NewLine, Items.Select(item =>
        $"{(item.IsOk ? "OK" : "Attention")}: {item.Name} - {item.Message}"));
}

public sealed record ReleaseRepairResult(string Summary, IReadOnlyList<string> Details);

public sealed class ReleaseReadinessService
{
    private readonly SamhainServiceClient _serviceClient = new();
    private readonly ServiceControlService _serviceControlService = new();

    public async Task<ReleaseReadinessReport> CheckAsync(
        VpnProtocolType protocol,
        string enginePath,
        CancellationToken cancellationToken = default)
    {
        var serviceItem = await CheckServiceAsync(cancellationToken);
        var items = new List<ReleaseReadinessItem>
        {
            CheckDirectory(
                "Папка данных",
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SamhainSecurity")),
            CheckDirectory(
                "Папка логов",
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SamhainSecurity", "logs")),
            serviceItem,
            CheckPrivilege(protocol, serviceItem.IsOk),
            CheckEngine(protocol, enginePath)
        };

        var isReady = items.All(item => item.IsOk);
        var blockers = items.Count(item => !item.IsOk);
        var summary = isReady
            ? "Среда готова"
            : $"Среда требует внимания: {blockers}";

        return new ReleaseReadinessReport(isReady, summary, items);
    }

    public async Task<ReleaseRepairResult> RepairAsync(CancellationToken cancellationToken = default)
    {
        var details = new List<string>();
        var appDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "SamhainSecurity");
        var logDirectory = Path.Combine(appDirectory, "logs");

        Directory.CreateDirectory(appDirectory);
        Directory.CreateDirectory(logDirectory);
        details.Add($"Папки проверены: {appDirectory}");

        var serviceResult = await _serviceControlService.EnsureInstalledAndStartedAsync(cancellationToken);
        details.Add(serviceResult.IsSuccess
            ? "Служба установлена или уже запущена"
            : SecretRedactor.Redact(serviceResult.CombinedOutput));

        return new ReleaseRepairResult(
            serviceResult.IsSuccess ? "Быстрый ремонт завершен" : "Быстрый ремонт требует запуска от администратора",
            details);
    }

    private static ReleaseReadinessItem CheckDirectory(string name, string path)
    {
        try
        {
            Directory.CreateDirectory(path);
            return new ReleaseReadinessItem(name, true, path);
        }
        catch (Exception ex)
        {
            return new ReleaseReadinessItem(name, false, ex.Message);
        }
    }

    private async Task<ReleaseReadinessItem> CheckServiceAsync(CancellationToken cancellationToken)
    {
        if (await _serviceClient.IsAvailableAsync(cancellationToken))
        {
            return new ReleaseReadinessItem("Служба", true, "готова");
        }

        var status = await _serviceControlService.QueryAsync(cancellationToken);
        return status.IsSuccess
            ? new ReleaseReadinessItem("Служба", false, "установлена, но не отвечает")
            : new ReleaseReadinessItem("Служба", false, "не установлена или не запущена");
    }

    private static ReleaseReadinessItem CheckPrivilege(VpnProtocolType protocol, bool serviceReady)
    {
        if (AdminElevationService.IsAdministrator())
        {
            return new ReleaseReadinessItem("Права", true, "запущено от администратора");
        }

        if (serviceReady)
        {
            return new ReleaseReadinessItem("Права", true, "привилегированные действия выполнит служба");
        }

        return protocol == VpnProtocolType.WindowsNative
            ? new ReleaseReadinessItem("Права", true, "для части действий служба может запросить повышенные права")
            : new ReleaseReadinessItem("Права", false, "для выбранного протокола нужна служба или запуск от администратора");
    }

    private static ReleaseReadinessItem CheckEngine(VpnProtocolType protocol, string enginePath)
    {
        return protocol switch
        {
            VpnProtocolType.VlessReality => CheckExternalEngine("sing-box", EnginePathResolver.ResolveSingBox(enginePath)),
            VpnProtocolType.WireGuard => CheckExternalEngine("WireGuard", EnginePathResolver.ResolveWireGuard(enginePath)),
            VpnProtocolType.AmneziaWireGuard => CheckExternalEngine("AmneziaWG", EnginePathResolver.ResolveAmneziaWireGuard(enginePath)),
            _ => new ReleaseReadinessItem("Движок", true, "для Windows Native внешний движок не нужен")
        };
    }

    private static ReleaseReadinessItem CheckExternalEngine(string name, string path)
    {
        return EnginePathResolver.IsPathAvailable(path)
            ? new ReleaseReadinessItem(name, true, path)
            : new ReleaseReadinessItem(name, false, "не найден");
    }
}
