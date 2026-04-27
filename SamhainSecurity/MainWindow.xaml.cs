using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Drawing;
using System.Reflection;
using System.Windows;
using Microsoft.Win32;
using VpnClientWindows.Models;
using VpnClientWindows.Services;
using Forms = System.Windows.Forms;

namespace VpnClientWindows;

public partial class MainWindow : Window
{
    private readonly ObservableCollection<VpnProfile> _profiles = [];
    private readonly ProfileStore _profileStore = new();
    private readonly SecureDataProtector _protector = new();
    private readonly MultiProtocolVpnService _vpnService = new();
    private readonly EnvironmentDiagnosticsService _diagnosticsService = new();
    private readonly EngineAvailabilityService _engineAvailabilityService = new();
    private Forms.NotifyIcon? _notifyIcon;
    private bool _allowExit;
    private bool _isBusy;
    private bool _isLoadingProfile;

    public MainWindow()
    {
        InitializeComponent();

        VersionTextBlock.Text = "v" + GetAppVersion();
        ProfilesListBox.ItemsSource = _profiles;

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
        UpdateAdminButton();
    }

    private async void Window_Loaded(object sender, RoutedEventArgs e)
    {
        await RunUiActionAsync(async () =>
        {
            var profiles = await _profileStore.LoadAsync();
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

            AppendLog($"Профили: {_profiles.Count}. Хранилище: {_profileStore.FilePath}");
        }, "Загрузка профилей...");
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

    private void NewProfileButton_Click(object sender, RoutedEventArgs e)
    {
        ProfilesListBox.SelectedItem = null;
        ClearEditor();
        StatusTextBlock.Text = "Новый профиль";
    }

    private async void SaveProfileButton_Click(object sender, RoutedEventArgs e)
    {
        await RunUiActionAsync(async () =>
        {
            var profile = await SaveCurrentProfileAsync();
            if (profile is not null)
            {
                StatusTextBlock.Text = "Профиль сохранен";
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
            if (!removeResult.IsSuccess)
            {
                AppendCommandResult("profile cleanup", removeResult);
            }

            _profiles.Remove(profile);
            await _profileStore.SaveAsync(_profiles);
            ClearEditor();
            StatusTextBlock.Text = "Профиль удален";
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
            AppendCommandResult($"{profile.Protocol.ToDisplayName()} connect", connectResult);

            StatusTextBlock.Text = connectResult.IsSuccess
                ? "Подключено"
                : "Подключение не удалось";
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
            AppendCommandResult($"{profile.Protocol.ToDisplayName()} disconnect", disconnectResult);

            StatusTextBlock.Text = disconnectResult.IsSuccess
                ? "Отключено"
                : "Отключение не удалось";
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
            AppendCommandResult($"{profile.Protocol.ToDisplayName()} status", statusResult);

            StatusTextBlock.Text = statusResult.IsSuccess
                ? $"Статус: {statusResult.Output.Trim()}"
                : "Статус недоступен";
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

        if (!string.IsNullOrWhiteSpace(oldName)
            && !string.Equals(oldName, profile.Name, StringComparison.OrdinalIgnoreCase)
            && oldProfile?.Protocol == VpnProtocolType.WindowsNative)
        {
            var removeOldResult = await _vpnService.RemoveProfileAsync(oldProfile, GetTunnelConfig());
            if (!removeOldResult.IsSuccess)
            {
                AppendCommandResult("old Windows native profile remove", removeOldResult);
            }
        }

        var prepareResult = await _vpnService.PrepareProfileAsync(profile, L2tpPskPasswordBox.Password);
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
        validationError = ValidateProfile(profile);

        return string.IsNullOrWhiteSpace(validationError);
    }

    private VpnProfile BuildProfileFromEditorWithoutValidation()
    {
        var oldProfile = ProfilesListBox.SelectedItem as VpnProfile;
        var protocol = ProtocolComboBox.SelectedValue is VpnProtocolType selectedProtocol
            ? selectedProtocol
            : VpnProtocolType.WindowsNative;

        return new VpnProfile
        {
            Id = oldProfile?.Id ?? Guid.NewGuid().ToString("N"),
            Name = NameTextBox.Text.Trim(),
            Protocol = protocol,
            ServerAddress = ServerTextBox.Text.Trim(),
            ServerPort = ParsePortOrDefault(ServerPortTextBox.Text),
            TunnelType = TunnelTypeComboBox.SelectedValue is VpnTunnelType tunnelType
                ? tunnelType
                : VpnTunnelType.Ikev2,
            UserName = UserNameTextBox.Text.Trim(),
            EncryptedPassword = _protector.Protect(PasswordBox.Password),
            EncryptedL2tpPsk = _protector.Protect(L2tpPskPasswordBox.Password),
            SplitTunneling = SplitTunnelingCheckBox.IsChecked == true,
            VlessUuid = VlessUuidTextBox.Text.Trim(),
            VlessFlow = VlessFlowTextBox.Text.Trim(),
            RealityServerName = RealityServerNameTextBox.Text.Trim(),
            RealityPublicKey = RealityPublicKeyTextBox.Text.Trim(),
            RealityShortId = RealityShortIdTextBox.Text.Trim(),
            RealityFingerprint = RealityFingerprintTextBox.Text.Trim(),
            EnginePath = EnginePathTextBox.Text.Trim(),
            EncryptedTunnelConfig = _protector.Protect(GetTunnelConfig()),
            UpdatedAt = DateTimeOffset.UtcNow
        };
    }

    private static string ValidateProfile(VpnProfile profile)
    {
        if (string.IsNullOrWhiteSpace(profile.Name))
        {
            return "Введите название профиля";
        }

        if (profile.Protocol is VpnProtocolType.WindowsNative or VpnProtocolType.VlessReality
            && string.IsNullOrWhiteSpace(profile.ServerAddress))
        {
            return "Введите адрес сервера";
        }

        if (profile.Protocol == VpnProtocolType.VlessReality)
        {
            if (profile.ServerPort <= 0 || profile.ServerPort > 65535)
            {
                return "Введите корректный порт VLESS";
            }

            if (string.IsNullOrWhiteSpace(profile.VlessUuid))
            {
                return "Введите UUID VLESS";
            }

            if (string.IsNullOrWhiteSpace(profile.RealityServerName))
            {
                return "Введите Reality SNI";
            }

            if (string.IsNullOrWhiteSpace(profile.RealityPublicKey))
            {
                return "Введите Reality public key";
            }
        }

        if (profile.Protocol is VpnProtocolType.WireGuard or VpnProtocolType.AmneziaWireGuard
            && string.IsNullOrWhiteSpace(profile.EncryptedTunnelConfig))
        {
            return "Вставьте .conf";
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

    private void UpdateAdminButton()
    {
        RunAsAdminButton.Visibility = AdminElevationService.IsAdministrator()
            ? Visibility.Collapsed
            : Visibility.Visible;
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
        DiagnosticsButton.IsEnabled = !isBusy;
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
    }

    private string GetTunnelConfig()
    {
        return TunnelConfigTextBox.Text.Trim();
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

    private Forms.ContextMenuStrip BuildTrayMenu()
    {
        var menu = new Forms.ContextMenuStrip();

        menu.Items.Add("Открыть", null, (_, _) => Dispatcher.Invoke(ShowFromTray));
        menu.Items.Add("Подключить", null, (_, _) => Dispatcher.Invoke(() => ConnectButton_Click(this, new RoutedEventArgs())));
        menu.Items.Add("Отключить", null, (_, _) => Dispatcher.Invoke(() => DisconnectButton_Click(this, new RoutedEventArgs())));
        menu.Items.Add("Диагностика", null, (_, _) => Dispatcher.Invoke(() => DiagnosticsButton_Click(this, new RoutedEventArgs())));
        menu.Items.Add("Запуск от администратора", null, (_, _) => Dispatcher.Invoke(RelaunchAsAdministrator));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Выход", null, (_, _) => Dispatcher.Invoke(ExitApplication));

        return menu;
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
}
