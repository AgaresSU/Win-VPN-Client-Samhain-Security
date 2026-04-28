using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Net.NetworkInformation;
using System.Reflection;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;
using SamhainSecurity.Models;
using SamhainSecurity.Services;
using Forms = System.Windows.Forms;

namespace SamhainSecurity;

public partial class MainWindow : Window
{
    private const int MaxServerProbesPerRun = 60;
    private const int MaxConcurrentServerProbes = 6;
    private const int MaxFailoverCandidates = 3;

    private readonly ObservableCollection<VpnProfile> _profiles = [];
    private readonly ObservableCollection<SubscriptionSourceListItem> _subscriptionSources = [];
    private readonly ObservableCollection<ServerListItem> _serverChoices = [];
    private readonly ObservableCollection<EngineCatalogEntry> _engineCatalog = [];
    private ICollectionView? _serverChoicesView;
    private readonly ProfileStore _profileStore = new();
    private readonly AppSettingsStore _appSettingsStore = new();
    private readonly StartupRegistrationService _startupRegistrationService = new();
    private readonly SecureDataProtector _protector = new();
    private readonly SubscriptionStore _subscriptionStore;
    private readonly SubscriptionImportService _subscriptionImportService;
    private readonly MultiProtocolVpnService _vpnService = new();
    private readonly ServerProbeService _serverProbeService = new();
    private readonly EnvironmentDiagnosticsService _diagnosticsService = new();
    private readonly EngineAvailabilityService _engineAvailabilityService = new();
    private readonly EngineCatalogService _engineCatalogService = new();
    private readonly ServiceControlService _serviceControlService = new();
    private readonly SamhainServiceClient _serviceClient = new();
    private readonly ConnectionStateStore _connectionStateStore = new();
    private readonly StructuredLogService _structuredLogService = new();
    private readonly ConnectionHistoryStore _connectionHistoryStore = new();
    private readonly DiagnosticsBundleService _diagnosticsBundleService;
    private readonly ReleaseReadinessService _releaseReadinessService = new();
    private readonly DispatcherTimer _connectionWatchdogTimer = new()
    {
        Interval = TimeSpan.FromSeconds(60)
    };
    private Forms.NotifyIcon? _notifyIcon;
    private bool _allowExit;
    private bool _isBusy;
    private bool _isLoadingProfile;
    private bool _isLoadingSubscriptions;
    private bool _isLoadingServerChoices;
    private bool _isLoadingAppSettings;
    private bool _isBackgroundProbeRunning;
    private bool _isRefreshingSubscriptionsQuietly;
    private bool _isWatchdogChecking;
    private string _lastClipboardSubscriptionUrl = string.Empty;
    private string _watchdogProfileId = string.Empty;
    private string _dailyConnectionState = "Ожидание";
    private string _dailyServiceState = "Служба: проверка";
    private string _releaseReadinessState = "Среда: проверка не запускалась";
    private DateTimeOffset _lastReconnectAttemptAt = DateTimeOffset.MinValue;
    private DateTimeOffset _lastWatchdogRecoveryAt = DateTimeOffset.MinValue;
    private AppSettings _appSettings = new();

    public MainWindow()
    {
        _subscriptionStore = new SubscriptionStore(_protector);
        _subscriptionImportService = new SubscriptionImportService(_protector);
        _diagnosticsBundleService = new DiagnosticsBundleService(
            _profileStore,
            _connectionStateStore,
            _structuredLogService,
            _connectionHistoryStore);

        InitializeComponent();

        VersionTextBlock.Text = "v" + GetAppVersion();
        ProfilesListBox.ItemsSource = _profiles;
        SubscriptionSourcesListBox.ItemsSource = _subscriptionSources;
        SubscriptionSelectorComboBox.ItemsSource = _subscriptionSources;
        ServerSelectorComboBox.ItemsSource = _serverChoices;
        ServersListView.ItemsSource = _serverChoices;
        EngineCatalogListView.ItemsSource = _engineCatalog;
        _serverChoicesView = CollectionViewSource.GetDefaultView(_serverChoices);
        _serverChoicesView.Filter = FilterServerChoice;
        _isLoadingServerChoices = true;
        try
        {
            ServerSortComboBox.SelectedIndex = 0;
        }
        finally
        {
            _isLoadingServerChoices = false;
        }

        UpdateServerCatalogSummary();
        UpdateServerRecommendations();
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
        InitializeConnectionWatchdog();
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
            UpdateFirstRunPanel();

            AppendLog($"Профили: {_profiles.Count}. Хранилище: {_profileStore.FilePath}");
            AppendLog($"Подписки: {subscriptions.Count}. Хранилище: {_subscriptionStore.FilePath}");
        }, "Загрузка профилей...");

        await RefreshDailyServiceStateAsync();
        await RefreshHistorySummaryAsync();
        await RefreshEngineCatalogAsync(showStatus: false);
        _ = RefreshReleaseReadinessAsync(isAutomatic: true);
        _ = RefreshDueSubscriptionsQuietlyAsync();
        _ = ProbeServerChoicesInBackgroundAsync("проверка при запуске");
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
        _connectionWatchdogTimer.Stop();
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
            UpdateSubscriptionEditor(item);
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
        UpdateSubscriptionEditor(item);
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

    private void ServersListView_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (_isLoadingServerChoices || ServersListView.SelectedItem is not ServerListItem item)
        {
            return;
        }

        ServerSelectorComboBox.SelectedItem = item;
        ApplyServerChoice(item, $"Сервер: {item.DisplayName}");
    }

    private void ServersListView_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        ConnectSelectedServerFromCatalog();
    }

    private void ServersListView_KeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            e.Handled = true;
            ConnectSelectedServerFromCatalog();
        }
    }

    private void ServerCategoryButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not System.Windows.Controls.Button { Tag: string category })
        {
            return;
        }

        ApplyServerCategory(category);
    }

    private void ApplyServerCategory(string category)
    {
        var normalizedCategory = category.Trim().ToLowerInvariant();
        ServerSearchTextBox.Clear();
        FavoriteServersOnlyCheckBox.IsChecked = false;

        var statusText = "Показаны все серверы";
        switch (normalizedCategory)
        {
            case "favorite":
                FavoriteServersOnlyCheckBox.IsChecked = true;
                SelectServerSortMode("favorite");
                statusText = "Показаны избранные серверы";
                break;
            case "fast":
                SelectServerSortMode("latency");
                statusText = "Показаны быстрые серверы";
                break;
            case "recent":
                SelectServerSortMode("recent");
                statusText = "Показаны последние серверы";
                break;
            case "vless":
                SelectServerSortMode("smart");
                ServerSearchTextBox.Text = "VLESS";
                statusText = "Показаны VLESS серверы";
                break;
            case "awg":
                SelectServerSortMode("smart");
                ServerSearchTextBox.Text = "AmneziaWG";
                statusText = "Показаны AWG серверы";
                break;
            default:
                SelectServerSortMode("smart");
                break;
        }

        RefreshServerCatalogView();
        StatusTextBlock.Text = statusText;
    }

    private void ServersListView_PreviewMouseRightButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (FindVisualParent<System.Windows.Controls.ListViewItem>(e.OriginalSource as DependencyObject) is not { } row)
        {
            return;
        }

        row.IsSelected = true;
        row.Focus();

        if (row.DataContext is ServerListItem item)
        {
            ServerSelectorComboBox.SelectedItem = item;
            ApplyServerChoice(item, $"Сервер: {item.DisplayName}");
        }
    }

    private void ServersListContextMenu_Opened(object sender, RoutedEventArgs e)
    {
        var selected = GetSelectedServerChoice();
        ServerContextFavoriteMenuItem.Header = selected?.Profile.IsFavorite == true
            ? "Убрать из избранного"
            : "В избранное";
        ServerContextFavoriteMenuItem.IsEnabled = !_isBusy && selected is not null;
    }

    private void ServerContextConnectMenuItem_Click(object sender, RoutedEventArgs e)
    {
        ConnectSelectedServerFromCatalog();
    }

    private async void ServerContextFavoriteMenuItem_Click(object sender, RoutedEventArgs e)
    {
        if (GetSelectedServerChoice() is not { } item)
        {
            StatusTextBlock.Text = "Выберите сервер";
            return;
        }

        await ToggleServerFavoriteAsync(item);
    }

    private void ServerContextCopyEndpointMenuItem_Click(object sender, RoutedEventArgs e)
    {
        if (GetSelectedServerChoice() is not { } item)
        {
            StatusTextBlock.Text = "Выберите сервер";
            return;
        }

        System.Windows.Clipboard.SetText(item.Endpoint);
        StatusTextBlock.Text = "Адрес сервера скопирован";
    }

    private void RecommendedServerButton_Click(object sender, RoutedEventArgs e)
    {
        SelectRecommendedServer(GetBestServerChoice(visibleOnly: true), "Рекомендуем");
    }

    private void FavoriteRecommendationButton_Click(object sender, RoutedEventArgs e)
    {
        SelectRecommendedServer(GetFavoriteServerChoice(visibleOnly: true), "Избранный");
    }

    private void RecentServerButton_Click(object sender, RoutedEventArgs e)
    {
        SelectRecommendedServer(GetRecentServerChoice(visibleOnly: true), "Последний");
    }

    private void ServerCatalogFilter_Changed(object sender, RoutedEventArgs e)
    {
        if (_isLoadingAppSettings)
        {
            return;
        }

        RefreshServerCatalogView();

        if (ReferenceEquals(sender, FavoriteServersOnlyCheckBox))
        {
            _appSettings.ServerCatalogFavoritesOnly = FavoriteServersOnlyCheckBox.IsChecked == true;
            _ = SaveAppSettingsQuietlyAsync();
        }
    }

    private void ServerSearchTextBox_KeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            e.Handled = true;
            if (string.IsNullOrWhiteSpace(ServerSearchTextBox.Text))
            {
                StatusTextBlock.Text = "Поиск уже пуст";
                return;
            }

            ServerSearchTextBox.Clear();
            StatusTextBlock.Text = "Поиск очищен";
            return;
        }

        if (e.Key == Key.Enter)
        {
            e.Handled = true;
            SelectFirstVisibleServerFromSearch();
        }
    }

    private void ClearServerFiltersButton_Click(object sender, RoutedEventArgs e)
    {
        if (!HasActiveServerCatalogFilter())
        {
            StatusTextBlock.Text = "Фильтры уже сброшены";
            return;
        }

        ServerSearchTextBox.Clear();
        FavoriteServersOnlyCheckBox.IsChecked = false;
        SelectServerSortMode("smart");
        RefreshServerCatalogView();
        StatusTextBlock.Text = "Фильтры серверов сброшены";
    }

    private void ServerSortComboBox_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (_isLoadingAppSettings)
        {
            return;
        }

        if (_isLoadingServerChoices)
        {
            return;
        }

        _appSettings.ServerCatalogSortMode = GetServerSortMode();
        _ = SaveAppSettingsQuietlyAsync();
        var selectedProfileId = (ServerSelectorComboBox.SelectedItem as ServerListItem)?.Profile.Id
            ?? (ServersListView.SelectedItem as ServerListItem)?.Profile.Id;
        RenderServerChoices(SubscriptionSelectorComboBox.SelectedItem as SubscriptionSourceListItem, selectedProfileId);
    }

    private void ApplySelectedServerChoice(string statusText)
    {
        if (ServerSelectorComboBox.SelectedItem is ServerListItem item)
        {
            ApplyServerChoice(item, statusText);
        }
    }

    private void SelectFirstVisibleServerFromSearch()
    {
        var first = GetVisibleServerChoices().FirstOrDefault();
        if (first is null)
        {
            StatusTextBlock.Text = HasActiveServerCatalogFilter()
                ? "Нет серверов по фильтрам"
                : "Нет серверов";
            return;
        }

        SelectRecommendedServer(first, "Найден");
    }

    private void SelectRecommendedServer(ServerListItem? item, string label)
    {
        if (item is null)
        {
            StatusTextBlock.Text = "Подходящий сервер не найден";
            return;
        }

        ServerSelectorComboBox.SelectedItem = item;
        ServersListView.SelectedItem = item;
        ServersListView.ScrollIntoView(item);
        ApplyServerChoice(item, $"{label}: {item.DisplayName}");
    }

    private void ConnectSelectedServerFromCatalog()
    {
        var selected = GetSelectedServerChoice();
        if (selected is null)
        {
            StatusTextBlock.Text = "Выберите сервер";
            return;
        }

        ServerSelectorComboBox.SelectedItem = selected;
        ApplyServerChoice(selected, $"Сервер: {selected.DisplayName}");
        ConnectButton_Click(this, new RoutedEventArgs());
    }

    private void ApplyServerChoice(ServerListItem item, string statusText)
    {
        ProfilesListBox.SelectedItem = item.Profile;
        if (!ReferenceEquals(ServersListView.SelectedItem, item))
        {
            ServersListView.SelectedItem = item;
        }

        LoadProfileIntoEditor(item.Profile);
        StatusTextBlock.Text = statusText;
        UpdateDailyStatusPanel(item.Profile);
        UpdateFavoriteServerButton();
    }

    private async void FavoriteServerButton_Click(object sender, RoutedEventArgs e)
    {
        if (GetSelectedServerChoice() is not { } item)
        {
            StatusTextBlock.Text = "Выберите сервер";
            return;
        }

        await ToggleServerFavoriteAsync(item);
    }

    private async Task ToggleServerFavoriteAsync(ServerListItem item)
    {
        item.Profile.IsFavorite = !item.Profile.IsFavorite;
        item.Profile.UpdatedAt = DateTimeOffset.UtcNow;
        await _profileStore.SaveAsync(_profiles);
        RenderServerChoices(SubscriptionSelectorComboBox.SelectedItem as SubscriptionSourceListItem, item.Profile.Id);
        StatusTextBlock.Text = item.Profile.IsFavorite
            ? "Сервер добавлен в избранное"
            : "Сервер убран из избранного";
    }

    private ServerListItem? GetSelectedServerChoice()
    {
        return ServersListView.SelectedItem as ServerListItem
            ?? ServerSelectorComboBox.SelectedItem as ServerListItem;
    }

    private static T? FindVisualParent<T>(DependencyObject? child)
        where T : DependencyObject
    {
        while (child is not null)
        {
            if (child is T typed)
            {
                return typed;
            }

            child = VisualTreeHelper.GetParent(child);
        }

        return null;
    }

    private void BestServerButton_Click(object sender, RoutedEventArgs e)
    {
        var best = GetBestServerChoice(visibleOnly: true);

        if (best is null)
        {
            StatusTextBlock.Text = "Нет серверов";
            return;
        }

        ServerSelectorComboBox.SelectedItem = best;
        ApplyServerChoice(best, $"Лучший сервер: {best.DisplayName}");
    }

    private async void ProbeServersButton_Click(object sender, RoutedEventArgs e)
    {
        await RunUiActionAsync(async () =>
        {
            var selectedProfileId = (ServerSelectorComboBox.SelectedItem as ServerListItem)?.Profile.Id;
            var source = SubscriptionSelectorComboBox.SelectedItem as SubscriptionSourceListItem;
            var visibleServerCount = GetVisibleServerChoices().Count();
            var targets = GetVisibleServerChoices()
                .Select(item => item.Profile)
                .Take(MaxServerProbesPerRun)
                .ToList();

            if (targets.Count == 0)
            {
                StatusTextBlock.Text = "Нет серверов для проверки";
                return;
            }

            var completed = 0;
            var available = 0;
            using var throttler = new SemaphoreSlim(MaxConcurrentServerProbes);

            var tasks = targets.Select(async profile =>
            {
                await throttler.WaitAsync();
                try
                {
                    var tunnelConfig = profile.Protocol is VpnProtocolType.WireGuard or VpnProtocolType.AmneziaWireGuard
                        ? _protector.Unprotect(profile.EncryptedTunnelConfig)
                        : string.Empty;
                    var result = await _serverProbeService.ProbeAsync(profile, tunnelConfig);

                    profile.LastLatencyMs = result.LatencyMs;
                    profile.LastProbeStatus = result.Status;
                    profile.LastProbedAt = DateTimeOffset.UtcNow;
                    profile.UpdatedAt = DateTimeOffset.UtcNow;

                    if (result.IsSuccess)
                    {
                        Interlocked.Increment(ref available);
                    }
                }
                finally
                {
                    var count = Interlocked.Increment(ref completed);
                    await Dispatcher.InvokeAsync(() =>
                    {
                        StatusTextBlock.Text = $"Проверка серверов: {count}/{targets.Count}";
                    });
                    throttler.Release();
                }
            });

            await Task.WhenAll(tasks);
            await _profileStore.SaveAsync(_profiles);
            RenderServerChoices(source, selectedProfileId);

            StatusTextBlock.Text = targets.Count >= MaxServerProbesPerRun && visibleServerCount > MaxServerProbesPerRun
                ? $"Проверено серверов: {completed}; доступны: {available}; лимит за раз: {MaxServerProbesPerRun}"
                : $"Проверено серверов: {completed}; доступны: {available}";
        }, "Проверка серверов...");
    }

    private async void ResetServerHealthButton_Click(object sender, RoutedEventArgs e)
    {
        await RunUiActionAsync(async () =>
        {
            var source = SubscriptionSelectorComboBox.SelectedItem as SubscriptionSourceListItem;
            var profiles = GetProfilesForSubscription(source).ToList();
            if (profiles.Count == 0)
            {
                StatusTextBlock.Text = "Нет серверов";
                return;
            }

            foreach (var profile in profiles)
            {
                profile.LastLatencyMs = null;
                profile.LastProbeStatus = string.Empty;
                profile.LastProbedAt = null;
                profile.LastWatchdogCheckedAt = null;
                profile.WatchdogFailureCount = 0;
                profile.LastWatchdogMessage = string.Empty;
                profile.UpdatedAt = DateTimeOffset.UtcNow;
            }

            await _profileStore.SaveAsync(_profiles);
            RenderServerChoices(source, (ServerSelectorComboBox.SelectedItem as ServerListItem)?.Profile.Id);
            UpdateDailyStatusPanel(GetCurrentOrSelectedProfile());
            StatusTextBlock.Text = $"Статусы сброшены: {profiles.Count}";
        }, "Сброс статусов...");
    }

    private void ProtocolComboBox_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (_isLoadingProfile)
        {
            return;
        }

        UpdateProtocolFields();
        _ = RefreshEngineCatalogAsync(showStatus: false);
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
        _appSettings.AutoFailoverOnConnectFailure = AutoFailoverCheckBox.IsChecked == true;
        _appSettings.ConnectBestServerAutomatically = AutoBestServerCheckBox.IsChecked == true;
        _appSettings.AutoRefreshSubscriptions = AutoRefreshSubscriptionsCheckBox.IsChecked == true;
        _appSettings.EnableConnectionWatchdog = ConnectionWatchdogCheckBox.IsChecked == true;

        try
        {
            _startupRegistrationService.SetEnabled(_appSettings.LaunchAtStartup);
            await _appSettingsStore.SaveAsync(_appSettings);
            if (!_appSettings.EnableConnectionWatchdog)
            {
                StopConnectionWatchdog();
            }
            else if (IsConnectedState(_dailyConnectionState) && GetCurrentOrSelectedProfile() is { } profile)
            {
                StartConnectionWatchdog(profile);
            }

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
            if (_appSettings.ConnectBestServerAutomatically && GetBestServerChoice() is { } bestServer)
            {
                ApplyServerChoice(bestServer, $"Лучший сервер: {bestServer.DisplayName}");
            }

            var profile = await SaveCurrentProfileAsync();
            if (profile is null)
            {
                return;
            }

            var connection = await ConnectWithFailoverAsync(profile, PasswordBox.Password, GetTunnelConfig(), "connect");
            var connectResult = connection.Result;
            var connectedProfile = connection.Profile;

            if (connectResult.IsSuccess)
            {
                _appSettings.LastProfileId = connectedProfile.Id;
                await _profileStore.SaveAsync(_profiles);
                await SaveAppSettingsQuietlyAsync();
                RenderServerChoices(SubscriptionSelectorComboBox.SelectedItem as SubscriptionSourceListItem, connectedProfile.Id);
                StartConnectionWatchdog(connectedProfile);
            }
            else
            {
                await _profileStore.SaveAsync(_profiles);
                RenderServerChoices(SubscriptionSelectorComboBox.SelectedItem as SubscriptionSourceListItem, profile.Id);
                StopConnectionWatchdog();
            }

            StatusTextBlock.Text = connectResult.IsSuccess
                ? connection.UsedFailover
                    ? $"Подключено через резерв: {connectedProfile.Name}"
                    : "Подключено"
                : FriendlyErrorService.ToUserMessage(connectResult);
            UpdateDailyStatusPanel(connectedProfile, connectResult.IsSuccess ? "Подключено" : "Ошибка подключения");

            if (connectResult.IsSuccess && IsProtectionRequested(connectedProfile))
            {
                var protectionResult = await _serviceClient.ApplyProtectionAsync(connectedProfile)
                    ?? ServiceUnavailableResult();
                AppendCommandResult("protection apply", protectionResult);
                UpdateDailyStatusPanel(
                    connectedProfile,
                    protectionResult.IsSuccess ? "Подключено, защита включена" : "Защита требует внимания");
            }
        }, "Подключение...");
    }

    private async Task<ConnectionFlowResult> ConnectWithFailoverAsync(
        VpnProfile initialProfile,
        string initialPassword,
        string initialTunnelConfig,
        string actionName)
    {
        SetConnectionStage("Подключается", 18, $"Сервер: {initialProfile.Name}");
        var initialResult = await ConnectSingleProfileAsync(
            initialProfile,
            initialPassword,
            initialTunnelConfig,
            actionName,
            "connect");
        if (initialResult.IsSuccess || !_appSettings.AutoFailoverOnConnectFailure)
        {
            return new ConnectionFlowResult(initialProfile, initialResult, false, 1);
        }

        var candidates = GetFailoverCandidates(initialProfile)
            .Take(MaxFailoverCandidates)
            .ToList();
        var attempts = 1;
        var lastResult = initialResult;

        foreach (var candidate in candidates)
        {
            attempts++;
            SetConnectionStage("Резерв", Math.Min(35 + attempts * 12, 82), $"Пробую: {candidate.Name}");
            SelectProfileForConnection(candidate, $"Пробую другой сервер: {candidate.Name}");

            var prepareResult = await _vpnService.PrepareProfileAsync(
                candidate,
                _protector.Unprotect(candidate.EncryptedL2tpPsk));
            _structuredLogService.WriteCommand(actionName + ".failover.prepare", candidate, prepareResult);
            if (!prepareResult.IsSuccess)
            {
                AppendCommandResult($"{candidate.Protocol.ToDisplayName()} reserve prepare", prepareResult);
                MarkProfileConnectFailed(candidate);
                continue;
            }

            lastResult = await ConnectSingleProfileAsync(
                candidate,
                _protector.Unprotect(candidate.EncryptedPassword),
                _protector.Unprotect(candidate.EncryptedTunnelConfig),
                actionName + ".failover",
                "reserve connect");

            if (lastResult.IsSuccess)
            {
                SetConnectionStage("Подключено", 100, $"Рабочий сервер: {candidate.Name}", showProgress: false);
                return new ConnectionFlowResult(candidate, lastResult, true, attempts);
            }
        }

        SetConnectionStage("Ошибка", 0, FriendlyErrorService.ToUserMessage(lastResult), showProgress: false);
        SelectProfileForConnection(initialProfile, "Подключение не удалось");
        return new ConnectionFlowResult(initialProfile, lastResult, false, attempts);
    }

    private async Task<CommandResult> ConnectSingleProfileAsync(
        VpnProfile profile,
        string password,
        string tunnelConfig,
        string actionName,
        string logTitle)
    {
        var connectResult = await _vpnService.ConnectAsync(profile, password, tunnelConfig);
        _structuredLogService.WriteCommand(actionName, profile, connectResult);
        AppendCommandResult($"{profile.Protocol.ToDisplayName()} {logTitle}", connectResult);

        await _connectionStateStore.UpdateAsync(
            profile,
            actionName,
            connectResult.IsSuccess ? "Connected" : "Failed",
            connectResult);
        await RecordConnectionHistoryAsync(profile, actionName, connectResult);

        if (connectResult.IsSuccess)
        {
            MarkProfileConnected(profile);
            SetConnectionStage("Подключено", 100, $"Рабочий сервер: {profile.Name}", showProgress: false);
        }
        else
        {
            MarkProfileConnectFailed(profile);
            SetConnectionStage("Ошибка", 0, FriendlyErrorService.ToUserMessage(connectResult), showProgress: false);
        }

        return connectResult;
    }

    private void SetConnectionStage(string state, int progress, string detail, bool showProgress = true)
    {
        DailyConnectionStateTextBlock.Text = state;
        StatusTextBlock.Text = detail;
        ConnectionDetailTextBlock.Text = detail;
        ConnectionProgressBar.Value = Math.Clamp(progress, 0, 100);
        ConnectionProgressBar.Visibility = showProgress ? Visibility.Visible : Visibility.Collapsed;
        ApplyDailyConnectionBrush(state);
    }

    private void SelectProfileForConnection(VpnProfile profile, string statusText)
    {
        ProfilesListBox.SelectedItem = profile;
        var serverItem = _serverChoices.FirstOrDefault(item => item.Profile.Id == profile.Id);
        if (serverItem is not null)
        {
            ServerSelectorComboBox.SelectedItem = serverItem;
        }

        LoadProfileIntoEditor(profile);
        StatusTextBlock.Text = statusText;
    }

    private IEnumerable<VpnProfile> GetFailoverCandidates(VpnProfile failedProfile)
    {
        var source = SubscriptionSelectorComboBox.SelectedItem as SubscriptionSourceListItem;
        var profiles = GetProfilesForSubscription(source);
        if (source is null && !string.IsNullOrWhiteSpace(failedProfile.SubscriptionSourceId))
        {
            profiles = profiles.Where(profile => string.Equals(
                profile.SubscriptionSourceId,
                failedProfile.SubscriptionSourceId,
                StringComparison.OrdinalIgnoreCase));
        }

        return profiles
            .Where(profile => profile.Id != failedProfile.Id)
            .OrderBy(profile => GetServerSortKey(profile).ProbeBucket)
            .ThenByDescending(profile => profile.IsFavorite)
            .ThenBy(profile => GetServerSortKey(profile).LatencyMs)
            .ThenByDescending(profile => profile.LastConnectedAt ?? DateTimeOffset.MinValue)
            .ThenBy(profile => profile.Name, StringComparer.CurrentCultureIgnoreCase)
            .ThenBy(profile => profile.ServerAddress);
    }

    private static void MarkProfileConnected(VpnProfile profile)
    {
        profile.LastConnectedAt = DateTimeOffset.UtcNow;
        profile.LastProbeStatus = ServerProbeStatus.Connected;
        profile.LastLatencyMs ??= 0;
        profile.LastProbedAt = DateTimeOffset.UtcNow;
        profile.WatchdogFailureCount = 0;
        profile.LastWatchdogMessage = "Подключено";
        profile.UpdatedAt = DateTimeOffset.UtcNow;
    }

    private static void MarkProfileConnectFailed(VpnProfile profile)
    {
        profile.LastLatencyMs = null;
        profile.LastProbeStatus = ServerProbeStatus.Failed;
        profile.LastProbedAt = DateTimeOffset.UtcNow;
        profile.WatchdogFailureCount++;
        profile.LastWatchdogMessage = "Подключение не удалось";
        profile.UpdatedAt = DateTimeOffset.UtcNow;
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
            await RecordConnectionHistoryAsync(profile, "disconnect", disconnectResult);

            StatusTextBlock.Text = disconnectResult.IsSuccess
                ? "Отключено"
                : "Отключение не удалось";
            if (disconnectResult.IsSuccess)
            {
                StopConnectionWatchdog();
            }

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
            await RecordConnectionHistoryAsync(profile, "status", statusResult);

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
            _ = RefreshEngineCatalogAsync(showStatus: true);
        }
    }

    private async void CheckEnginesButton_Click(object sender, RoutedEventArgs e)
    {
        await RunUiActionAsync(async () =>
        {
            await RefreshEngineCatalogAsync(showStatus: true);
        }, "Проверка движков...");
    }

    private void UseEngineButton_Click(object sender, RoutedEventArgs e)
    {
        if (EngineCatalogListView.SelectedItem is not EngineCatalogEntry entry)
        {
            StatusTextBlock.Text = "Выберите движок";
            return;
        }

        ProtocolComboBox.SelectedValue = entry.Protocol;
        if (entry.IsAvailable)
        {
            EnginePathTextBox.Text = entry.Path;
            StatusTextBlock.Text = $"Движок выбран: {entry.Name}";
            EngineManagerStatusTextBlock.Text = $"{entry.Name}: {entry.Status}";
            UpdateEngineStatusBadge();
            return;
        }

        EnginePathTextBox.Text = string.Empty;
        StatusTextBlock.Text = entry.Hint;
        EngineManagerStatusTextBlock.Text = entry.Hint;
    }

    private void OpenEnginesFolderButton_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            _engineCatalogService.EnsurePortableFolders();
            Process.Start(new ProcessStartInfo
            {
                FileName = _engineCatalogService.PortableEngineRoot,
                UseShellExecute = true
            });
            StatusTextBlock.Text = "Папка движков открыта";
        }
        catch (Exception ex)
        {
            StatusTextBlock.Text = "Не удалось открыть папку";
            AppendLog(ex.Message);
        }
    }

    private void EngineCatalogListView_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        UseEngineButton.IsEnabled = !_isBusy && EngineCatalogListView.SelectedItem is EngineCatalogEntry;
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

    private async void CheckReadinessButton_Click(object sender, RoutedEventArgs e)
    {
        await RunUiActionAsync(async () =>
        {
            var report = await RefreshReleaseReadinessAsync(isAutomatic: false);
            AppendLog(report.Details);
            StatusTextBlock.Text = report.Summary;
        }, "Проверка среды...");
    }

    private async void RepairReadinessButton_Click(object sender, RoutedEventArgs e)
    {
        await RunUiActionAsync(async () =>
        {
            var result = await _releaseReadinessService.RepairAsync();
            StatusTextBlock.Text = result.Summary;
            AppendLog(string.Join(Environment.NewLine, result.Details));
            await RefreshDailyServiceStateAsync();
            await RefreshReleaseReadinessAsync(isAutomatic: false);
        }, "Быстрый ремонт...");
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
            foreach (var source in sources.Where(item => item.IsEnabled).OrderBy(item => item.Name))
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

            var refreshedCount = sources.Count(item => item.IsEnabled);
            var status = $"Источников обновлено: {refreshedCount}; профили: +{added}, обновлено {updated}";
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

    private async void FirstRunPasteButton_Click(object sender, RoutedEventArgs e)
    {
        await RunUiActionAsync(async () =>
        {
            if (!TryGetSubscriptionUrlFromClipboard(out var url))
            {
                StatusTextBlock.Text = "В буфере нет ссылки подключения";
                return;
            }

            SubscriptionUrlTextBox.Text = url;
            var refreshResult = await RefreshSubscriptionUrlAsync(url, selectImportedProfile: true);
            _appSettings.FirstRunDismissed = true;
            await SaveAppSettingsQuietlyAsync();
            UpdateFirstRunPanel();
            StatusTextBlock.Text = refreshResult.Added + refreshResult.Updated > 0
                ? "Подписка импортирована"
                : "Подписка проверена";
        }, "Быстрый старт...");
    }

    private async void DismissFirstRunButton_Click(object sender, RoutedEventArgs e)
    {
        _appSettings.FirstRunDismissed = true;
        await SaveAppSettingsQuietlyAsync();
        UpdateFirstRunPanel();
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
            UpdateSubscriptionEditor(null);
            RenderServerChoices(null);
            StatusTextBlock.Text = "Источник удален";
            SubscriptionStatusTextBlock.Text = "Источник удален. Импортированные профили не удалялись.";
        }, "Удаление источника...");
    }

    private async void RenameSubscriptionButton_Click(object sender, RoutedEventArgs e)
    {
        if (SubscriptionSourcesListBox.SelectedItem is not SubscriptionSourceListItem selected)
        {
            StatusTextBlock.Text = "Выберите источник";
            return;
        }

        await RunUiActionAsync(async () =>
        {
            var sources = (await _subscriptionStore.LoadAsync()).ToList();
            var source = sources.FirstOrDefault(item => item.Id == selected.Source.Id);
            if (source is null)
            {
                StatusTextBlock.Text = "Источник не найден";
                return;
            }

            source.Name = string.IsNullOrWhiteSpace(SubscriptionNameTextBox.Text)
                ? "Samhain Security"
                : SubscriptionNameTextBox.Text.Trim();
            source.UpdatedAt = DateTimeOffset.UtcNow;
            await _subscriptionStore.SaveAsync(sources);
            RenderSubscriptionSources(sources, SubscriptionUrlNormalizer.Normalize(selected.Url));
            StatusTextBlock.Text = "Источник переименован";
        }, "Переименование...");
    }

    private async void ToggleSubscriptionButton_Click(object sender, RoutedEventArgs e)
    {
        if (SubscriptionSourcesListBox.SelectedItem is not SubscriptionSourceListItem selected)
        {
            StatusTextBlock.Text = "Выберите источник";
            return;
        }

        await RunUiActionAsync(async () =>
        {
            var sources = (await _subscriptionStore.LoadAsync()).ToList();
            var source = sources.FirstOrDefault(item => item.Id == selected.Source.Id);
            if (source is null)
            {
                StatusTextBlock.Text = "Источник не найден";
                return;
            }

            source.IsEnabled = !source.IsEnabled;
            source.UpdatedAt = DateTimeOffset.UtcNow;
            await _subscriptionStore.SaveAsync(sources);
            RenderSubscriptionSources(sources, SubscriptionUrlNormalizer.Normalize(selected.Url));
            StatusTextBlock.Text = source.IsEnabled ? "Источник включен" : "Источник выключен";
        }, "Настройка источника...");
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
        UpdateFirstRunPanel();

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
            LastLatencyMs = oldProfile?.LastLatencyMs,
            LastProbeStatus = oldProfile?.LastProbeStatus ?? string.Empty,
            LastProbedAt = oldProfile?.LastProbedAt,
            LastWatchdogCheckedAt = oldProfile?.LastWatchdogCheckedAt,
            WatchdogFailureCount = oldProfile?.WatchdogFailureCount ?? 0,
            LastWatchdogMessage = oldProfile?.LastWatchdogMessage ?? string.Empty,
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
        _ = RefreshEngineCatalogAsync(showStatus: false);
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
        _ = RefreshEngineCatalogAsync(showStatus: false);
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

    private async Task RefreshEngineCatalogAsync(bool showStatus)
    {
        var protocol = ProtocolComboBox.SelectedValue is VpnProtocolType selectedProtocol
            ? selectedProtocol
            : VpnProtocolType.WindowsNative;
        var entries = await _engineCatalogService.BuildCatalogAsync(protocol, EnginePathTextBox.Text);
        var selectedProtocolBeforeRefresh = (EngineCatalogListView.SelectedItem as EngineCatalogEntry)?.Protocol;

        _engineCatalog.Clear();
        foreach (var entry in entries)
        {
            _engineCatalog.Add(entry);
        }

        var selected = selectedProtocolBeforeRefresh is not null
            ? _engineCatalog.FirstOrDefault(entry => entry.Protocol == selectedProtocolBeforeRefresh)
            : _engineCatalog.FirstOrDefault(entry => entry.Protocol == protocol);
        EngineCatalogListView.SelectedItem = selected ?? _engineCatalog.FirstOrDefault();

        var readyCount = _engineCatalog.Count(entry => entry.IsAvailable);
        EngineManagerStatusTextBlock.Text = $"Готово: {readyCount}/{_engineCatalog.Count}; portable: {_engineCatalogService.PortableEngineRoot}";
        UseEngineButton.IsEnabled = !_isBusy && EngineCatalogListView.SelectedItem is EngineCatalogEntry;

        if (showStatus)
        {
            StatusTextBlock.Text = EngineManagerStatusTextBlock.Text;
        }
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
        ReadinessSummaryTextBlock.Text = _releaseReadinessState;
        HealthSummaryTextBlock.Text = BuildHealthSummary(profile ?? ProfilesListBox.SelectedItem as VpnProfile);
        if (ConnectionProgressBar.Visibility != Visibility.Visible)
        {
            ConnectionDetailTextBlock.Text = hasProfile
                ? BuildDailyRouteText(snapshot)
                : "Добавьте подписку или выберите профиль";
        }

        ApplyDailyConnectionBrush(_dailyConnectionState);
    }

    private static string BuildHealthSummary(VpnProfile? profile)
    {
        if (profile is null)
        {
            return "Здоровье: нет данных";
        }

        var checkedAt = profile.LastWatchdogCheckedAt is null
            ? "надзор еще не проверял"
            : $"надзор {profile.LastWatchdogCheckedAt.Value.ToLocalTime():HH:mm}";
        var latency = profile.LastLatencyMs is null
            ? "задержка неизвестна"
            : $"{profile.LastLatencyMs} мс";
        var failures = profile.WatchdogFailureCount == 0
            ? "сбоев нет"
            : $"сбоев: {profile.WatchdogFailureCount}";
        var message = string.IsNullOrWhiteSpace(profile.LastWatchdogMessage)
            ? string.Empty
            : $"; {profile.LastWatchdogMessage}";

        return $"Здоровье: {checkedAt}; {latency}; {failures}{message}";
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
        var failover = _appSettings.AutoFailoverOnConnectFailure ? "резерв" : "без резерва";
        var best = _appSettings.ConnectBestServerAutomatically ? "лучший" : "выбранный";
        var watchdog = _appSettings.EnableConnectionWatchdog ? "надзор" : "без надзора";

        return $"{startup}; {reconnect}; {recovery}; {failover}; {best}; {watchdog}";
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

    private static bool IsConnectedState(string state)
    {
        return state.Contains("Подключено", StringComparison.OrdinalIgnoreCase)
            || state.Contains("Статус получен", StringComparison.OrdinalIgnoreCase);
    }

    private async Task RefreshDailyServiceStateAsync()
    {
        SetDailyServiceState("Служба: проверка");
        var isAvailable = await _serviceClient.IsAvailableAsync();
        SetDailyServiceState(isAvailable ? "Служба: готова" : "Служба: не запущена");
    }

    private async Task<ReleaseReadinessReport> RefreshReleaseReadinessAsync(bool isAutomatic)
    {
        try
        {
            var protocol = ProtocolComboBox.SelectedValue is VpnProtocolType selectedProtocol
                ? selectedProtocol
                : VpnProtocolType.WindowsNative;
            var report = await _releaseReadinessService.CheckAsync(protocol, EnginePathTextBox.Text);
            _releaseReadinessState = report.Summary;
            ReadinessSummaryTextBlock.Text = report.Summary;
            ReadinessSummaryTextBlock.Foreground = (System.Windows.Media.Brush)FindResource(
                report.IsReady ? "SuccessTextBrush" : "WarningTextBrush");

            if (!isAutomatic)
            {
                ConnectionDetailTextBlock.Text = report.Summary;
            }

            return report;
        }
        catch (Exception ex)
        {
            _releaseReadinessState = "Среда: проверка не удалась";
            ReadinessSummaryTextBlock.Text = _releaseReadinessState;
            ReadinessSummaryTextBlock.Foreground = (System.Windows.Media.Brush)FindResource("ErrorTextBrush");
            if (!isAutomatic)
            {
                AppendLog($"Среда: {ex.Message}");
            }

            return new ReleaseReadinessReport(
                false,
                _releaseReadinessState,
                [new ReleaseReadinessItem("Проверка", false, ex.Message)]);
        }
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
            AutoFailoverCheckBox.IsChecked = _appSettings.AutoFailoverOnConnectFailure;
            AutoBestServerCheckBox.IsChecked = _appSettings.ConnectBestServerAutomatically;
            AutoRefreshSubscriptionsCheckBox.IsChecked = _appSettings.AutoRefreshSubscriptions;
            ConnectionWatchdogCheckBox.IsChecked = _appSettings.EnableConnectionWatchdog;
            AdvancedSettingsExpander.IsExpanded = _appSettings.AdvancedSettingsExpanded;
            ServerSearchTextBox.Clear();
            FavoriteServersOnlyCheckBox.IsChecked = _appSettings.ServerCatalogFavoritesOnly;
            SelectServerSortMode(NormalizeServerSortMode(_appSettings.ServerCatalogSortMode));
        }
        finally
        {
            _isLoadingAppSettings = false;
        }

        RefreshServerCatalogView();
    }

    private async Task AutoConnectLastProfileIfRequestedAsync()
    {
        if (!_appSettings.AutoConnectLastProfile)
        {
            return;
        }

        var profile = ResolveAutomaticConnectionProfile();
        if (profile is null)
        {
            return;
        }

        ProfilesListBox.SelectedItem = profile;
        LoadProfileIntoEditor(profile);
        await RunUiActionAsync(async () =>
        {
            var connection = await ConnectWithFailoverAsync(
                profile,
                _protector.Unprotect(profile.EncryptedPassword),
                _protector.Unprotect(profile.EncryptedTunnelConfig),
                "autoconnect");
            var connectResult = connection.Result;
            var connectedProfile = connection.Profile;

            StatusTextBlock.Text = connectResult.IsSuccess
                ? connection.UsedFailover
                    ? $"Подключено через резерв: {connectedProfile.Name}"
                    : "Подключено"
                : FriendlyErrorService.ToUserMessage(connectResult);
            if (connectResult.IsSuccess)
            {
                _appSettings.LastProfileId = connectedProfile.Id;
                await _profileStore.SaveAsync(_profiles);
                await SaveAppSettingsQuietlyAsync();
                RenderServerChoices(SubscriptionSelectorComboBox.SelectedItem as SubscriptionSourceListItem, connectedProfile.Id);
                StartConnectionWatchdog(connectedProfile);
            }
            else
            {
                await _profileStore.SaveAsync(_profiles);
                RenderServerChoices(SubscriptionSelectorComboBox.SelectedItem as SubscriptionSourceListItem, profile.Id);
                StopConnectionWatchdog();
            }

            UpdateDailyStatusPanel(connectedProfile, connectResult.IsSuccess ? "Подключено" : "Автоподключение не удалось");
        }, "Автоподключение...");
    }

    private VpnProfile? ResolveAutomaticConnectionProfile()
    {
        if (_appSettings.ConnectBestServerAutomatically && GetBestServerChoice() is { } best)
        {
            return best.Profile;
        }

        return string.IsNullOrWhiteSpace(_appSettings.LastProfileId)
            ? _profiles.FirstOrDefault()
            : _profiles.FirstOrDefault(item => item.Id == _appSettings.LastProfileId);
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
        RenameSubscriptionButton.IsEnabled = !isBusy && SubscriptionSourcesListBox.SelectedItem is SubscriptionSourceListItem;
        ToggleSubscriptionButton.IsEnabled = !isBusy && SubscriptionSourcesListBox.SelectedItem is SubscriptionSourceListItem;
        SubscriptionSelectorComboBox.IsEnabled = !isBusy;
        ServerSelectorComboBox.IsEnabled = !isBusy;
        ServerSearchTextBox.IsEnabled = !isBusy;
        FavoriteServersOnlyCheckBox.IsEnabled = !isBusy;
        ServerSortComboBox.IsEnabled = !isBusy;
        ClearServerFiltersButton.IsEnabled = !isBusy && HasActiveServerCatalogFilter();
        UpdateServerRecommendations();
        ServersListView.IsEnabled = !isBusy;
        FavoriteServerButton.IsEnabled = !isBusy;
        BestServerButton.IsEnabled = !isBusy;
        ProbeServersButton.IsEnabled = !isBusy;
        ResetServerHealthButton.IsEnabled = !isBusy && _serverChoices.Count > 0;
        CheckEnginesButton.IsEnabled = !isBusy;
        OpenEnginesFolderButton.IsEnabled = !isBusy;
        EngineCatalogListView.IsEnabled = !isBusy;
        UseEngineButton.IsEnabled = !isBusy && EngineCatalogListView.SelectedItem is EngineCatalogEntry;
        DiagnosticsButton.IsEnabled = !isBusy;
        ExportDiagnosticsButton.IsEnabled = !isBusy;
        CheckReadinessButton.IsEnabled = !isBusy;
        RepairReadinessButton.IsEnabled = !isBusy;
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
        if (!result.IsSuccess)
        {
            AppendLog(FriendlyErrorService.ToUserMessage(result));
        }

        if (!string.IsNullOrWhiteSpace(result.CombinedOutput))
        {
            AppendLog(result.CombinedOutput);
        }
    }

    private void AppendLog(string message)
    {
        var redactedMessage = SecretRedactor.Redact(message);
        LogTextBox.AppendText($"[{DateTime.Now:HH:mm:ss}] {redactedMessage}{Environment.NewLine}");
        LogTextBox.ScrollToEnd();
        TryWriteInfoLog("ui.log", redactedMessage);
    }

    private async Task RecordConnectionHistoryAsync(
        VpnProfile profile,
        string action,
        CommandResult result,
        CancellationToken cancellationToken = default)
    {
        var server = string.IsNullOrWhiteSpace(profile.ServerAddress)
            ? "маршрут из конфигурации"
            : profile.ServerPort > 0
                ? $"{profile.ServerAddress}:{profile.ServerPort}"
                : profile.ServerAddress;

        await _connectionHistoryStore.AppendAsync(
            new ConnectionHistoryEntry
            {
                Action = action,
                ProfileId = profile.Id,
                ProfileName = profile.Name,
                Protocol = profile.Protocol,
                Server = server,
                Success = result.IsSuccess,
                Message = result.IsSuccess ? "OK" : FriendlyErrorService.ToUserMessage(result)
            },
            cancellationToken);
        await RefreshHistorySummaryAsync(cancellationToken);
    }

    private async Task RefreshHistorySummaryAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            var last = (await _connectionHistoryStore.LoadAsync(cancellationToken)).FirstOrDefault();
            HistorySummaryTextBlock.Text = last is null
                ? "История: пока пусто"
                : $"История: {last.Timestamp.ToLocalTime():dd.MM HH:mm}; {FormatHistoryAction(last.Action)}; {last.ProfileName}; {(last.Success ? "успешно" : "ошибка")}";
        }
        catch
        {
            HistorySummaryTextBlock.Text = "История: недоступна";
        }
    }

    private static string FormatHistoryAction(string action)
    {
        if (action.Contains("connect", StringComparison.OrdinalIgnoreCase))
        {
            return "подключение";
        }

        if (action.Contains("disconnect", StringComparison.OrdinalIgnoreCase))
        {
            return "отключение";
        }

        if (action.Contains("status", StringComparison.OrdinalIgnoreCase))
        {
            return "статус";
        }

        return action;
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

    private void UpdateSubscriptionEditor(SubscriptionSourceListItem? item)
    {
        if (item is null)
        {
            SubscriptionNameTextBox.Text = string.Empty;
            ToggleSubscriptionButton.Content = "Выключить";
            RenameSubscriptionButton.IsEnabled = !_isBusy && false;
            ToggleSubscriptionButton.IsEnabled = !_isBusy && false;
            return;
        }

        SubscriptionNameTextBox.Text = item.DisplayName;
        ToggleSubscriptionButton.Content = item.Source.IsEnabled ? "Выключить" : "Включить";
        RenameSubscriptionButton.IsEnabled = !_isBusy;
        ToggleSubscriptionButton.IsEnabled = !_isBusy;
    }

    private void UpdateFirstRunPanel()
    {
        FirstRunPanel.Visibility = !_appSettings.FirstRunDismissed
            && _profiles.Count == 0
            && _subscriptionSources.Count == 0
                ? Visibility.Visible
                : Visibility.Collapsed;
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
                UpdateSubscriptionEditor(null);
                RenderServerChoices(null);
                return;
            }

            SubscriptionUrlTextBox.Text = selected.Url;
            UpdateSubscriptionEditor(selected);
            SubscriptionStatusTextBlock.Text = _subscriptionSources.Count > 1
                ? $"Источников: {_subscriptionSources.Count}. {selected.DisplayStatus}"
                : selected.DisplayStatus;
            RenderServerChoices(selected);
        }
        finally
        {
            _isLoadingSubscriptions = false;
        }

        UpdateFirstRunPanel();
    }

    private void RenderServerChoices(SubscriptionSourceListItem? source, string? preferredProfileId = null)
    {
        _isLoadingServerChoices = true;
        try
        {
            _serverChoices.Clear();

            var profiles = OrderServerProfiles(GetProfilesForSubscription(source), GetServerSortMode())
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
            ServersListView.SelectedItem = selected;
            RefreshServerCatalogView();
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
            RefreshTrayMenu();
        }
    }

    private bool FilterServerChoice(object item)
    {
        if (item is not ServerListItem server)
        {
            return false;
        }

        if (FavoriteServersOnlyCheckBox.IsChecked == true && !server.Profile.IsFavorite)
        {
            return false;
        }

        var query = ServerSearchTextBox.Text.Trim();
        if (string.IsNullOrWhiteSpace(query))
        {
            return true;
        }

        var terms = query.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        return terms.All(term => server.SearchText.Contains(term, StringComparison.CurrentCultureIgnoreCase));
    }

    private void RefreshServerCatalogView()
    {
        _serverChoicesView?.Refresh();
        UpdateServerCatalogSummary();
        UpdateServerRecommendations();
        UpdateFavoriteServerButton();
    }

    private void UpdateServerCatalogSummary()
    {
        if (_serverChoicesView is null)
        {
            ServerCatalogSummaryTextBlock.Text = "Серверов: 0";
            ClearServerFiltersButton.IsEnabled = !_isBusy && HasActiveServerCatalogFilter();
            return;
        }

        var visibleCount = GetVisibleServerChoices().Count();
        var totalCount = _serverChoices.Count;
        var favoriteCount = _serverChoices.Count(item => item.Profile.IsFavorite);
        var summary = visibleCount == totalCount
            ? $"Серверов: {totalCount}; избранных: {favoriteCount}"
            : $"Показано: {visibleCount} из {totalCount}; избранных: {favoriteCount}";
        var filterLabel = BuildServerCatalogFilterLabel();

        ServerCatalogSummaryTextBlock.Text = string.IsNullOrWhiteSpace(filterLabel)
            ? summary
            : $"{summary}; {filterLabel}";
        ClearServerFiltersButton.IsEnabled = !_isBusy && HasActiveServerCatalogFilter();
    }

    private IEnumerable<ServerListItem> GetVisibleServerChoices()
    {
        return _serverChoicesView is null
            ? _serverChoices
            : _serverChoicesView.Cast<ServerListItem>();
    }

    private IEnumerable<ServerListItem> GetServerRecommendationCandidates(bool visibleOnly)
    {
        return visibleOnly ? GetVisibleServerChoices() : _serverChoices;
    }

    private void UpdateServerRecommendations()
    {
        var best = GetBestServerChoice(visibleOnly: true);
        var favorite = GetFavoriteServerChoice(visibleOnly: true);
        var recent = GetRecentServerChoice(visibleOnly: true);

        SetRecommendation(
            RecommendedServerButton,
            RecommendedServerNameTextBlock,
            RecommendedServerDetailTextBlock,
            RecommendedServerReasonTextBlock,
            best,
            _serverChoices.Count == 0 ? "Обновите подписку" : "Нет совпадений");
        SetRecommendation(
            FavoriteRecommendationButton,
            FavoriteRecommendationNameTextBlock,
            FavoriteRecommendationDetailTextBlock,
            FavoriteRecommendationReasonTextBlock,
            favorite,
            _serverChoices.Any(item => item.Profile.IsFavorite) ? "Скрыт фильтром" : "Отметьте сервер");
        SetRecommendation(
            RecentServerButton,
            RecentServerNameTextBlock,
            RecentServerDetailTextBlock,
            RecentServerReasonTextBlock,
            recent,
            _serverChoices.Any(item => item.Profile.LastConnectedAt is not null) ? "Скрыт фильтром" : "После успешного подключения");
    }

    private void SetRecommendation(
        System.Windows.Controls.Button button,
        TextBlock nameTextBlock,
        TextBlock detailTextBlock,
        TextBlock reasonTextBlock,
        ServerListItem? item,
        string emptyDetail)
    {
        button.IsEnabled = !_isBusy && item is not null;

        if (item is null)
        {
            nameTextBlock.Text = "Нет сервера";
            detailTextBlock.Text = emptyDetail;
            reasonTextBlock.Text = "Нет данных";
            button.ToolTip = emptyDetail;
            return;
        }

        var reason = BuildRecommendationReason(item.Profile);
        nameTextBlock.Text = item.DisplayName;
        detailTextBlock.Text = item.Details;
        reasonTextBlock.Text = reason;
        button.ToolTip = $"{item.DisplayName}{Environment.NewLine}{item.Details}{Environment.NewLine}{reason}";
    }

    private static string BuildRecommendationReason(VpnProfile profile)
    {
        var markers = new List<string>();

        if (profile.WatchdogFailureCount > 0)
        {
            markers.Add($"сбоев {profile.WatchdogFailureCount}");
        }

        var probeStatus = profile.LastProbeStatus switch
        {
            ServerProbeStatus.Connected => "активен",
            ServerProbeStatus.TcpOk => "доступен",
            ServerProbeStatus.EndpointResolved => "адрес найден",
            ServerProbeStatus.Failed => "нет ответа",
            ServerProbeStatus.Skipped => "нет адреса",
            _ => string.Empty
        };

        if (!string.IsNullOrWhiteSpace(probeStatus))
        {
            markers.Add(probeStatus);
        }

        if (profile.LastLatencyMs is >= 0)
        {
            markers.Add($"{profile.LastLatencyMs} мс");
        }

        if (profile.LastProbedAt is not null)
        {
            markers.Add($"проверен {profile.LastProbedAt.Value.ToLocalTime():HH:mm}");
        }

        if (profile.IsFavorite)
        {
            markers.Add("избранный");
        }

        if (profile.LastConnectedAt is not null)
        {
            markers.Add($"последний {profile.LastConnectedAt.Value.ToLocalTime():HH:mm}");
        }

        return markers.Count == 0
            ? "ожидает проверки"
            : string.Join(" · ", markers);
    }

    private string GetServerSortMode()
    {
        return (ServerSortComboBox.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "smart";
    }

    private static string NormalizeServerSortMode(string? sortMode)
    {
        if (string.IsNullOrWhiteSpace(sortMode))
        {
            return "smart";
        }

        var normalized = sortMode.Trim().ToLowerInvariant();
        return normalized is "latency" or "favorite" or "recent" or "name"
            ? normalized
            : "smart";
    }

    private string GetServerSortLabel()
    {
        return (ServerSortComboBox.SelectedItem as ComboBoxItem)?.Content?.ToString() ?? "Умная";
    }

    private void SelectServerSortMode(string sortMode)
    {
        foreach (var item in ServerSortComboBox.Items.OfType<ComboBoxItem>())
        {
            if (string.Equals(item.Tag?.ToString(), sortMode, StringComparison.OrdinalIgnoreCase))
            {
                ServerSortComboBox.SelectedItem = item;
                return;
            }
        }
    }

    private bool HasActiveServerCatalogFilter()
    {
        return !string.IsNullOrWhiteSpace(ServerSearchTextBox.Text)
            || FavoriteServersOnlyCheckBox.IsChecked == true
            || !string.Equals(GetServerSortMode(), "smart", StringComparison.OrdinalIgnoreCase);
    }

    private string BuildServerCatalogFilterLabel()
    {
        var filters = new List<string>();
        var query = ServerSearchTextBox.Text.Trim();
        if (!string.IsNullOrWhiteSpace(query))
        {
            filters.Add($"поиск: {query}");
        }

        if (FavoriteServersOnlyCheckBox.IsChecked == true)
        {
            filters.Add("только избранные");
        }

        if (!string.Equals(GetServerSortMode(), "smart", StringComparison.OrdinalIgnoreCase))
        {
            filters.Add($"сортировка: {GetServerSortLabel()}");
        }

        return filters.Count == 0
            ? string.Empty
            : $"фильтры: {string.Join(", ", filters)}";
    }

    private static IOrderedEnumerable<VpnProfile> OrderServerProfiles(IEnumerable<VpnProfile> profiles, string sortMode)
    {
        return sortMode switch
        {
            "latency" => profiles
                .OrderBy(profile => GetServerSortKey(profile).ProbeBucket)
                .ThenBy(profile => GetServerSortKey(profile).LatencyMs)
                .ThenByDescending(profile => profile.IsFavorite)
                .ThenByDescending(profile => profile.LastConnectedAt ?? DateTimeOffset.MinValue)
                .ThenBy(profile => GetProfileSortName(profile), StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(profile => profile.ServerAddress),
            "favorite" => profiles
                .OrderByDescending(profile => profile.IsFavorite)
                .ThenBy(profile => GetServerSortKey(profile).ProbeBucket)
                .ThenBy(profile => GetServerSortKey(profile).LatencyMs)
                .ThenByDescending(profile => profile.LastConnectedAt ?? DateTimeOffset.MinValue)
                .ThenBy(profile => GetProfileSortName(profile), StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(profile => profile.ServerAddress),
            "recent" => profiles
                .OrderByDescending(profile => profile.LastConnectedAt ?? DateTimeOffset.MinValue)
                .ThenBy(profile => GetServerSortKey(profile).ProbeBucket)
                .ThenByDescending(profile => profile.IsFavorite)
                .ThenBy(profile => GetServerSortKey(profile).LatencyMs)
                .ThenBy(profile => GetProfileSortName(profile), StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(profile => profile.ServerAddress),
            "name" => profiles
                .OrderBy(profile => GetProfileSortName(profile), StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(profile => profile.ServerAddress)
                .ThenBy(profile => profile.ServerPort),
            _ => profiles
                .OrderBy(profile => GetServerSortKey(profile).ProbeBucket)
                .ThenByDescending(profile => profile.IsFavorite)
                .ThenBy(profile => GetServerSortKey(profile).LatencyMs)
                .ThenByDescending(profile => profile.LastConnectedAt ?? DateTimeOffset.MinValue)
                .ThenBy(profile => GetProfileSortName(profile), StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(profile => profile.ServerAddress)
        };
    }

    private static string GetProfileSortName(VpnProfile profile)
    {
        return string.IsNullOrWhiteSpace(profile.Name)
            ? profile.ServerAddress
            : profile.Name;
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
            FavoriteServerButton.IsEnabled = !_isBusy && GetVisibleServerChoices().Any();
            return;
        }

        FavoriteServerButton.Content = item.Profile.IsFavorite ? "Убрать" : "Избранное";
        FavoriteServerButton.IsEnabled = !_isBusy;
        RefreshTrayMenu();
    }

    private ServerListItem? GetBestServerChoice(bool visibleOnly = false)
    {
        var candidates = GetServerRecommendationCandidates(visibleOnly).ToList();
        var bestProfile = OrderServerProfiles(candidates.Select(item => item.Profile), "smart")
            .FirstOrDefault();

        return bestProfile is null
            ? null
            : candidates.FirstOrDefault(item => item.Profile.Id == bestProfile.Id);
    }

    private ServerListItem? GetFavoriteServerChoice(bool visibleOnly = false)
    {
        var candidates = GetServerRecommendationCandidates(visibleOnly).ToList();
        var favoriteProfile = OrderServerProfiles(
                candidates
                    .Where(item => item.Profile.IsFavorite)
                    .Select(item => item.Profile),
                "smart")
            .FirstOrDefault();

        return favoriteProfile is null
            ? null
            : candidates.FirstOrDefault(item => item.Profile.Id == favoriteProfile.Id);
    }

    private ServerListItem? GetRecentServerChoice(bool visibleOnly = false)
    {
        return GetServerRecommendationCandidates(visibleOnly)
            .Where(item => item.Profile.LastConnectedAt is not null)
            .OrderByDescending(item => item.Profile.LastConnectedAt ?? DateTimeOffset.MinValue)
            .ThenBy(item => GetServerSortKey(item.Profile).ProbeBucket)
            .ThenBy(item => GetServerSortKey(item.Profile).LatencyMs)
            .ThenBy(item => item.DisplayName, StringComparer.CurrentCultureIgnoreCase)
            .FirstOrDefault();
    }

    private static ServerSortKey GetServerSortKey(VpnProfile profile)
    {
        var hasFreshProbe = profile.LastProbedAt is not null
            && DateTimeOffset.UtcNow - profile.LastProbedAt.Value < TimeSpan.FromHours(6);
        var isAvailable = hasFreshProbe
            && profile.LastProbeStatus is ServerProbeStatus.Connected or ServerProbeStatus.TcpOk or ServerProbeStatus.EndpointResolved
            && profile.LastLatencyMs is not null;
        var isFailed = hasFreshProbe
            && profile.LastProbeStatus is ServerProbeStatus.Failed or ServerProbeStatus.Skipped;

        return new ServerSortKey(
            isAvailable ? 0 : isFailed ? 2 : 1,
            isAvailable ? profile.LastLatencyMs.GetValueOrDefault() : int.MaxValue);
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

        UpdateFirstRunPanel();
        _ = ProbeServerChoicesInBackgroundAsync("проверка после обновления");

        return new SubscriptionRefreshResult(mergeResult.Added, mergeResult.Updated);
    }

    private async Task ProbeServerChoicesInBackgroundAsync(string reason)
    {
        if (_isBackgroundProbeRunning || _serverChoices.Count == 0)
        {
            return;
        }

        _isBackgroundProbeRunning = true;
        var selectedProfileId = (ServerSelectorComboBox.SelectedItem as ServerListItem)?.Profile.Id;
        var source = SubscriptionSelectorComboBox.SelectedItem as SubscriptionSourceListItem;
        var targets = _serverChoices
            .Select(item => item.Profile)
            .Take(24)
            .ToList();

        try
        {
            var completed = 0;
            var available = 0;
            using var throttler = new SemaphoreSlim(MaxConcurrentServerProbes);

            var tasks = targets.Select(async profile =>
            {
                await throttler.WaitAsync();
                try
                {
                    var tunnelConfig = profile.Protocol is VpnProtocolType.WireGuard or VpnProtocolType.AmneziaWireGuard
                        ? _protector.Unprotect(profile.EncryptedTunnelConfig)
                        : string.Empty;
                    var result = await _serverProbeService.ProbeAsync(profile, tunnelConfig);
                    profile.LastLatencyMs = result.LatencyMs;
                    profile.LastProbeStatus = result.Status;
                    profile.LastProbedAt = DateTimeOffset.UtcNow;
                    profile.UpdatedAt = DateTimeOffset.UtcNow;
                    if (result.IsSuccess)
                    {
                        Interlocked.Increment(ref available);
                    }
                }
                finally
                {
                    Interlocked.Increment(ref completed);
                    throttler.Release();
                }
            });

            await Task.WhenAll(tasks);
            await _profileStore.SaveAsync(_profiles);
            await Dispatcher.InvokeAsync(() =>
            {
                RenderServerChoices(source, selectedProfileId);
                SubscriptionStatusTextBlock.Text = $"{reason}: {completed}; доступны: {available}";
            });
        }
        catch (Exception ex)
        {
            await Dispatcher.InvokeAsync(() => AppendLog($"Фоновая проверка: {ex.Message}"));
        }
        finally
        {
            _isBackgroundProbeRunning = false;
        }
    }

    private async Task RefreshDueSubscriptionsQuietlyAsync()
    {
        if (!_appSettings.AutoRefreshSubscriptions || _isRefreshingSubscriptionsQuietly)
        {
            return;
        }

        _isRefreshingSubscriptionsQuietly = true;
        try
        {
            var sources = (await _subscriptionStore.LoadAsync()).Where(source => source.IsEnabled).ToList();
            var refreshInterval = TimeSpan.FromHours(Math.Clamp(_appSettings.SubscriptionRefreshIntervalHours, 1, 168));
            var dueSources = sources
                .Where(source => source.LastUpdatedAt is null
                    || DateTimeOffset.UtcNow - source.LastUpdatedAt.Value > refreshInterval)
                .ToList();

            if (dueSources.Count == 0)
            {
                return;
            }

            var added = 0;
            var updated = 0;
            var failed = 0;
            foreach (var source in dueSources)
            {
                var url = _subscriptionStore.UnprotectUrl(source);
                if (string.IsNullOrWhiteSpace(url))
                {
                    continue;
                }

                try
                {
                    var result = await RefreshSubscriptionUrlAsync(url, selectImportedProfile: false);
                    added += result.Added;
                    updated += result.Updated;
                }
                catch (Exception ex)
                {
                    failed++;
                    source.LastStatus = "Автообновление не удалось";
                    source.UpdatedAt = DateTimeOffset.UtcNow;
                    AppendLog($"Автообновление источника: {ex.Message}");
                }
            }

            if (failed > 0)
            {
                await _subscriptionStore.SaveAsync(sources);
                await Dispatcher.InvokeAsync(() => RenderSubscriptionSources(sources));
            }

            await Dispatcher.InvokeAsync(() =>
            {
                SubscriptionStatusTextBlock.Text = failed == 0
                    ? $"Автообновление: источников {dueSources.Count}; +{added}, обновлено {updated}"
                    : $"Автообновление: источников {dueSources.Count}; +{added}, обновлено {updated}; ошибок {failed}";
            });
        }
        catch (Exception ex)
        {
            await Dispatcher.InvokeAsync(() => AppendLog($"Автообновление подписок: {ex.Message}"));
        }
        finally
        {
            _isRefreshingSubscriptionsQuietly = false;
        }
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
        target.LastLatencyMs = existing.LastLatencyMs;
        target.LastProbeStatus = existing.LastProbeStatus ?? string.Empty;
        target.LastProbedAt = existing.LastProbedAt;
        target.LastWatchdogCheckedAt = existing.LastWatchdogCheckedAt;
        target.WatchdogFailureCount = existing.WatchdogFailureCount;
        target.LastWatchdogMessage = existing.LastWatchdogMessage ?? string.Empty;
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

    private void InitializeConnectionWatchdog()
    {
        _connectionWatchdogTimer.Tick += ConnectionWatchdogTimer_Tick;
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

    private void StartConnectionWatchdog(VpnProfile profile)
    {
        if (!_appSettings.EnableConnectionWatchdog)
        {
            return;
        }

        _watchdogProfileId = profile.Id;
        _connectionWatchdogTimer.Start();
        ConnectionDetailTextBlock.Text = $"Надзор активен: {profile.Name}";
    }

    private void StopConnectionWatchdog()
    {
        _connectionWatchdogTimer.Stop();
        _watchdogProfileId = string.Empty;
        _isWatchdogChecking = false;
    }

    private async void ConnectionWatchdogTimer_Tick(object? sender, EventArgs e)
    {
        if (!_appSettings.EnableConnectionWatchdog
            || _isBusy
            || _isWatchdogChecking
            || string.IsNullOrWhiteSpace(_watchdogProfileId))
        {
            return;
        }

        var profile = _profiles.FirstOrDefault(item => item.Id == _watchdogProfileId);
        if (profile is null)
        {
            StopConnectionWatchdog();
            return;
        }

        _isWatchdogChecking = true;
        try
        {
            var statusResult = await _vpnService.GetStatusAsync(profile);
            _structuredLogService.WriteCommand("watchdog.status", profile, statusResult);
            var state = BuildDailyConnectionStatus(statusResult);

            if (statusResult.IsSuccess && state != "Отключено")
            {
                profile.LastWatchdogCheckedAt = DateTimeOffset.UtcNow;
                profile.WatchdogFailureCount = 0;
                profile.LastWatchdogMessage = "Надзор: маршрут работает";
                profile.UpdatedAt = DateTimeOffset.UtcNow;
                await _profileStore.SaveAsync(_profiles);
                UpdateDailyStatusPanel(profile, "Подключено");
                ConnectionDetailTextBlock.Text = $"Надзор: проверено {DateTime.Now:HH:mm}";
                return;
            }

            MarkProfileConnectFailed(profile);
            profile.LastWatchdogCheckedAt = DateTimeOffset.UtcNow;
            profile.LastWatchdogMessage = FriendlyErrorService.ToUserMessage(statusResult);
            await _profileStore.SaveAsync(_profiles);
            if (DateTimeOffset.UtcNow - _lastWatchdogRecoveryAt < TimeSpan.FromMinutes(2))
            {
                UpdateDailyStatusPanel(profile, "Ошибка подключения");
                ConnectionDetailTextBlock.Text = FriendlyErrorService.ToUserMessage(statusResult);
                return;
            }

            _lastWatchdogRecoveryAt = DateTimeOffset.UtcNow;
            AppendLog("Надзор: маршрут требует восстановления");
            await TryReconnectLastProfileAsync("надзор подключения");
        }
        catch (Exception ex)
        {
            AppendLog($"Надзор: {ex.Message}");
        }
        finally
        {
            _isWatchdogChecking = false;
        }
    }

    private void ScheduleReconnect(string reason)
    {
        if (!_appSettings.AutoReconnectOnSystemChange
            || (string.IsNullOrWhiteSpace(_appSettings.LastProfileId) && !_appSettings.ConnectBestServerAutomatically))
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

        var profile = ResolveAutomaticConnectionProfile();
        if (profile is null)
        {
            return;
        }

        ProfilesListBox.SelectedItem = profile;
        LoadProfileIntoEditor(profile);
        await RunUiActionAsync(async () =>
        {
            var connection = await ConnectWithFailoverAsync(
                profile,
                _protector.Unprotect(profile.EncryptedPassword),
                _protector.Unprotect(profile.EncryptedTunnelConfig),
                "reconnect");
            var connectResult = connection.Result;
            var connectedProfile = connection.Profile;

            if (connectResult.IsSuccess)
            {
                _appSettings.LastProfileId = connectedProfile.Id;
                await _profileStore.SaveAsync(_profiles);
                await SaveAppSettingsQuietlyAsync();
                RenderServerChoices(SubscriptionSelectorComboBox.SelectedItem as SubscriptionSourceListItem, connectedProfile.Id);
                StartConnectionWatchdog(connectedProfile);
            }
            else
            {
                await _profileStore.SaveAsync(_profiles);
                RenderServerChoices(SubscriptionSelectorComboBox.SelectedItem as SubscriptionSourceListItem, profile.Id);
                StopConnectionWatchdog();
            }

            StatusTextBlock.Text = connectResult.IsSuccess
                ? connection.UsedFailover
                    ? $"Восстановлено через резерв: {reason}"
                    : $"Восстановлено: {reason}"
                : $"{FriendlyErrorService.ToUserMessage(connectResult)}: {reason}";
            UpdateDailyStatusPanel(connectedProfile, connectResult.IsSuccess ? "Подключено" : "Восстановление не удалось");
        }, $"Восстановление: {reason}...");
    }

    private Forms.ContextMenuStrip BuildTrayMenu()
    {
        var menu = new Forms.ContextMenuStrip();

        menu.Items.Add($"Статус: {_dailyConnectionState}", null, (_, _) => Dispatcher.Invoke(ShowFromTray)).Enabled = false;
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Открыть", null, (_, _) => Dispatcher.Invoke(ShowFromTray));
        menu.Items.Add("Подключить выбранный", null, (_, _) => Dispatcher.Invoke(() => ConnectButton_Click(this, new RoutedEventArgs())));
        menu.Items.Add("Подключить лучший", null, (_, _) => Dispatcher.Invoke(ConnectBestServerFromTray));
        menu.Items.Add("Отключить", null, (_, _) => Dispatcher.Invoke(() => DisconnectButton_Click(this, new RoutedEventArgs())));
        menu.Items.Add(BuildTrayServersMenu());
        menu.Items.Add(BuildTrayFavoritesMenu());
        menu.Items.Add("Обновить подписки", null, (_, _) => Dispatcher.Invoke(() => RefreshAllSubscriptionsButton_Click(this, new RoutedEventArgs())));
        menu.Items.Add("Защита", null, (_, _) => Dispatcher.Invoke(ToggleProtectionFromTray));
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

    private Forms.ToolStripMenuItem BuildTrayFavoritesMenu()
    {
        var favoritesMenu = new Forms.ToolStripMenuItem("Избранные");
        var favorites = _serverChoices.Where(server => server.Profile.IsFavorite).Take(10).ToList();
        if (favorites.Count == 0)
        {
            favoritesMenu.DropDownItems.Add(new Forms.ToolStripMenuItem("Нет избранных") { Enabled = false });
            return favoritesMenu;
        }

        foreach (var server in favorites)
        {
            var menuItem = new Forms.ToolStripMenuItem(server.TrayLabel);
            menuItem.Click += (_, _) => Dispatcher.Invoke(() => ConnectServerFromTray(server));
            favoritesMenu.DropDownItems.Add(menuItem);
        }

        return favoritesMenu;
    }

    private void ToggleProtectionFromTray()
    {
        if (GetCurrentOrSelectedProfile() is { } profile && IsProtectionRequested(profile))
        {
            ApplyProtectionButton_Click(this, new RoutedEventArgs());
            return;
        }

        RemoveProtectionButton_Click(this, new RoutedEventArgs());
    }

    private void ConnectBestServerFromTray()
    {
        var best = GetBestServerChoice();
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

        public string SelectorName => Source.IsEnabled
            ? $"{DisplayName} · {Source.LastImportedCount} серверов"
            : $"{DisplayName} · выкл";

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

                var enabled = Source.IsEnabled ? "включена" : "выключена";
                return $"{enabled}; {imported}; {updated}";
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

        public string ProtocolLabel => Profile.Protocol.ToDisplayName();

        public string Endpoint => BuildServerEndpoint(Profile);

        public string BadgeText => BuildBadgeText(DisplayName);

        public string FavoriteMark => Profile.IsFavorite ? "★" : "☆";

        public string ActionMark => "›";

        public string MenuLabel => BuildMenuLabel(Profile);

        public string StatusLabel => BuildStatusLabel(Profile);

        public string SearchText => $"{DisplayName} {Details} {ProtocolLabel} {Endpoint} {MenuLabel} {StatusLabel}";

        public string TrayLabel => $"{DisplayName} ({BuildTrayDetails(Profile)})";

        private static string BuildBadgeText(string value)
        {
            var letters = new string(value
                .Where(char.IsLetterOrDigit)
                .Take(2)
                .ToArray());
            return string.IsNullOrWhiteSpace(letters)
                ? "SS"
                : letters.ToUpperInvariant();
        }

        private static string BuildMenuLabel(VpnProfile profile)
        {
            var markers = new List<string>();
            var probeLabel = BuildProbeLabel(profile);
            if (!string.IsNullOrWhiteSpace(probeLabel))
            {
                markers.Add(probeLabel);
            }

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

        private static string BuildTrayDetails(VpnProfile profile)
        {
            var probeLabel = BuildProbeLabel(profile);
            return string.IsNullOrWhiteSpace(probeLabel)
                ? profile.Protocol.ToDisplayName()
                : $"{profile.Protocol.ToDisplayName()}, {probeLabel}";
        }

        private static string BuildStatusLabel(VpnProfile profile)
        {
            if (profile.WatchdogFailureCount > 0)
            {
                return $"сбоев {profile.WatchdogFailureCount}";
            }

            if (profile.IsFavorite)
            {
                return "избранное";
            }

            if (profile.LastProbeStatus == ServerProbeStatus.Failed)
            {
                return "ошибка";
            }

            if (profile.LastLatencyMs is >= 0)
            {
                return $"{profile.LastLatencyMs} мс";
            }

            return profile.LastConnectedAt is null ? string.Empty : "последний";
        }

        private static string BuildProbeLabel(VpnProfile profile)
        {
            var hasLatency = profile.LastLatencyMs is >= 0;
            return profile.LastProbeStatus switch
            {
                ServerProbeStatus.Connected => "подключен",
                ServerProbeStatus.TcpOk when hasLatency => $"{profile.LastLatencyMs} мс",
                ServerProbeStatus.EndpointResolved when hasLatency => $"адрес {profile.LastLatencyMs} мс",
                ServerProbeStatus.Failed => "нет ответа",
                ServerProbeStatus.Skipped => "нет адреса",
                _ => string.Empty
            };
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

    private sealed record ConnectionFlowResult(
        VpnProfile Profile,
        CommandResult Result,
        bool UsedFailover,
        int AttemptCount);

    private readonly record struct ServerSortKey(int ProbeBucket, int LatencyMs);

    [GeneratedRegex(@"https?://[^\s""'<>]+", RegexOptions.Compiled)]
    private static partial Regex SubscriptionUrlCandidateRegex();

    [GeneratedRegex(@"(?i)(?<prefix>[?&]token=)(?<token>[^&#]+)", RegexOptions.Compiled)]
    private static partial Regex SubscriptionTokenQueryRegex();

    [GeneratedRegex(@"(?i)(?<prefix>/api/sub/)(?<token>[^/?#]+)", RegexOptions.Compiled)]
    private static partial Regex SubscriptionTokenPathRegex();
}
