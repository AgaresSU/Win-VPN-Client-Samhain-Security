using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Drawing;
using System.Net.NetworkInformation;
using System.Reflection;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;
using SamhainSecurity.Models;
using SamhainSecurity.Services;
using Forms = System.Windows.Forms;

namespace SamhainSecurity;

public partial class MainWindow : Window
{
    private readonly ObservableCollection<VpnProfile> _profiles = [];
    private readonly ObservableCollection<SubscriptionSourceListItem> _subscriptionSources = [];
    private readonly ObservableCollection<ServerListItem> _serverChoices = [];
    private readonly ProfileStore _profileStore = new();
    private readonly AppSettingsStore _appSettingsStore = new();
    private readonly StartupRegistrationService _startupRegistrationService = new();
    private readonly SecureDataProtector _protector = new();
    private readonly SubscriptionStore _subscriptionStore;
    private readonly SubscriptionImportService _subscriptionImportService;
    private readonly MultiProtocolVpnService _vpnService = new();
    private readonly EnvironmentDiagnosticsService _diagnosticsService = new();
    private readonly EngineAvailabilityService _engineAvailabilityService = new();
    private readonly ServiceControlService _serviceControlService = new();
    private readonly SamhainServiceClient _serviceClient = new();
    private readonly ConnectionStateStore _connectionStateStore = new();
    private readonly StructuredLogService _structuredLogService = new();
    private readonly DiagnosticsBundleService _diagnosticsBundleService;
    private Forms.NotifyIcon? _notifyIcon;
    private bool _allowExit;
    private bool _isBusy;
    private bool _isLoadingProfile;
    private bool _isLoadingSubscriptions;
    private bool _isLoadingServerChoices;
    private bool _isLoadingAppSettings;
    private string _lastClipboardSubscriptionUrl = string.Empty;
    private string _dailyConnectionState = "Ожидание";
    private string _dailyServiceState = "Служба: проверка";
    private DateTimeOffset _lastReconnectAttemptAt = DateTimeOffset.MinValue;
    private AppSettings _appSettings = new();

    public MainWindow()
    {
        _subscriptionStore = new SubscriptionStore(_protector);
        _subscriptionImportService = new SubscriptionImportService(_protector);
        _diagnosticsBundleService = new DiagnosticsBundleService(_profileStore, _connectionStateStore, _structuredLogService);

        InitializeComponent();

        VersionTextBlock.Text = "v" + GetAppVersion();
        ProfilesListBox.ItemsSource = _profiles;
        SubscriptionSourcesListBox.ItemsSource = _subscriptionSources;
        SubscriptionSelectorComboBox.ItemsSource = _subscriptionSources;
        ServerSelectorComboBox.ItemsSource = _serverChoices;
        CommandBindings.Add(new CommandBinding(
            ApplicationCommands.Paste,
            PasteCommand_Executed,
            PasteCommand_CanExecute));

        ProtocolComboBox.ItemsSource = Enum.GetValues<VpnProtocolType>()
            .Select(protocol => new ProtocolOption(protocol))
            .ToList();
        ProtocolComboBox.SelectedValue = VpnProtocolType.WindowsNative;

        TunnelTypeComboBox.ItemsSource = Enum.GetValues<VpnTunnelType>()
            .Select(tunnelType => new TunnelTypeOption(tunnelType))
            .ToList();
        TunnelTypeComboBox.SelectedValue = VpnTunnelType.Ikev2;

        UpdateProtocolFields();
        InitializeTrayIcon();
        InitializeReconnectMonitors();
        UpdateAdminButton();
        UpdateDailyStatusPanel();
    }

    private async void Window_Loaded(object sender, RoutedEventArgs e)
    {
        _appSettings = await _appSettingsStore.LoadAsync();
        ApplyAppSettingsToUi();

        await RunUiActionAsync(async () =>
        {
            var profiles = await _profileStore.LoadAsync();
            var subscriptions = await _subscriptionStore.LoadAsync();
            _profiles.Clear();

            foreach (var profile in profiles.OrderByDescending(profile => profile.UpdatedAt))
            {
                _profiles.Add(profile);
            }

            if (_profiles.Count > 0)
            {
                ProfilesListBox.SelectedIndex = 0;
            }
            else
            {
                ClearEditor();
            }

            LoadSubscriptionState(subscriptions);
            TryPrimeSubscriptionFromClipboard(replaceCurrent: false);

            AppendLog($"Профили: {_profiles.Count}. Хранилище: {_profileStore.FilePath}");
            AppendLog($"Подписки: {subscriptions.Count}. Хранилище: {_subscriptionStore.FilePath}");
        }, "Загрузка профилей...");

        await RefreshDailyServiceStateAsync();
        await AutoConnectLastProfileIfRequestedAsync();
    }

    private void Window_Activated(object sender, EventArgs e)
    {
        TryPrimeSubscriptionFromClipboard(replaceCurrent: false);
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!_allowExit)
        {
            e.Cancel = true;
            Hide();
            AppendLog("Окно скрыто в трей");
            return;
        }

        UnsubscribeReconnectMonitors();
        _notifyIcon?.Dispose();
        base.OnClosing(e);
    }

    private void ProfilesListBox_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (_isLoadingProfile)
        {
            return;
        }

        if (ProfilesListBox.SelectedItem is VpnProfile profile)
        {
            LoadProfileIntoEditor(profile);
        }
    }

    private void SubscriptionSourcesListBox_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (_isLoadingSubscriptions)
        {
            return;
        }

        if (SubscriptionSourcesListBox.SelectedItem is SubscriptionSourceListItem item)
        {
            SubscriptionUrlTextBox.Text = item.Url;
            SubscriptionStatusTextBlock.Text = item.DisplayStatus;
            SubscriptionSelectorComboBox.SelectedItem = item;
            _ = RememberSubscriptionSelectionAsync(item.Source.Id);
            RenderServerChoices(item);
            ApplySelectedServerChoice($"Подписка: {item.DisplayName}");
        }
    }

    private void SubscriptionSelectorComboBox_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (_isLoadingSubscriptions)
        {
            return;
        }

        if (SubscriptionSelectorComboBox.SelectedItem is not SubscriptionSourceListItem item)
        {
            RenderServerChoices(null);
            return;
        }

        SubscriptionSourcesListBox.SelectedItem = item;
        SubscriptionUrlTextBox.Text = item.Url;
        SubscriptionStatusTextBlock.Text = item.DisplayStatus;
        _ = RememberSubscriptionSelectionAsync(item.Source.Id);
        RenderServerChoices(item);
        ApplySelectedServerChoice($"Подписка: {item.DisplayName}");
    }

    private void ServerSelectorComboBox_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (_isLoadingServerChoices || ServerSelectorComboBox.SelectedItem is not ServerListItem item)
        {
            return;
        }

        ApplyServerChoice(item, $"Сервер: {item.DisplayName}");
    }

    private void ApplySelectedServerChoice(string statusText)
    {
        if (ServerSelectorComboBox.SelectedItem is ServerListItem item)
        {
            ApplyServerChoice(item, statusText);
        }
    }

    private void ApplyServerChoice(ServerListItem item, string statusText)
    {
        ProfilesListBox.SelectedItem = item.Profile;
        LoadProfileIntoEditor(item.Profile);
        StatusTextBlock.Text = statusText;
        UpdateDailyStatusPanel(item.Profile);
        UpdateFavoriteServerButton();
    }

    private async void FavoriteServerButton_Click(object sender, RoutedEventArgs e)
    {
        if (ServerSelectorComboBox.SelectedItem is not ServerListItem item)
        {
            StatusTextBlock.Text = "Выберите сервер";
            return;
        }

        item.Profile.IsFavorite = !item.Profile.IsFavorite;
        item.Profile.UpdatedAt = DateTimeOffset.UtcNow;
        await _profileStore.SaveAsync(_profiles);
        RenderServerChoices(SubscriptionSelectorComboBox.SelectedItem as SubscriptionSourceListItem, item.Profile.Id);
        StatusTextBlock.Text = item.Profile.IsFavorite
            ? "Сервер добавлен в избранное"
            : "Сервер убран из избранного";
    }

    private void BestServerButton_Click(object sender, RoutedEventArgs e)
    {
        var best = _serverChoices
            .OrderByDescending(item => item.Profile.IsFavorite)
            .ThenByDescending(item => item.Profile.LastConnectedAt ?? DateTimeOffset.MinValue)
            .ThenBy(item => item.DisplayName, StringComparer.CurrentCultureIgnoreCase)
            .FirstOrDefault();

        if (best is null)
        {
            StatusTextBlock.Text = "Нет серверов";
            return;
        }

        ServerSelectorComboBox.SelectedItem = best;
        ApplyServerChoice(best, $"Лучший сервер: {best.DisplayName}");
    }

    private void ProtocolComboBox_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (_isLoadingProfile)
        {
            return;
        }

        UpdateProtocolFields();
    }

    private void EnginePathTextBox_TextChanged(object sender, System.Windows.Controls.TextChangedEventArgs e)
    {
        if (_isLoadingProfile)
        {
            return;
        }

        UpdateEngineStatusBadge();
    }

    private async void AppSettingCheckBox_Changed(object sender, RoutedEventArgs e)
    {
        if (_isLoadingAppSettings)
        {
            return;
        }

        _appSettings.LaunchAtStartup = LaunchAtStartupCheckBox.IsChecked == true;
        _appSettings.AutoConnectLastProfile = AutoConnectLastProfileCheckBox.IsChecked == true;
        _appSettings.AutoReconnectOnSystemChange = AutoReconnectCheckBox.IsChecked == true;

        try
        {
            _startupRegistrationService.SetEnabled(_appSettings.LaunchAtStartup);
            await _appSettingsStore.SaveAsync(_appSettings);
            StatusTextBlock.Text = "Настройки сохранены";
            UpdateDailyStatusPanel();
        }
        catch (Exception ex)
        {
            StatusTextBlock.Text = "Не удалось сохранить настройки";
            AppendLog(ex.Message);
        }
    }

    private async void AdvancedSettingsExpander_Changed(object sender, RoutedEventArgs e)
    {
        if (_isLoadingAppSettings)
        {
            return;
        }

        _appSettings.AdvancedSettingsExpanded = AdvancedSettingsExpander.IsExpanded;
        await SaveAppSettingsQuietlyAsync();
    }

    private void NewProfileButton_Click(object sender, RoutedEventArgs e)
    {
        ProfilesListBox.SelectedItem = null;
        ClearEditor();
        StatusTextBlock.Text = "Новый профиль";
        UpdateDailyStatusPanel(connectionState: "Новый профиль");
    }

    private async void SaveProfileButton_Click(object sender, RoutedEventArgs e)
    {
        await RunUiActionAsync(async () =>
        {
            var profile = await SaveCurrentProfileAsync();
            if (profile is not null)
            {
                StatusTextBlock.Text = "Профиль сохранен";
                UpdateDailyStatusPanel(profile);
            }
        }, "Сохранение...");
    }

    private async void DeleteProfileButton_Click(object sender, RoutedEventArgs e)
    {
        if (ProfilesListBox.SelectedItem is not VpnProfile profile)
        {
            StatusTextBlock.Text = "Выберите профиль";
            return;
        }

        var confirmed = System.Windows.MessageBox.Show(
            this,
            $"Удалить профиль \"{profile.Name}\"?",
            "Удаление",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning);

        if (confirmed != MessageBoxResult.Yes)
        {
            return;
        }

        await RunUiActionAsync(async () =>
        {
            var removeResult = await _vpnService.RemoveProfileAsync(profile, GetTunnelConfig());
            _structuredLogService.WriteCommand("profile.cleanup", profile, removeResult);
            if (!removeResult.IsSuccess)
            {
                AppendCommandResult("profile cleanup", removeResult);
            }

            _profiles.Remove(profile);
            await _profileStore.SaveAsync(_profiles);
            ClearEditor();
            RenderServerChoices(SubscriptionSelectorComboBox.SelectedItem as SubscriptionSourceListItem);
            StatusTextBlock.Text = "Профиль удален";
            UpdateDailyStatusPanel(connectionState: "Ожидание");
            AppendLog($"Удален: {profile.Name}");
        }, "Удаление...");
    }

    private async void ConnectButton_Click(object sender, RoutedEventArgs e)
    {
        await RunUiActionAsync(async () =>
        {
            var profile = await SaveCurrentProfileAsync();
            if (profile is null)
            {
                return;
            }

            var connectResult = await _vpnService.ConnectAsync(profile, PasswordBox.Password, GetTunnelConfig());
            _structuredLogService.WriteCommand("connect", profile, connectResult);
            AppendCommandResult($"{profile.Protocol.ToDisplayName()} connect", connectResult);

            await _connectionStateStore.UpdateAsync(
                profile,
                "connect",
                connectResult.IsSuccess ? "Connected" : "Failed",
                connectResult);

            if (connectResult.IsSuccess)
            {
                profile.LastConnectedAt = DateTimeOffset.UtcNow;
                _appSettings.LastProfileId = profile.Id;
                await _profileStore.SaveAsync(_profiles);
                await SaveAppSettingsQuietlyAsync();
                RenderServerChoices(SubscriptionSelectorComboBox.SelectedItem as SubscriptionSourceListItem, profile.Id);
            }

            StatusTextBlock.Text = connectResult.IsSuccess
                ? "Подключено"
                : "Подключение не удалось";
            UpdateDailyStatusPanel(profile, connectResult.IsSuccess ? "Подключено" : "Ошибка подключения");

            if (connectResult.IsSuccess && IsProtectionRequested(profile))
            {
                var protectionResult = await _serviceClient.ApplyProtectionAsync(profile)
                    ?? ServiceUnavailableResult();
                AppendCommandResult("protection apply", protectionResult);
                UpdateDailyStatusPanel(
                    profile,
                    protectionResult.IsSuccess ? "Подключено, защита включена" : "Защита требует внимания");
            }
        }, "Подключение...");
    }

    private async void DisconnectButton_Click(object sender, RoutedEventArgs e)
    {
        var profile = GetCurrentOrSelectedProfile();
        if (profile is null)
        {
            StatusTextBlock.Text = "Выберите профиль";
            return;
        }

        await RunUiActionAsync(async () =>
        {
            var disconnectResult = await _vpnService.DisconnectAsync(profile, GetTunnelConfig());
            _structuredLogService.WriteCommand("disconnect", profile, disconnectResult);
            AppendCommandResult($"{profile.Protocol.ToDisplayName()} disconnect", disconnectResult);

            await _connectionStateStore.UpdateAsync(
                profile,
                "disconnect",
                disconnectResult.IsSuccess ? "Disconnected" : "DisconnectFailed",
                disconnectResult);

            StatusTextBlock.Text = disconnectResult.IsSuccess
                ? "Отключено"
                : "Отключение не удалось";
            UpdateDailyStatusPanel(profile, disconnectResult.IsSuccess ? "Отключено" : "Ошибка отключения");
        }, "Отключение...");
    }

    private async void RefreshStatusButton_Click(object sender, RoutedEventArgs e)
    {
        var profile = GetCurrentOrSelectedProfile();
        if (profile is null)
        {
            StatusTextBlock.Text = "Выберите профиль";
            return;
        }

        await RunUiActionAsync(async () =>
        {
            var statusResult = await _vpnService.GetStatusAsync(profile);
            _structuredLogService.WriteCommand("status", profile, statusResult);
            AppendCommandResult($"{profile.Protocol.ToDisplayName()} status", statusResult);

            await _connectionStateStore.UpdateAsync(
                profile,
                "status",
                statusResult.Output.Trim(),
                statusResult);

            StatusTextBlock.Text = statusResult.IsSuccess
                ? $"Статус: {statusResult.Output.Trim()}"
                : "Статус недоступен";
            UpdateDailyStatusPanel(profile, BuildDailyConnectionStatus(statusResult));
        }, "Проверка статуса...");
    }

    private void BrowseEngineButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Filter = "Executable (*.exe)|*.exe|All files (*.*)|*.*",
            CheckFileExists = true
        };

        if (dialog.ShowDialog(this) == true)
        {
            EnginePathTextBox.Text = dialog.FileName;
        }
    }

    private void RunAsAdminButton_Click(object sender, RoutedEventArgs e)
    {
        RelaunchAsAdministrator();
    }

    private async void ServiceButton_Click(object sender, RoutedEventArgs e)
    {
        await RunUiActionAsync(async () =>
        {
            var result = await _serviceControlService.EnsureInstalledAndStartedAsync();
            AppendCommandResult("service ensure", result);
            StatusTextBlock.Text = result.IsSuccess
                ? "Служба готова"
                : "Служба недоступна";
            SetDailyServiceState(result.IsSuccess ? "Служба: готова" : "Служба: недоступна");
        }, "Проверка службы...");
    }

    private async void ApplyProtectionButton_Click(object sender, RoutedEventArgs e)
    {
        await RunUiActionAsync(async () =>
        {
            var profile = await SaveCurrentProfileAsync();
            if (profile is null)
            {
                return;
            }

            var result = await _serviceClient.ApplyProtectionAsync(profile)
                ?? ServiceUnavailableResult();
            AppendCommandResult("protection apply", result);
            StatusTextBlock.Text = result.IsSuccess
                ? "Защита применена"
                : "Защита недоступна";
            UpdateDailyStatusPanel(profile, result.IsSuccess ? _dailyConnectionState : "Защита требует внимания");
        }, "Применение защиты...");
    }

    private async void PreviewProtectionButton_Click(object sender, RoutedEventArgs e)
    {
        await RunUiActionAsync(async () =>
        {
            var profile = BuildProfileFromEditorWithoutValidation();
            var validationError = ValidateProtectionProfile(profile);
            if (!string.IsNullOrWhiteSpace(validationError))
            {
                StatusTextBlock.Text = validationError;
                AppendLog(validationError);
                return;
            }

            var result = await _serviceClient.PreviewProtectionAsync(profile)
                ?? ServiceUnavailableResult();
            AppendCommandResult("protection preview", result);
            StatusTextBlock.Text = result.IsSuccess
                ? "План защиты готов"
                : "План защиты недоступен";
        }, "Расчет защиты...");
    }

    private async void RemoveProtectionButton_Click(object sender, RoutedEventArgs e)
    {
        await RunUiActionAsync(async () =>
        {
            var result = await _serviceClient.RemoveProtectionAsync()
                ?? ServiceUnavailableResult();
            AppendCommandResult("protection remove", result);
            StatusTextBlock.Text = result.IsSuccess
                ? "Защита снята"
                : "Защита недоступна";
        }, "Отключение защиты...");
    }

    private async void ResetProtectionButton_Click(object sender, RoutedEventArgs e)
    {
        await RunUiActionAsync(async () =>
        {
            var result = await _serviceClient.ResetProtectionAsync()
                ?? ServiceUnavailableResult();
            AppendCommandResult("protection reset", result);
            StatusTextBlock.Text = result.IsSuccess
                ? "Защита сброшена"
                : "Сброс защиты недоступен";
        }, "Аварийный сброс защиты...");
    }

    private async void ProtectionStatusButton_Click(object sender, RoutedEventArgs e)
    {
        await RunUiActionAsync(async () =>
        {
            var result = await _serviceClient.GetProtectionStatusAsync()
                ?? ServiceUnavailableResult();
            AppendCommandResult("protection status", result);
            StatusTextBlock.Text = result.IsSuccess
                ? "Защита проверена"
                : "Защита недоступна";
        }, "Проверка защиты...");
    }

    private async void DiagnosticsButton_Click(object sender, RoutedEventArgs e)
    {
        await RunUiActionAsync(async () =>
        {
            var protocol = ProtocolComboBox.SelectedValue is VpnProtocolType selectedProtocol
                ? selectedProtocol
                : VpnProtocolType.WindowsNative;
            var report = await _diagnosticsService.BuildReportAsync(protocol, EnginePathTextBox.Text);

            AppendLog(report);
            StatusTextBlock.Text = "Диагностика завершена";
        }, "Диагностика...");
    }

    private async void ExportDiagnosticsButton_Click(object sender, RoutedEventArgs e)
    {
        await RunUiActionAsync(() =>
        {
            var dialog = new Microsoft.Win32.SaveFileDialog
            {
                Filter = "Zip archive (*.zip)|*.zip",
                FileName = $"samhain-diagnostics-{DateTime.Now:yyyyMMdd-HHmmss}.zip",
                OverwritePrompt = true
            };

            if (dialog.ShowDialog(this) == true)
            {
                _diagnosticsBundleService.Export(dialog.FileName);
                AppendLog($"Диагностика экспортирована: {dialog.FileName}");
                StatusTextBlock.Text = "Диагностика экспортирована";
            }

            return Task.CompletedTask;
        }, "Экспорт диагностики...");
    }

    private void ImportVlessButton_Click(object sender, RoutedEventArgs e)
    {
        var profile = BuildProfileFromEditorWithoutValidation();
        if (!VlessShareLinkParser.TryApply(VlessUriTextBox.Text, profile, out var error))
        {
            StatusTextBlock.Text = error;
            AppendLog(error);
            return;
        }

        LoadProfileIntoEditor(profile);
        StatusTextBlock.Text = "VLESS импортирован";
        UpdateDailyStatusPanel(profile);
    }

    private async void RefreshSubscriptionButton_Click(object sender, RoutedEventArgs e)
    {
        await RunUiActionAsync(async () =>
        {
            var url = SubscriptionUrlTextBox.Text.Trim();
            if (string.IsNullOrWhiteSpace(url))
            {
                StatusTextBlock.Text = "Введите ссылку подключения";
                SubscriptionStatusTextBlock.Text = StatusTextBlock.Text;
                return;
            }

            var refreshResult = await RefreshSubscriptionUrlAsync(url, selectImportedProfile: true);
            StatusTextBlock.Text = refreshResult.Added + refreshResult.Updated > 0
                ? "Подписка обновлена"
                : "Нет новых профилей";
        }, "Обновление подписки...");
    }

    private async void RefreshAllSubscriptionsButton_Click(object sender, RoutedEventArgs e)
    {
        await RunUiActionAsync(async () =>
        {
            var sources = await _subscriptionStore.LoadAsync();
            if (sources.Count == 0)
            {
                StatusTextBlock.Text = "Нет сохраненных источников";
                SubscriptionStatusTextBlock.Text = StatusTextBlock.Text;
                return;
            }

            var added = 0;
            var updated = 0;
            foreach (var source in sources.OrderBy(item => item.Name))
            {
                var url = _subscriptionStore.UnprotectUrl(source);
                if (string.IsNullOrWhiteSpace(url))
                {
                    continue;
                }

                var refreshResult = await RefreshSubscriptionUrlAsync(url, selectImportedProfile: false);
                added += refreshResult.Added;
                updated += refreshResult.Updated;
            }

            var status = $"Источников обновлено: {sources.Count}; профили: +{added}, обновлено {updated}";
            StatusTextBlock.Text = "Все подписки обновлены";
            SubscriptionStatusTextBlock.Text = status;
            AppendLog(status);
        }, "Обновление всех подписок...");
    }

    private async void PasteSubscriptionButton_Click(object sender, RoutedEventArgs e)
    {
        await RunUiActionAsync(async () =>
        {
            if (!TryGetSubscriptionUrlFromClipboard(out var url))
            {
                StatusTextBlock.Text = "В буфере нет ссылки подключения";
                SubscriptionStatusTextBlock.Text = StatusTextBlock.Text;
                return;
            }

            SubscriptionUrlTextBox.Text = url;
            var refreshResult = await RefreshSubscriptionUrlAsync(url, selectImportedProfile: true);
            StatusTextBlock.Text = refreshResult.Added + refreshResult.Updated > 0
                ? "Подписка из буфера импортирована"
                : "Подписка из буфера проверена";
        }, "Импорт из буфера...");
    }

    private async void DeleteSubscriptionButton_Click(object sender, RoutedEventArgs e)
    {
        if (SubscriptionSourcesListBox.SelectedItem is not SubscriptionSourceListItem selected)
        {
            StatusTextBlock.Text = "Выберите источник";
            return;
        }

        var confirmed = System.Windows.MessageBox.Show(
            this,
            $"Удалить источник \"{selected.DisplayName}\"?",
            "Удаление источника",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning);

        if (confirmed != MessageBoxResult.Yes)
        {
            return;
        }

        await RunUiActionAsync(async () =>
        {
            var sources = (await _subscriptionStore.LoadAsync()).ToList();
            sources.RemoveAll(source => source.Id == selected.Source.Id);
            await _subscriptionStore.SaveAsync(sources);
            RenderSubscriptionSources(sources);
            SubscriptionUrlTextBox.Clear();
            RenderServerChoices(null);
            StatusTextBlock.Text = "Источник удален";
            SubscriptionStatusTextBlock.Text = "Источник удален. Импортированные профили не удалялись.";
        }, "Удаление источника...");
    }

    private async Task<VpnProfile?> SaveCurrentProfileAsync()
    {
        if (!TryBuildProfileFromEditor(out var profile, out var validationError))
        {
            StatusTextBlock.Text = validationError;
            AppendLog(validationError);
            return null;
        }

        var oldProfile = ProfilesListBox.SelectedItem as VpnProfile;
        var oldName = oldProfile?.Name;
        var index = oldProfile is null ? -1 : _profiles.IndexOf(oldProfile);

        var duplicate = _profiles.Any(existing =>
            !ReferenceEquals(existing, oldProfile)
            && string.Equals(existing.Name, profile.Name, StringComparison.OrdinalIgnoreCase));

        if (duplicate)
        {
            StatusTextBlock.Text = "Профиль с таким названием уже есть";
            AppendLog(StatusTextBlock.Text);
            return null;
        }

        if (index >= 0)
        {
            _profiles[index] = profile;
        }
        else
        {
            _profiles.Insert(0, profile);
        }

        ProfilesListBox.SelectedItem = profile;
        await _profileStore.SaveAsync(_profiles);
        RenderServerChoices(SubscriptionSelectorComboBox.SelectedItem as SubscriptionSourceListItem, profile.Id);

        if (!string.IsNullOrWhiteSpace(oldName)
            && !string.Equals(oldName, profile.Name, StringComparison.OrdinalIgnoreCase)
            && oldProfile?.Protocol == VpnProtocolType.WindowsNative)
        {
            var removeOldResult = await _vpnService.RemoveProfileAsync(oldProfile, GetTunnelConfig());
            _structuredLogService.WriteCommand("profile.cleanup.old", oldProfile, removeOldResult);
            if (!removeOldResult.IsSuccess)
            {
                AppendCommandResult("old Windows native profile remove", removeOldResult);
            }
        }

        var prepareResult = await _vpnService.PrepareProfileAsync(profile, L2tpPskPasswordBox.Password);
        _structuredLogService.WriteCommand("profile.prepare", profile, prepareResult);
        AppendCommandResult($"{profile.Protocol.ToDisplayName()} prepare", prepareResult);

        if (!prepareResult.IsSuccess)
        {
            StatusTextBlock.Text = "Не удалось подготовить профиль";
            return null;
        }

        return profile;
    }

    private bool TryBuildProfileFromEditor(out VpnProfile profile, out string validationError)
    {
        profile = BuildProfileFromEditorWithoutValidation();
        validationError = ValidateProfile(profile, GetTunnelConfig());

        return string.IsNullOrWhiteSpace(validationError);
    }

    private VpnProfile BuildProfileFromEditorWithoutValidation()
    {
        var oldProfile = ProfilesListBox.SelectedItem as VpnProfile;
        var protocol = ProtocolComboBox.SelectedValue is VpnProtocolType selectedProtocol
            ? selectedProtocol
            : VpnProtocolType.WindowsNative;
        var tunnelConfig = GetTunnelConfig();
        var serverAddress = ServerTextBox.Text.Trim();
        var serverPort = ParsePortOrDefault(ServerPortTextBox.Text);

        if (protocol is VpnProtocolType.WireGuard or VpnProtocolType.AmneziaWireGuard
            && TryParseEndpointFromConfig(tunnelConfig, out var endpointHost, out var endpointPort))
        {
            serverAddress = endpointHost;
            serverPort = endpointPort;
        }

        return new VpnProfile
        {
            Id = oldProfile?.Id ?? Guid.NewGuid().ToString("N"),
            Name = NameTextBox.Text.Trim(),
            Protocol = protocol,
            SubscriptionSourceId = oldProfile?.SubscriptionSourceId ?? string.Empty,
            SubscriptionName = oldProfile?.SubscriptionName ?? string.Empty,
            IsFavorite = oldProfile?.IsFavorite ?? false,
            LastConnectedAt = oldProfile?.LastConnectedAt,
            ServerAddress = serverAddress,
            ServerPort = serverPort,
            TunnelType = TunnelTypeComboBox.SelectedValue is VpnTunnelType tunnelType
                ? tunnelType
                : VpnTunnelType.Ikev2,
            UserName = UserNameTextBox.Text.Trim(),
            EncryptedPassword = _protector.Protect(PasswordBox.Password),
            EncryptedL2tpPsk = _protector.Protect(L2tpPskPasswordBox.Password),
            SplitTunneling = SplitTunnelingCheckBox.IsChecked == true,
            KillSwitchEnabled = KillSwitchCheckBox.IsChecked == true,
            DnsLeakProtectionEnabled = DnsLeakProtectionCheckBox.IsChecked == true,
            AllowLanTraffic = AllowLanTrafficCheckBox.IsChecked == true,
            DnsServers = DnsServersTextBox.Text.Trim(),
            VlessUuid = VlessUuidTextBox.Text.Trim(),
            VlessFlow = VlessFlowTextBox.Text.Trim(),
            RealityServerName = RealityServerNameTextBox.Text.Trim(),
            RealityPublicKey = RealityPublicKeyTextBox.Text.Trim(),
            RealityShortId = RealityShortIdTextBox.Text.Trim(),
            RealityFingerprint = RealityFingerprintTextBox.Text.Trim(),
            EnginePath = EnginePathTextBox.Text.Trim(),
            EncryptedTunnelConfig = _protector.Protect(tunnelConfig),
            UpdatedAt = DateTimeOffset.UtcNow
        };
    }

    private static string ValidateProfile(VpnProfile profile, string tunnelConfig)
    {
        var protocolError = ProtocolProfileValidator.Validate(profile, tunnelConfig);
        if (!string.IsNullOrWhiteSpace(protocolError))
        {
            return protocolError;
        }

        if (profile.DnsLeakProtectionEnabled && string.IsNullOrWhiteSpace(profile.DnsServers))
        {
            return "Введите DNS servers";
        }

        var protectionError = ValidateProtectionProfile(profile);
        if (!string.IsNullOrWhiteSpace(protectionError))
        {
            return protectionError;
        }

        return string.Empty;
    }

    private static string ValidateProtectionProfile(VpnProfile profile)
    {
        if (!profile.KillSwitchEnabled && !profile.DnsLeakProtectionEnabled)
        {
            return string.Empty;
        }

        if (profile.DnsLeakProtectionEnabled && !profile.KillSwitchEnabled)
        {
            return "DNS leak protection требует Kill switch";
        }

        if (profile.KillSwitchEnabled
            && string.IsNullOrWhiteSpace(profile.ServerAddress)
            && string.IsNullOrWhiteSpace(profile.EnginePath)
            && string.IsNullOrWhiteSpace(profile.Name))
        {
            return "Для Kill switch нужен сервер, движок или имя интерфейса";
        }

        return string.Empty;
    }

    private VpnProfile? GetCurrentOrSelectedProfile()
    {
        if (ProfilesListBox.SelectedItem is VpnProfile selected)
        {
            return selected;
        }

        return TryBuildProfileFromEditor(out var profile, out _)
            ? profile
            : null;
    }

    private void LoadProfileIntoEditor(VpnProfile profile)
    {
        _isLoadingProfile = true;
        try
        {
            NameTextBox.Text = profile.Name;
            ProtocolComboBox.SelectedValue = profile.Protocol;
            ServerTextBox.Text = profile.ServerAddress;
            ServerPortTextBox.Text = profile.ServerPort > 0 ? profile.ServerPort.ToString() : "443";
            EnginePathTextBox.Text = profile.EnginePath;
            TunnelTypeComboBox.SelectedValue = profile.TunnelType;
            UserNameTextBox.Text = profile.UserName;
            PasswordBox.Password = _protector.Unprotect(profile.EncryptedPassword);
            L2tpPskPasswordBox.Password = _protector.Unprotect(profile.EncryptedL2tpPsk);
            SplitTunnelingCheckBox.IsChecked = profile.SplitTunneling;
            KillSwitchCheckBox.IsChecked = profile.KillSwitchEnabled;
            DnsLeakProtectionCheckBox.IsChecked = profile.DnsLeakProtectionEnabled;
            AllowLanTrafficCheckBox.IsChecked = profile.AllowLanTraffic;
            DnsServersTextBox.Text = string.IsNullOrWhiteSpace(profile.DnsServers)
                ? "1.1.1.1, 9.9.9.9"
                : profile.DnsServers;
            VlessUuidTextBox.Text = profile.VlessUuid;
            VlessFlowTextBox.Text = string.IsNullOrWhiteSpace(profile.VlessFlow)
                ? "xtls-rprx-vision"
                : profile.VlessFlow;
            RealityServerNameTextBox.Text = profile.RealityServerName;
            RealityPublicKeyTextBox.Text = profile.RealityPublicKey;
            RealityShortIdTextBox.Text = profile.RealityShortId;
            RealityFingerprintTextBox.Text = string.IsNullOrWhiteSpace(profile.RealityFingerprint)
                ? "chrome"
                : profile.RealityFingerprint;
            TunnelConfigTextBox.Text = _protector.Unprotect(profile.EncryptedTunnelConfig);
            StatusTextBlock.Text = $"Профиль: {profile.Name}";
        }
        finally
        {
            _isLoadingProfile = false;
        }

        UpdateProtocolFields();
        UpdateDailyStatusPanel(profile);
    }

    private void ClearEditor()
    {
        _isLoadingProfile = true;
        try
        {
            NameTextBox.Text = string.Empty;
            ProtocolComboBox.SelectedValue = VpnProtocolType.WindowsNative;
            ServerTextBox.Text = string.Empty;
            ServerPortTextBox.Text = "443";
            EnginePathTextBox.Text = string.Empty;
            TunnelTypeComboBox.SelectedValue = VpnTunnelType.Ikev2;
            UserNameTextBox.Text = string.Empty;
            PasswordBox.Password = string.Empty;
            L2tpPskPasswordBox.Password = string.Empty;
            SplitTunnelingCheckBox.IsChecked = false;
            KillSwitchCheckBox.IsChecked = false;
            DnsLeakProtectionCheckBox.IsChecked = false;
            AllowLanTrafficCheckBox.IsChecked = true;
            DnsServersTextBox.Text = "1.1.1.1, 9.9.9.9";
            VlessUriTextBox.Text = string.Empty;
            VlessUuidTextBox.Text = string.Empty;
            VlessFlowTextBox.Text = "xtls-rprx-vision";
            RealityServerNameTextBox.Text = string.Empty;
            RealityPublicKeyTextBox.Text = string.Empty;
            RealityShortIdTextBox.Text = string.Empty;
            RealityFingerprintTextBox.Text = "chrome";
            TunnelConfigTextBox.Text = string.Empty;
        }
        finally
        {
            _isLoadingProfile = false;
        }

        UpdateProtocolFields();
    }

    private void UpdateProtocolFields()
    {
        var protocol = ProtocolComboBox.SelectedValue is VpnProtocolType selectedProtocol
            ? selectedProtocol
            : VpnProtocolType.WindowsNative;

        NativePanel.Visibility = protocol == VpnProtocolType.WindowsNative
            ? Visibility.Visible
            : Visibility.Collapsed;
        VlessRealityPanel.Visibility = protocol == VpnProtocolType.VlessReality
            ? Visibility.Visible
            : Visibility.Collapsed;
        TunnelConfigPanel.Visibility = protocol is VpnProtocolType.WireGuard or VpnProtocolType.AmneziaWireGuard
            ? Visibility.Visible
            : Visibility.Collapsed;
        EnginePathPanel.Visibility = protocol == VpnProtocolType.WindowsNative
            ? Visibility.Collapsed
            : Visibility.Visible;

        ServerPortTextBox.IsEnabled = protocol == VpnProtocolType.VlessReality;
        ServerTextBox.IsEnabled = protocol is VpnProtocolType.WindowsNative or VpnProtocolType.VlessReality;

        EnginePathLabel.Text = protocol switch
        {
            VpnProtocolType.VlessReality => "sing-box.exe",
            VpnProtocolType.WireGuard => "wireguard.exe",
            VpnProtocolType.AmneziaWireGuard => "awg-quick.exe",
            _ => "Движок"
        };

        TunnelConfigLabel.Text = protocol switch
        {
            VpnProtocolType.AmneziaWireGuard => "AmneziaWG .conf",
            _ => "WireGuard .conf"
        };

        UpdateEngineStatusBadge();
        UpdateDailyStatusPanel();
    }

    private void UpdateEngineStatusBadge()
    {
        var protocol = ProtocolComboBox.SelectedValue is VpnProtocolType selectedProtocol
            ? selectedProtocol
            : VpnProtocolType.WindowsNative;

        var availability = _engineAvailabilityService.GetAvailability(protocol, EnginePathTextBox.Text);
        EngineStatusTextBlock.Text = availability.Label;

        if (!availability.IsAvailable)
        {
            EngineStatusBadge.Background = (System.Windows.Media.Brush)FindResource("ErrorBrush");
            EngineStatusTextBlock.Foreground = (System.Windows.Media.Brush)FindResource("ErrorTextBrush");
            return;
        }

        if (availability.NeedsAdmin)
        {
            EngineStatusBadge.Background = (System.Windows.Media.Brush)FindResource("WarningBrush");
            EngineStatusTextBlock.Foreground = (System.Windows.Media.Brush)FindResource("WarningTextBrush");
            return;
        }

        EngineStatusBadge.Background = (System.Windows.Media.Brush)FindResource("SuccessBrush");
        EngineStatusTextBlock.Foreground = (System.Windows.Media.Brush)FindResource("SuccessTextBrush");
    }

    private void UpdateDailyStatusPanel(VpnProfile? profile = null, string? connectionState = null)
    {
        if (!string.IsNullOrWhiteSpace(connectionState))
        {
            _dailyConnectionState = connectionState;
        }

        var snapshot = BuildDailyProfileSnapshot(profile);
        var hasProfile = !string.IsNullOrWhiteSpace(snapshot.Name)
            || !string.IsNullOrWhiteSpace(snapshot.ServerAddress);

        DailyConnectionStateTextBlock.Text = _dailyConnectionState;
        DailyProfileTextBlock.Text = hasProfile
            ? string.IsNullOrWhiteSpace(snapshot.Name) ? "Без названия" : snapshot.Name
            : "Профиль не выбран";
        DailyRouteTextBlock.Text = BuildDailyRouteText(snapshot);
        DailyProtocolTextBlock.Text = snapshot.Protocol.ToDisplayName();
        DailyProtectionTextBlock.Text = BuildDailyProtectionText(snapshot);
        DailyAutoModeTextBlock.Text = BuildDailyAutoModeText();
        DailyServiceTextBlock.Text = _dailyServiceState;

        ApplyDailyConnectionBrush(_dailyConnectionState);
    }

    private DailyProfileSnapshot BuildDailyProfileSnapshot(VpnProfile? profile)
    {
        if (profile is not null)
        {
            return new DailyProfileSnapshot(
                profile.Name,
                profile.Protocol,
                profile.ServerAddress,
                profile.ServerPort,
                profile.KillSwitchEnabled,
                profile.DnsLeakProtectionEnabled,
                profile.AllowLanTraffic);
        }

        var protocol = ProtocolComboBox.SelectedValue is VpnProtocolType selectedProtocol
            ? selectedProtocol
            : VpnProtocolType.WindowsNative;
        var serverAddress = ServerTextBox.Text.Trim();
        var serverPort = ParsePortOrDefault(ServerPortTextBox.Text);

        if (protocol is VpnProtocolType.WireGuard or VpnProtocolType.AmneziaWireGuard
            && TryParseEndpointFromConfig(GetTunnelConfig(), out var endpointHost, out var endpointPort))
        {
            serverAddress = endpointHost;
            serverPort = endpointPort;
        }

        return new DailyProfileSnapshot(
            NameTextBox.Text.Trim(),
            protocol,
            serverAddress,
            serverPort,
            KillSwitchCheckBox.IsChecked == true,
            DnsLeakProtectionCheckBox.IsChecked == true,
            AllowLanTrafficCheckBox.IsChecked == true);
    }

    private static string BuildDailyRouteText(DailyProfileSnapshot snapshot)
    {
        if (string.IsNullOrWhiteSpace(snapshot.ServerAddress))
        {
            return snapshot.Protocol is VpnProtocolType.WireGuard or VpnProtocolType.AmneziaWireGuard
                ? "Маршрут: из конфигурации"
                : "Маршрут не выбран";
        }

        return snapshot.ServerPort > 0
            ? $"{snapshot.ServerAddress}:{snapshot.ServerPort}"
            : snapshot.ServerAddress;
    }

    private static string BuildDailyProtectionText(DailyProfileSnapshot snapshot)
    {
        var parts = new List<string>();

        if (snapshot.KillSwitchEnabled)
        {
            parts.Add("Kill switch");
        }

        if (snapshot.DnsLeakProtectionEnabled)
        {
            parts.Add("DNS");
        }

        if (parts.Count == 0)
        {
            return "Выключена";
        }

        if (snapshot.AllowLanTraffic)
        {
            parts.Add("локальная сеть");
        }

        return string.Join(", ", parts);
    }

    private string BuildDailyAutoModeText()
    {
        var startup = _appSettings.LaunchAtStartup ? "автозапуск" : "ручной запуск";
        var reconnect = _appSettings.AutoConnectLastProfile ? "автоподключение" : "без автоподключения";
        var recovery = _appSettings.AutoReconnectOnSystemChange ? "восстановление" : "без восстановления";

        return $"{startup}; {reconnect}; {recovery}";
    }

    private static string BuildDailyConnectionStatus(CommandResult result)
    {
        if (!result.IsSuccess)
        {
            return "Статус недоступен";
        }

        var output = result.CombinedOutput.ToLowerInvariant();
        if (output.Contains("disconnected", StringComparison.Ordinal)
            || output.Contains("not connected", StringComparison.Ordinal)
            || output.Contains("no active", StringComparison.Ordinal))
        {
            return "Отключено";
        }

        if (output.Contains("connected", StringComparison.Ordinal)
            || output.Contains("running", StringComparison.Ordinal)
            || output.Contains("active", StringComparison.Ordinal))
        {
            return "Подключено";
        }

        return "Статус получен";
    }

    private async Task RefreshDailyServiceStateAsync()
    {
        SetDailyServiceState("Служба: проверка");
        var isAvailable = await _serviceClient.IsAvailableAsync();
        SetDailyServiceState(isAvailable ? "Служба: готова" : "Служба: не запущена");
    }

    private void SetDailyServiceState(string state)
    {
        _dailyServiceState = state;
        UpdateDailyStatusPanel();
    }

    private void ApplyDailyConnectionBrush(string state)
    {
        var normalized = state.ToLowerInvariant();
        if (normalized.Contains("ошибка", StringComparison.Ordinal)
            || normalized.Contains("недоступ", StringComparison.Ordinal)
            || normalized.Contains("не удалось", StringComparison.Ordinal)
            || normalized.Contains("требует", StringComparison.Ordinal))
        {
            DailyConnectionBadge.Background = (System.Windows.Media.Brush)FindResource("ErrorBrush");
            DailyConnectionStateTextBlock.Foreground = (System.Windows.Media.Brush)FindResource("ErrorTextBrush");
            return;
        }

        if (normalized.Contains("подключено", StringComparison.Ordinal))
        {
            DailyConnectionBadge.Background = (System.Windows.Media.Brush)FindResource("SuccessBrush");
            DailyConnectionStateTextBlock.Foreground = (System.Windows.Media.Brush)FindResource("SuccessTextBrush");
            return;
        }

        DailyConnectionBadge.Background = (System.Windows.Media.Brush)FindResource("WarningBrush");
        DailyConnectionStateTextBlock.Foreground = (System.Windows.Media.Brush)FindResource("WarningTextBrush");
    }

    private void UpdateAdminButton()
    {
        RunAsAdminButton.Visibility = AdminElevationService.IsAdministrator()
            ? Visibility.Collapsed
            : Visibility.Visible;
    }

    private void ApplyAppSettingsToUi()
    {
        _isLoadingAppSettings = true;
        try
        {
            _appSettings.LaunchAtStartup = _appSettings.LaunchAtStartup || _startupRegistrationService.IsEnabled();
            LaunchAtStartupCheckBox.IsChecked = _appSettings.LaunchAtStartup;
            AutoConnectLastProfileCheckBox.IsChecked = _appSettings.AutoConnectLastProfile;
            AutoReconnectCheckBox.IsChecked = _appSettings.AutoReconnectOnSystemChange;
            AdvancedSettingsExpander.IsExpanded = _appSettings.AdvancedSettingsExpanded;
        }
        finally
        {
            _isLoadingAppSettings = false;
        }
    }

    private async Task AutoConnectLastProfileIfRequestedAsync()
    {
        if (!_appSettings.AutoConnectLastProfile || string.IsNullOrWhiteSpace(_appSettings.LastProfileId))
        {
            return;
        }

        var profile = _profiles.FirstOrDefault(item => item.Id == _appSettings.LastProfileId);
        if (profile is null)
        {
            return;
        }

        ProfilesListBox.SelectedItem = profile;
        await RunUiActionAsync(async () =>
        {
            var connectResult = await _vpnService.ConnectAsync(profile, PasswordBox.Password, GetTunnelConfig());
            _structuredLogService.WriteCommand("autoconnect", profile, connectResult);
            AppendCommandResult($"{profile.Protocol.ToDisplayName()} autoconnect", connectResult);

            await _connectionStateStore.UpdateAsync(
                profile,
                "autoconnect",
                connectResult.IsSuccess ? "Connected" : "Failed",
                connectResult);

            StatusTextBlock.Text = connectResult.IsSuccess
                ? "Подключено"
                : "Автоподключение не удалось";
            if (connectResult.IsSuccess)
            {
                profile.LastConnectedAt = DateTimeOffset.UtcNow;
                await _profileStore.SaveAsync(_profiles);
                RenderServerChoices(SubscriptionSelectorComboBox.SelectedItem as SubscriptionSourceListItem, profile.Id);
            }

            UpdateDailyStatusPanel(profile, connectResult.IsSuccess ? "Подключено" : "Автоподключение не удалось");
        }, "Автоподключение...");
    }

    private async Task SaveAppSettingsQuietlyAsync()
    {
        try
        {
            await _appSettingsStore.SaveAsync(_appSettings);
        }
        catch (Exception ex)
        {
            AppendLog(ex.Message);
        }
    }

    private async Task RememberSubscriptionSelectionAsync(string sourceId)
    {
        if (string.Equals(_appSettings.LastSubscriptionSourceId, sourceId, StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        _appSettings.LastSubscriptionSourceId = sourceId;
        await SaveAppSettingsQuietlyAsync();
    }

    private async Task RunUiActionAsync(Func<Task> action, string busyText)
    {
        if (_isBusy)
        {
            return;
        }

        SetBusy(true, busyText);

        try
        {
            await action();
        }
        catch (Exception ex)
        {
            StatusTextBlock.Text = "Ошибка";
            AppendLog(ex.Message);
            System.Windows.MessageBox.Show(this, ex.Message, "Ошибка", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            SetBusy(false);
        }
    }

    private void SetBusy(bool isBusy, string? statusText = null)
    {
        _isBusy = isBusy;

        SaveProfileButton.IsEnabled = !isBusy;
        NewProfileButton.IsEnabled = !isBusy;
        DeleteProfileButton.IsEnabled = !isBusy;
        ConnectButton.IsEnabled = !isBusy;
        DisconnectButton.IsEnabled = !isBusy;
        ServiceButton.IsEnabled = !isBusy;
        PreviewProtectionButton.IsEnabled = !isBusy;
        ApplyProtectionButton.IsEnabled = !isBusy;
        RemoveProtectionButton.IsEnabled = !isBusy;
        ResetProtectionButton.IsEnabled = !isBusy;
        ProtectionStatusButton.IsEnabled = !isBusy;
        RefreshSubscriptionButton.IsEnabled = !isBusy;
        RefreshAllSubscriptionsButton.IsEnabled = !isBusy;
        PasteSubscriptionButton.IsEnabled = !isBusy;
        DeleteSubscriptionButton.IsEnabled = !isBusy;
        SubscriptionSelectorComboBox.IsEnabled = !isBusy;
        ServerSelectorComboBox.IsEnabled = !isBusy;
        FavoriteServerButton.IsEnabled = !isBusy;
        BestServerButton.IsEnabled = !isBusy;
        DiagnosticsButton.IsEnabled = !isBusy;
        ExportDiagnosticsButton.IsEnabled = !isBusy;
        RunAsAdminButton.IsEnabled = !isBusy;
        RefreshStatusButton.IsEnabled = !isBusy;

        if (!string.IsNullOrWhiteSpace(statusText))
        {
            StatusTextBlock.Text = statusText;
        }
    }

    private void AppendCommandResult(string title, CommandResult result)
    {
        AppendLog($"{title}: exit {result.ExitCode}");

        if (!string.IsNullOrWhiteSpace(result.CombinedOutput))
        {
            AppendLog(result.CombinedOutput);
        }
    }

    private void AppendLog(string message)
    {
        LogTextBox.AppendText($"[{DateTime.Now:HH:mm:ss}] {message}{Environment.NewLine}");
        LogTextBox.ScrollToEnd();
        TryWriteInfoLog("ui.log", message);
    }

    private string GetTunnelConfig()
    {
        return TunnelConfigTextBox.Text.Trim();
    }

    private static bool IsProtectionRequested(VpnProfile profile)
    {
        return profile.KillSwitchEnabled || profile.DnsLeakProtectionEnabled;
    }

    private static bool TryParseEndpointFromConfig(string config, out string host, out int port)
    {
        host = string.Empty;
        port = 0;

        var endpointLine = config
            .Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .FirstOrDefault(line => line.StartsWith("Endpoint", StringComparison.OrdinalIgnoreCase));

        if (string.IsNullOrWhiteSpace(endpointLine))
        {
            return false;
        }

        var value = endpointLine.Split('=', 2, StringSplitOptions.TrimEntries).LastOrDefault();
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        var separatorIndex = value.LastIndexOf(':');
        if (separatorIndex <= 0 || separatorIndex >= value.Length - 1)
        {
            return false;
        }

        host = value[..separatorIndex].Trim('[', ']', ' ');
        return int.TryParse(value[(separatorIndex + 1)..], out port)
            && !string.IsNullOrWhiteSpace(host);
    }

    private static CommandResult ServiceUnavailableResult()
    {
        return new CommandResult(
            1,
            string.Empty,
            "Samhain Security Service is not running. Start it with the service button first.");
    }

    private void LoadSubscriptionState(IReadOnlyList<SubscriptionSource> subscriptions)
    {
        RenderSubscriptionSources(subscriptions);
    }

    private void RenderSubscriptionSources(
        IReadOnlyList<SubscriptionSource> subscriptions,
        string? preferredNormalizedUrl = null)
    {
        _isLoadingSubscriptions = true;
        try
        {
            _subscriptionSources.Clear();

            foreach (var source in subscriptions.OrderByDescending(item => item.UpdatedAt))
            {
                var url = _subscriptionStore.UnprotectUrl(source);
                if (string.IsNullOrWhiteSpace(url))
                {
                    continue;
                }

                _subscriptionSources.Add(new SubscriptionSourceListItem(source, url));
            }

            SubscriptionSourceListItem? selected = null;
            if (!string.IsNullOrWhiteSpace(preferredNormalizedUrl))
            {
                selected = _subscriptionSources.FirstOrDefault(item =>
                    string.Equals(
                        SubscriptionUrlNormalizer.Normalize(item.Url),
                        preferredNormalizedUrl,
                        StringComparison.OrdinalIgnoreCase));
            }

            selected ??= _subscriptionSources.FirstOrDefault(item =>
                string.Equals(
                    item.Source.Id,
                    _appSettings.LastSubscriptionSourceId,
                    StringComparison.OrdinalIgnoreCase));
            selected ??= _subscriptionSources.FirstOrDefault();
            SubscriptionSourcesListBox.SelectedItem = selected;
            SubscriptionSelectorComboBox.SelectedItem = selected;

            if (selected is null)
            {
                SubscriptionStatusTextBlock.Text = "Подписка не добавлена";
                RenderServerChoices(null);
                return;
            }

            SubscriptionUrlTextBox.Text = selected.Url;
            SubscriptionStatusTextBlock.Text = _subscriptionSources.Count > 1
                ? $"Источников: {_subscriptionSources.Count}. {selected.DisplayStatus}"
                : selected.DisplayStatus;
            RenderServerChoices(selected);
        }
        finally
        {
            _isLoadingSubscriptions = false;
        }
    }

    private void RenderServerChoices(SubscriptionSourceListItem? source, string? preferredProfileId = null)
    {
        _isLoadingServerChoices = true;
        try
        {
            _serverChoices.Clear();

            var profiles = GetProfilesForSubscription(source)
                .OrderByDescending(profile => profile.IsFavorite)
                .ThenByDescending(profile => profile.LastConnectedAt ?? DateTimeOffset.MinValue)
                .ThenBy(profile => profile.Name, StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(profile => profile.ServerAddress)
                .ToList();

            foreach (var profile in profiles)
            {
                _serverChoices.Add(new ServerListItem(profile));
            }

            ServerListItem? selected = null;
            if (!string.IsNullOrWhiteSpace(preferredProfileId))
            {
                selected = _serverChoices.FirstOrDefault(item => item.Profile.Id == preferredProfileId);
            }

            selected ??= ProfilesListBox.SelectedItem is VpnProfile activeProfile
                ? _serverChoices.FirstOrDefault(item => item.Profile.Id == activeProfile.Id)
                : null;
            selected ??= _serverChoices.FirstOrDefault();
            ServerSelectorComboBox.SelectedItem = selected;
            UpdateFavoriteServerButton();

            if (source is null)
            {
                SubscriptionStatusTextBlock.Text = _serverChoices.Count == 0
                    ? "Подписка не добавлена"
                    : $"Серверов: {_serverChoices.Count}";
                return;
            }

            SubscriptionStatusTextBlock.Text = $"{source.DisplayStatus}; серверов: {_serverChoices.Count}";
        }
        finally
        {
            _isLoadingServerChoices = false;
        }

        RefreshTrayMenu();
    }

    private IEnumerable<VpnProfile> GetProfilesForSubscription(SubscriptionSourceListItem? source)
    {
        if (source is null)
        {
            return _profiles;
        }

        var linkedProfiles = _profiles
            .Where(profile => string.Equals(
                profile.SubscriptionSourceId,
                source.Source.Id,
                StringComparison.OrdinalIgnoreCase))
            .ToList();

        if (linkedProfiles.Count > 0)
        {
            return linkedProfiles;
        }

        return _profiles.Where(profile => IsLegacyProfileLikelyFromSource(profile, source));
    }

    private static bool IsLegacyProfileLikelyFromSource(VpnProfile profile, SubscriptionSourceListItem source)
    {
        if (!string.IsNullOrWhiteSpace(profile.SubscriptionSourceId))
        {
            return false;
        }

        var sourceIsAwg = source.DisplayName.Contains("AWG", StringComparison.OrdinalIgnoreCase)
            || source.Url.Contains("/awg", StringComparison.OrdinalIgnoreCase)
            || source.Url.Contains("subscription-awg", StringComparison.OrdinalIgnoreCase);

        return sourceIsAwg
            ? profile.Protocol == VpnProtocolType.AmneziaWireGuard
            : profile.Protocol == VpnProtocolType.VlessReality;
    }

    private void UpdateFavoriteServerButton()
    {
        if (ServerSelectorComboBox.SelectedItem is not ServerListItem item)
        {
            FavoriteServerButton.Content = "Избранное";
            FavoriteServerButton.IsEnabled = !_isBusy && _serverChoices.Count > 0;
            return;
        }

        FavoriteServerButton.Content = item.Profile.IsFavorite ? "Убрать" : "Избранное";
        FavoriteServerButton.IsEnabled = !_isBusy;
        RefreshTrayMenu();
    }

    private async Task<SubscriptionRefreshResult> RefreshSubscriptionUrlAsync(
        string url,
        bool selectImportedProfile,
        CancellationToken cancellationToken = default)
    {
        var result = await _subscriptionImportService.ImportFromUrlAsync(url, cancellationToken);
        var sources = (await _subscriptionStore.LoadAsync(cancellationToken)).ToList();
        var normalizedUrl = SubscriptionUrlNormalizer.Normalize(url);
        var source = GetOrCreateSubscriptionSource(sources, url);
        var sourceName = BuildSubscriptionSourceName(result);

        foreach (var profile in result.Profiles)
        {
            profile.SubscriptionSourceId = source.Id;
            profile.SubscriptionName = sourceName;
        }

        var mergeResult = MergeSubscriptionProfiles(result.Profiles);

        if (mergeResult.Added > 0 || mergeResult.Updated > 0)
        {
            await _profileStore.SaveAsync(_profiles, cancellationToken);
        }

        var status = BuildSubscriptionStatus(result, mergeResult);
        source.Name = sourceName;
        source.EncryptedUrl = _subscriptionStore.ProtectUrl(url);
        source.LastUpdatedAt = DateTimeOffset.UtcNow;
        source.LastImportedCount = result.Profiles.Count;
        source.LastStatus = status;
        source.UpdatedAt = DateTimeOffset.UtcNow;

        await _subscriptionStore.SaveAsync(sources, cancellationToken);
        RenderSubscriptionSources(sources, normalizedUrl);

        SubscriptionStatusTextBlock.Text = status;
        AppendLog(status);

        if (selectImportedProfile && mergeResult.FirstProfile is not null)
        {
            ProfilesListBox.SelectedItem = mergeResult.FirstProfile;
            RenderServerChoices(SubscriptionSelectorComboBox.SelectedItem as SubscriptionSourceListItem, mergeResult.FirstProfile.Id);
        }

        return new SubscriptionRefreshResult(mergeResult.Added, mergeResult.Updated);
    }

    private SubscriptionSource GetOrCreateSubscriptionSource(List<SubscriptionSource> sources, string url)
    {
        var normalizedUrl = SubscriptionUrlNormalizer.Normalize(url);
        var source = sources.FirstOrDefault(item =>
            string.Equals(
                SubscriptionUrlNormalizer.Normalize(_subscriptionStore.UnprotectUrl(item)),
                normalizedUrl,
                StringComparison.OrdinalIgnoreCase));

        if (source is not null)
        {
            return source;
        }

        source = new SubscriptionSource();
        sources.Add(source);

        return source;
    }

    private static string BuildSubscriptionSourceName(SubscriptionImportResult result)
    {
        return result.SourceFormat.Contains("AWG", StringComparison.OrdinalIgnoreCase)
            ? "Samhain Security AWG"
            : "Samhain Security";
    }

    private SubscriptionMergeResult MergeSubscriptionProfiles(IReadOnlyList<VpnProfile> importedProfiles)
    {
        var added = 0;
        var updated = 0;
        VpnProfile? firstProfile = null;

        foreach (var imported in importedProfiles)
        {
            imported.UpdatedAt = DateTimeOffset.UtcNow;
            var existing = _profiles.FirstOrDefault(profile => IsSameImportedProfile(profile, imported));
            if (existing is null)
            {
                _profiles.Insert(0, imported);
                firstProfile ??= imported;
                added++;
                continue;
            }

            PreserveLocalProfileSettings(imported, existing);
            var index = _profiles.IndexOf(existing);
            _profiles[index] = imported;
            firstProfile ??= imported;
            updated++;
        }

        return new SubscriptionMergeResult(added, updated, firstProfile);
    }

    private static bool IsSameImportedProfile(VpnProfile existing, VpnProfile imported)
    {
        if (!string.IsNullOrWhiteSpace(existing.SubscriptionSourceId)
            && !string.IsNullOrWhiteSpace(imported.SubscriptionSourceId)
            && !string.Equals(existing.SubscriptionSourceId, imported.SubscriptionSourceId, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        if (existing.Protocol == VpnProtocolType.VlessReality
            && imported.Protocol == VpnProtocolType.VlessReality
            && string.Equals(existing.ServerAddress, imported.ServerAddress, StringComparison.OrdinalIgnoreCase)
            && existing.ServerPort == imported.ServerPort
            && string.Equals(existing.VlessUuid, imported.VlessUuid, StringComparison.OrdinalIgnoreCase)
            && string.Equals(existing.RealityPublicKey, imported.RealityPublicKey, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        if (existing.Protocol is VpnProtocolType.WireGuard or VpnProtocolType.AmneziaWireGuard
            && existing.Protocol == imported.Protocol
            && !string.IsNullOrWhiteSpace(imported.Name)
            && string.Equals(existing.Name, imported.Name, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        if (existing.Protocol is VpnProtocolType.WireGuard or VpnProtocolType.AmneziaWireGuard
            && existing.Protocol == imported.Protocol
            && !string.IsNullOrWhiteSpace(imported.ServerAddress)
            && string.Equals(existing.ServerAddress, imported.ServerAddress, StringComparison.OrdinalIgnoreCase)
            && existing.ServerPort == imported.ServerPort)
        {
            return true;
        }

        return !string.IsNullOrWhiteSpace(imported.Name)
            && string.Equals(existing.Name, imported.Name, StringComparison.OrdinalIgnoreCase);
    }

    private static void PreserveLocalProfileSettings(VpnProfile target, VpnProfile existing)
    {
        var importedTunnelConfig = target.EncryptedTunnelConfig;

        target.Id = existing.Id;
        target.EnginePath = existing.EnginePath;
        target.EncryptedPassword = existing.EncryptedPassword;
        target.EncryptedL2tpPsk = existing.EncryptedL2tpPsk;
        target.EncryptedTunnelConfig = string.IsNullOrWhiteSpace(importedTunnelConfig)
            ? existing.EncryptedTunnelConfig
            : importedTunnelConfig;
        target.SplitTunneling = existing.SplitTunneling;
        target.KillSwitchEnabled = existing.KillSwitchEnabled;
        target.DnsLeakProtectionEnabled = existing.DnsLeakProtectionEnabled;
        target.AllowLanTraffic = existing.AllowLanTraffic;
        target.DnsServers = existing.DnsServers;
        target.IsFavorite = existing.IsFavorite;
        target.LastConnectedAt = existing.LastConnectedAt;
    }

    private static string BuildSubscriptionStatus(
        SubscriptionImportResult result,
        SubscriptionMergeResult mergeResult)
    {
        var parts = new List<string>
        {
            $"Профили: +{mergeResult.Added}, обновлено {mergeResult.Updated}",
            $"формат: {result.SourceFormat}"
        };

        if (result.UnsupportedLinksSeen > 0)
        {
            parts.Add($"неподдерживаемых ссылок: {result.UnsupportedLinksSeen}");
        }

        if (result.Profiles.Count == 0)
        {
            parts.Add(result.Message);
        }

        return string.Join("; ", parts);
    }

    private void PasteCommand_CanExecute(object sender, CanExecuteRoutedEventArgs e)
    {
        if (Keyboard.FocusedElement is System.Windows.Controls.Primitives.TextBoxBase
            || Keyboard.FocusedElement is PasswordBox)
        {
            return;
        }

        e.CanExecute = TryGetSubscriptionUrlFromClipboard(out _);
        e.Handled = e.CanExecute;
    }

    private async void PasteCommand_Executed(object sender, ExecutedRoutedEventArgs e)
    {
        if (!TryGetSubscriptionUrlFromClipboard(out var url))
        {
            return;
        }

        e.Handled = true;
        SubscriptionUrlTextBox.Text = url;

        await RunUiActionAsync(async () =>
        {
            var refreshResult = await RefreshSubscriptionUrlAsync(url, selectImportedProfile: true);
            StatusTextBlock.Text = refreshResult.Added + refreshResult.Updated > 0
                ? "Подписка из буфера импортирована"
                : "Подписка из буфера проверена";
        }, "Импорт из буфера...");
    }

    private void TryPrimeSubscriptionFromClipboard(bool replaceCurrent)
    {
        if (!TryGetSubscriptionUrlFromClipboard(out var url))
        {
            return;
        }

        var normalizedUrl = SubscriptionUrlNormalizer.Normalize(url);
        var currentUrl = SubscriptionUrlTextBox.Text.Trim();
        var hasCurrentSubscription = TryExtractSubscriptionUrl(currentUrl, out var currentSubscriptionUrl);
        var currentNormalizedUrl = hasCurrentSubscription
            ? SubscriptionUrlNormalizer.Normalize(currentSubscriptionUrl)
            : string.Empty;

        if (string.Equals(normalizedUrl, currentNormalizedUrl, StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        if (string.Equals(normalizedUrl, _lastClipboardSubscriptionUrl, StringComparison.OrdinalIgnoreCase)
            && !replaceCurrent)
        {
            return;
        }

        _lastClipboardSubscriptionUrl = normalizedUrl;

        if (replaceCurrent || string.IsNullOrWhiteSpace(currentUrl) || !hasCurrentSubscription)
        {
            SubscriptionUrlTextBox.Text = url;
            SubscriptionStatusTextBlock.Text = "В буфере найдена ссылка подключения. Можно обновить источник.";
            return;
        }

        SubscriptionStatusTextBlock.Text = "В буфере найдена новая ссылка подключения. Нажмите Буфер, чтобы импортировать.";
    }

    private static bool TryGetSubscriptionUrlFromClipboard(out string url)
    {
        url = string.Empty;

        try
        {
            if (!System.Windows.Clipboard.ContainsText())
            {
                return false;
            }

            return TryExtractSubscriptionUrl(System.Windows.Clipboard.GetText(), out url);
        }
        catch
        {
            return false;
        }
    }

    private static bool TryExtractSubscriptionUrl(string value, out string url)
    {
        url = string.Empty;
        var trimmed = value.Trim();

        if (Uri.TryCreate(TrimCandidateUrl(trimmed), UriKind.Absolute, out var directUri)
            && IsSupportedSubscriptionUri(directUri))
        {
            url = directUri.ToString();
            return true;
        }

        foreach (Match match in SubscriptionUrlCandidateRegex().Matches(value))
        {
            var candidate = TrimCandidateUrl(match.Value);
            if (!Uri.TryCreate(candidate, UriKind.Absolute, out var uri)
                || !IsSupportedSubscriptionUri(uri))
            {
                continue;
            }

            url = uri.ToString();
            return true;
        }

        return false;
    }

    private static string TrimCandidateUrl(string value)
    {
        return value.Trim().TrimEnd('.', ',', ';', ')', ']', '}', '"', '\'');
    }

    private static bool IsSupportedSubscriptionUri(Uri uri)
    {
        if (uri.Scheme is not ("http" or "https"))
        {
            return false;
        }

        return uri.AbsolutePath.EndsWith("/subscription.html", StringComparison.OrdinalIgnoreCase)
            || uri.AbsolutePath.EndsWith("/subscription-awg.html", StringComparison.OrdinalIgnoreCase)
            || uri.AbsolutePath.Contains("/api/sub/", StringComparison.OrdinalIgnoreCase);
    }

    private static string MaskSubscriptionUrl(string url)
    {
        var masked = SubscriptionTokenQueryRegex().Replace(url, match =>
        {
            var token = match.Groups["token"].Value;
            return $"{match.Groups["prefix"].Value}{MaskToken(token)}";
        });

        return SubscriptionTokenPathRegex().Replace(masked, match =>
        {
            var token = match.Groups["token"].Value;
            return $"{match.Groups["prefix"].Value}{MaskToken(token)}";
        });
    }

    private static string MaskToken(string token)
    {
        return token.Length <= 4
            ? "****"
            : $"****{token[^4..]}";
    }

    private static int ParsePortOrDefault(string value)
    {
        return int.TryParse(value.Trim(), out var port)
            ? port
            : 443;
    }

    private static string GetAppVersion()
    {
        var version = Assembly.GetExecutingAssembly().GetName().Version;
        return version is null
            ? "0.0.1"
            : $"{version.Major}.{version.Minor}.{version.Build}";
    }

    private void TryWriteInfoLog(string eventName, string message)
    {
        try
        {
            _structuredLogService.WriteInfo(eventName, message);
        }
        catch
        {
            // UI logging must not fail because structured logging is unavailable.
        }
    }

    private void InitializeTrayIcon()
    {
        _notifyIcon = new Forms.NotifyIcon
        {
            Icon = SystemIcons.Shield,
            Text = "Samhain Security",
            Visible = true,
            ContextMenuStrip = BuildTrayMenu()
        };

        _notifyIcon.DoubleClick += (_, _) => ShowFromTray();
    }

    private void InitializeReconnectMonitors()
    {
        SystemEvents.PowerModeChanged += SystemEvents_PowerModeChanged;
        NetworkChange.NetworkAvailabilityChanged += NetworkChange_NetworkAvailabilityChanged;
        NetworkChange.NetworkAddressChanged += NetworkChange_NetworkAddressChanged;
    }

    private void UnsubscribeReconnectMonitors()
    {
        SystemEvents.PowerModeChanged -= SystemEvents_PowerModeChanged;
        NetworkChange.NetworkAvailabilityChanged -= NetworkChange_NetworkAvailabilityChanged;
        NetworkChange.NetworkAddressChanged -= NetworkChange_NetworkAddressChanged;
    }

    private void SystemEvents_PowerModeChanged(object sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Resume)
        {
            ScheduleReconnect("выход из сна");
        }
    }

    private void NetworkChange_NetworkAvailabilityChanged(object? sender, NetworkAvailabilityEventArgs e)
    {
        if (e.IsAvailable)
        {
            ScheduleReconnect("сеть доступна");
        }
    }

    private void NetworkChange_NetworkAddressChanged(object? sender, EventArgs e)
    {
        ScheduleReconnect("смена сети");
    }

    private void ScheduleReconnect(string reason)
    {
        if (!_appSettings.AutoReconnectOnSystemChange || string.IsNullOrWhiteSpace(_appSettings.LastProfileId))
        {
            return;
        }

        var now = DateTimeOffset.UtcNow;
        if (now - _lastReconnectAttemptAt < TimeSpan.FromSeconds(30))
        {
            return;
        }

        _lastReconnectAttemptAt = now;
        _ = Dispatcher.InvokeAsync(async () =>
        {
            await Task.Delay(TimeSpan.FromSeconds(3));
            await TryReconnectLastProfileAsync(reason);
        });
    }

    private async Task TryReconnectLastProfileAsync(string reason)
    {
        if (_isBusy)
        {
            return;
        }

        var profile = _profiles.FirstOrDefault(item => item.Id == _appSettings.LastProfileId);
        if (profile is null)
        {
            return;
        }

        ProfilesListBox.SelectedItem = profile;
        LoadProfileIntoEditor(profile);
        await RunUiActionAsync(async () =>
        {
            var password = _protector.Unprotect(profile.EncryptedPassword);
            var tunnelConfig = _protector.Unprotect(profile.EncryptedTunnelConfig);
            var connectResult = await _vpnService.ConnectAsync(profile, password, tunnelConfig);
            _structuredLogService.WriteCommand("reconnect", profile, connectResult);
            AppendCommandResult($"{profile.Protocol.ToDisplayName()} reconnect", connectResult);

            await _connectionStateStore.UpdateAsync(
                profile,
                "reconnect",
                connectResult.IsSuccess ? "Connected" : "Failed",
                connectResult);

            if (connectResult.IsSuccess)
            {
                profile.LastConnectedAt = DateTimeOffset.UtcNow;
                await _profileStore.SaveAsync(_profiles);
                RenderServerChoices(SubscriptionSelectorComboBox.SelectedItem as SubscriptionSourceListItem, profile.Id);
            }

            StatusTextBlock.Text = connectResult.IsSuccess
                ? $"Восстановлено: {reason}"
                : $"Восстановление не удалось: {reason}";
            UpdateDailyStatusPanel(profile, connectResult.IsSuccess ? "Подключено" : "Восстановление не удалось");
        }, $"Восстановление: {reason}...");
    }

    private Forms.ContextMenuStrip BuildTrayMenu()
    {
        var menu = new Forms.ContextMenuStrip();

        menu.Items.Add("Открыть", null, (_, _) => Dispatcher.Invoke(ShowFromTray));
        menu.Items.Add("Подключить выбранный", null, (_, _) => Dispatcher.Invoke(() => ConnectButton_Click(this, new RoutedEventArgs())));
        menu.Items.Add("Подключить лучший", null, (_, _) => Dispatcher.Invoke(ConnectBestServerFromTray));
        menu.Items.Add("Отключить", null, (_, _) => Dispatcher.Invoke(() => DisconnectButton_Click(this, new RoutedEventArgs())));
        menu.Items.Add(BuildTrayServersMenu());
        menu.Items.Add("Диагностика", null, (_, _) => Dispatcher.Invoke(() => DiagnosticsButton_Click(this, new RoutedEventArgs())));
        menu.Items.Add("Запуск от администратора", null, (_, _) => Dispatcher.Invoke(RelaunchAsAdministrator));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Выход", null, (_, _) => Dispatcher.Invoke(ExitApplication));

        return menu;
    }

    private Forms.ToolStripMenuItem BuildTrayServersMenu()
    {
        var serversMenu = new Forms.ToolStripMenuItem("Серверы");
        if (_serverChoices.Count == 0)
        {
            var emptyItem = new Forms.ToolStripMenuItem("Нет серверов") { Enabled = false };
            serversMenu.DropDownItems.Add(emptyItem);
            return serversMenu;
        }

        foreach (var server in _serverChoices.Take(10))
        {
            var menuItem = new Forms.ToolStripMenuItem(server.TrayLabel);
            menuItem.Click += (_, _) => Dispatcher.Invoke(() => ConnectServerFromTray(server));
            serversMenu.DropDownItems.Add(menuItem);
        }

        return serversMenu;
    }

    private void ConnectBestServerFromTray()
    {
        var best = _serverChoices.FirstOrDefault();
        if (best is null)
        {
            StatusTextBlock.Text = "Нет серверов";
            return;
        }

        ConnectServerFromTray(best);
    }

    private void ConnectServerFromTray(ServerListItem server)
    {
        ServerSelectorComboBox.SelectedItem = server;
        ApplyServerChoice(server, $"Сервер: {server.DisplayName}");
        ConnectButton_Click(this, new RoutedEventArgs());
    }

    private void RefreshTrayMenu()
    {
        if (_notifyIcon is null)
        {
            return;
        }

        var oldMenu = _notifyIcon.ContextMenuStrip;
        _notifyIcon.ContextMenuStrip = BuildTrayMenu();
        oldMenu?.Dispose();
    }

    private void ShowFromTray()
    {
        Show();
        WindowState = WindowState.Normal;
        Activate();
    }

    private void ExitApplication()
    {
        _allowExit = true;
        _notifyIcon?.Dispose();
        System.Windows.Application.Current.Shutdown();
    }

    private void RelaunchAsAdministrator()
    {
        if (AdminElevationService.IsAdministrator())
        {
            StatusTextBlock.Text = "Уже запущено от администратора";
            return;
        }

        if (!AdminElevationService.TryRelaunchAsAdministrator(out var error))
        {
            StatusTextBlock.Text = "Не удалось запустить от администратора";
            AppendLog(error);
            return;
        }

        ExitApplication();
    }

    private sealed record DailyProfileSnapshot(
        string Name,
        VpnProtocolType Protocol,
        string ServerAddress,
        int ServerPort,
        bool KillSwitchEnabled,
        bool DnsLeakProtectionEnabled,
        bool AllowLanTraffic);

    private sealed record SubscriptionMergeResult(int Added, int Updated, VpnProfile? FirstProfile);

    private sealed record SubscriptionRefreshResult(int Added, int Updated);

    private sealed class SubscriptionSourceListItem(SubscriptionSource source, string url)
    {
        public SubscriptionSource Source { get; } = source;

        public string Url { get; } = url;

        public string DisplayName => string.IsNullOrWhiteSpace(Source.Name)
            ? "Samhain Security"
            : Source.Name;

        public string SelectorName => $"{DisplayName} · {Source.LastImportedCount} серверов";

        public string MaskedUrl => MaskSubscriptionUrl(Url);

        public string DisplayStatus
        {
            get
            {
                var imported = Source.LastImportedCount > 0
                    ? $"профилей: {Source.LastImportedCount}"
                    : "профилей: 0";
                var updated = Source.LastUpdatedAt is null
                    ? "не обновлялась"
                    : Source.LastUpdatedAt.Value.ToLocalTime().ToString("dd.MM.yyyy HH:mm");

                return $"{imported}; {updated}";
            }
        }
    }

    private sealed class ServerListItem(VpnProfile profile)
    {
        public VpnProfile Profile { get; } = profile;

        public string DisplayName => string.IsNullOrWhiteSpace(Profile.Name)
            ? BuildServerEndpoint(Profile)
            : Profile.Name;

        public string Details => $"{Profile.Protocol.ToDisplayName()} · {BuildServerEndpoint(Profile)}";

        public string MenuLabel => BuildMenuLabel(Profile);

        public string TrayLabel => $"{DisplayName} ({Profile.Protocol.ToDisplayName()})";

        private static string BuildMenuLabel(VpnProfile profile)
        {
            var markers = new List<string>();
            if (profile.IsFavorite)
            {
                markers.Add("избранный");
            }

            if (profile.LastConnectedAt is not null)
            {
                markers.Add("последний");
            }

            return markers.Count == 0
                ? profile.Protocol.ToDisplayName()
                : $"{profile.Protocol.ToDisplayName()} · {string.Join(", ", markers)}";
        }

        private static string BuildServerEndpoint(VpnProfile profile)
        {
            if (string.IsNullOrWhiteSpace(profile.ServerAddress))
            {
                return "маршрут из конфигурации";
            }

            return profile.ServerPort > 0
                ? $"{profile.ServerAddress}:{profile.ServerPort}"
                : profile.ServerAddress;
        }
    }

    [GeneratedRegex(@"https?://[^\s""'<>]+", RegexOptions.Compiled)]
    private static partial Regex SubscriptionUrlCandidateRegex();

    [GeneratedRegex(@"(?i)(?<prefix>[?&]token=)(?<token>[^&#]+)", RegexOptions.Compiled)]
    private static partial Regex SubscriptionTokenQueryRegex();

    [GeneratedRegex(@"(?i)(?<prefix>/api/sub/)(?<token>[^/?#]+)", RegexOptions.Compiled)]
    private static partial Regex SubscriptionTokenPathRegex();
}
