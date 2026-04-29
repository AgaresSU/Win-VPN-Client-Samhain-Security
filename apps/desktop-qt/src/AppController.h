#pragma once

#include <QAbstractListModel>
#include <QDateTime>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QStringList>
#include <QTimer>
#include <QVector>

class QAction;
class QMenu;
class QSystemTrayIcon;

struct ServerItem {
    QString id;
    QString subscriptionId;
    QString name;
    QString flag;
    QString protocol;
    QString endpoint;
    QString ping;
    bool selected = false;
};

struct SubscriptionItem {
    QString id;
    QString name;
    QString meta;
    bool expanded = true;
    QVector<ServerItem> servers;
};

struct RouteApplicationItem {
    QString id;
    QString name;
    QString path;
    bool enabled = true;
};

class ServerListModel final : public QAbstractListModel {
    Q_OBJECT

public:
    enum Roles {
        IsSubscriptionRole = Qt::UserRole + 1,
        SubscriptionIdRole,
        ServerIdRole,
        NameRole,
        FlagRole,
        ProtocolRole,
        EndpointRole,
        PingRole,
        SelectedRole,
        ExpandedRole,
        MetaRole,
        ServerCountRole
    };

    explicit ServerListModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role = Qt::DisplayRole) const override;
    QHash<int, QByteArray> roleNames() const override;

    void setSubscriptions(QVector<SubscriptionItem> subscriptions, const QString &preferredServerId = {});
    void setServers(QVector<ServerItem> servers);
    void selectRow(int row);
    void setPing(int row, const QString &ping);
    void setPingByServerId(const QString &serverId, const QString &ping);
    void toggleSubscription(int row);
    bool isSubscriptionRow(int row) const;
    QString subscriptionIdAtRow(int row) const;
    QString subscriptionNameAtRow(int row) const;
    int serverCountAtRow(int row) const;
    QVector<QString> serverIds() const;
    const ServerItem *selectedServer() const;
    const SubscriptionItem *selectedSubscription() const;
    const QVector<SubscriptionItem> &subscriptions() const;
    int selectedRow() const;

private:
    struct VisibleRow {
        bool isSubscription = false;
        int subscriptionIndex = -1;
        int serverIndex = -1;
    };

    void rebuildRows();
    int visibleRowForServer(const QString &serverId) const;
    void clearSelection();

    QVector<SubscriptionItem> m_subscriptions;
    QVector<VisibleRow> m_rows;
};

class AppController final : public QObject {
    Q_OBJECT
    Q_PROPERTY(QAbstractListModel* serverModel READ serverModel CONSTANT)
    Q_PROPERTY(QString page READ page NOTIFY pageChanged)
    Q_PROPERTY(QString subscriptionName READ subscriptionName NOTIFY subscriptionChanged)
    Q_PROPERTY(QString subscriptionMeta READ subscriptionMeta NOTIFY subscriptionChanged)
    Q_PROPERTY(QString selectedServerName READ selectedServerName NOTIFY selectedServerChanged)
    Q_PROPERTY(QString selectedServerFlag READ selectedServerFlag NOTIFY selectedServerChanged)
    Q_PROPERTY(QString selectedServerProtocol READ selectedServerProtocol NOTIFY selectedServerChanged)
    Q_PROPERTY(QString selectedServerPing READ selectedServerPing NOTIFY selectedServerChanged)
    Q_PROPERTY(QString statusText READ statusText NOTIFY statusChanged)
    Q_PROPERTY(bool connected READ connected NOTIFY connectionChanged)
    Q_PROPERTY(int routeModeIndex READ routeModeIndex WRITE setRouteModeIndex NOTIFY routeModeChanged)
    Q_PROPERTY(QString downloadSpeed READ downloadSpeed NOTIFY statsChanged)
    Q_PROPERTY(QString uploadSpeed READ uploadSpeed NOTIFY statsChanged)
    Q_PROPERTY(QString sessionTraffic READ sessionTraffic NOTIFY statsChanged)
    Q_PROPERTY(QString sessionTime READ sessionTime NOTIFY statsChanged)
    Q_PROPERTY(QString engineStatus READ engineStatus NOTIFY engineChanged)
    Q_PROPERTY(QString engineDetail READ engineDetail NOTIFY engineChanged)
    Q_PROPERTY(QString engineConfigPreview READ engineConfigPreview NOTIFY engineChanged)
    Q_PROPERTY(QStringList engineCatalog READ engineCatalog NOTIFY engineChanged)
    Q_PROPERTY(QString proxyStatus READ proxyStatus NOTIFY proxyChanged)
    Q_PROPERTY(QString proxyDetail READ proxyDetail NOTIFY proxyChanged)
    Q_PROPERTY(QString tunStatus READ tunStatus NOTIFY tunChanged)
    Q_PROPERTY(QString tunDetail READ tunDetail NOTIFY tunChanged)
    Q_PROPERTY(QString routeAppCountLabel READ routeAppCountLabel NOTIFY appRoutingChanged)
    Q_PROPERTY(QString routePolicyStatus READ routePolicyStatus NOTIFY appRoutingChanged)
    Q_PROPERTY(QString routePolicyDetail READ routePolicyDetail NOTIFY appRoutingChanged)
    Q_PROPERTY(QStringList routeApplications READ routeApplications NOTIFY appRoutingChanged)
    Q_PROPERTY(QString protectionStatus READ protectionStatus NOTIFY protectionChanged)
    Q_PROPERTY(QString protectionDetail READ protectionDetail NOTIFY protectionChanged)
    Q_PROPERTY(bool minimizeToTray READ minimizeToTray NOTIFY desktopIntegrationChanged)
    Q_PROPERTY(bool autostartEnabled READ autostartEnabled NOTIFY desktopIntegrationChanged)
    Q_PROPERTY(QString desktopIntegrationStatus READ desktopIntegrationStatus NOTIFY desktopIntegrationChanged)
    Q_PROPERTY(QStringList logs READ logs NOTIFY logsChanged)

public:
    explicit AppController(QObject *parent = nullptr);

    QAbstractListModel *serverModel();
    QString page() const;
    QString subscriptionName() const;
    QString subscriptionMeta() const;
    QString selectedServerName() const;
    QString selectedServerFlag() const;
    QString selectedServerProtocol() const;
    QString selectedServerPing() const;
    QString statusText() const;
    bool connected() const;
    int routeModeIndex() const;
    QString downloadSpeed() const;
    QString uploadSpeed() const;
    QString sessionTraffic() const;
    QString sessionTime() const;
    QString engineStatus() const;
    QString engineDetail() const;
    QString engineConfigPreview() const;
    QStringList engineCatalog() const;
    QString proxyStatus() const;
    QString proxyDetail() const;
    QString tunStatus() const;
    QString tunDetail() const;
    QString routeAppCountLabel() const;
    QString routePolicyStatus() const;
    QString routePolicyDetail() const;
    QStringList routeApplications() const;
    QString protectionStatus() const;
    QString protectionDetail() const;
    bool minimizeToTray() const;
    bool autostartEnabled() const;
    QString desktopIntegrationStatus() const;
    QStringList logs() const;

    Q_INVOKABLE void navigate(const QString &page);
    Q_INVOKABLE void selectServer(int row);
    Q_INVOKABLE void toggleSubscription(int row);
    Q_INVOKABLE void toggleConnection();
    Q_INVOKABLE void testPing();
    Q_INVOKABLE void testAllPings();
    Q_INVOKABLE void pasteFromClipboard();
    Q_INVOKABLE void addSubscription(const QString &name, const QString &url);
    Q_INVOKABLE void refreshSubscription(int row);
    Q_INVOKABLE void renameSubscription(int row, const QString &name);
    Q_INVOKABLE void deleteSubscription(int row);
    Q_INVOKABLE void copySubscriptionDiagnostics(int row);
    Q_INVOKABLE void clearLogs();
    Q_INVOKABLE void openAdvancedSettings();
    Q_INVOKABLE void refreshEngineStatus();
    Q_INVOKABLE void previewSelectedEngineConfig();
    Q_INVOKABLE void restartEngine();
    Q_INVOKABLE void stopEngine();
    Q_INVOKABLE void refreshProxyStatus();
    Q_INVOKABLE void restoreProxyPolicy();
    Q_INVOKABLE void refreshTunStatus();
    Q_INVOKABLE void restoreTunPolicy();
    Q_INVOKABLE void refreshAppRoutingPolicy();
    Q_INVOKABLE void restoreAppRoutingPolicy();
    Q_INVOKABLE void addRouteApplication(const QString &path);
    Q_INVOKABLE void removeRouteApplication(int index);
    Q_INVOKABLE void refreshProtectionPolicy();
    Q_INVOKABLE void restoreProtectionPolicy();
    Q_INVOKABLE void emergencyRestore();
    Q_INVOKABLE void notifyMinimizedToTray();
    Q_INVOKABLE void setAutostartEnabled(bool enabled);
    Q_INVOKABLE void registerLinkHandler();
    Q_INVOKABLE void handleExternalActivation(const QStringList &arguments);

public slots:
    void setRouteModeIndex(int routeModeIndex);

signals:
    void pageChanged();
    void subscriptionChanged();
    void selectedServerChanged();
    void statusChanged();
    void connectionChanged();
    void routeModeChanged();
    void statsChanged();
    void engineChanged();
    void proxyChanged();
    void tunChanged();
    void appRoutingChanged();
    void protectionChanged();
    void desktopIntegrationChanged();
    void showMainWindowRequested();
    void hideMainWindowRequested();
    void logsChanged();

private:
    void setupTray();
    void updateTrayState();
    bool importActivationUrl(const QString &source);
    bool looksLikeImportSource(const QString &text) const;
    bool startupShortcutEnabled() const;
    void setDesktopIntegrationStatus(const QString &message);
    void loadState();
    bool loadStateFromService();
    bool applyServiceState(const QJsonObject &state);
    void saveState() const;
    void loadSampleSubscription();
    SubscriptionItem buildLocalSubscription(
        const QString &id,
        const QString &name,
        const QString &meta,
        QVector<ServerItem> servers) const;
    QVector<ServerItem> buildServersForUrl(const QString &url) const;
    QString requestService(const QJsonObject &command, int timeoutMs) const;
    QString protocolLabel(const QString &wireProtocol) const;
    QString flagForCountry(const QString &countryCode) const;
    QString routeModeWireValue() const;
    int routeModeIndexFromWire(const QString &routeMode) const;
    bool applyPingEvent(const QJsonObject &event);
    bool applyEngineStatusEvent(const QJsonObject &event);
    bool applyProxyStatusEvent(const QJsonObject &event);
    bool applyTunStatusEvent(const QJsonObject &event);
    bool applyAppRoutingPolicyEvent(const QJsonObject &event);
    bool applyProtectionPolicyEvent(const QJsonObject &event);
    void applyEngineStateObject(const QJsonObject &state);
    void applyEngineCatalogArray(const QJsonArray &catalog);
    void applyProxyStateObject(const QJsonObject &state);
    void applyTunStateObject(const QJsonObject &state);
    void applyAppRoutingPolicyObject(const QJsonObject &state);
    void applyProtectionPolicyObject(const QJsonObject &state);
    void syncAppRoutingPolicy();
    QJsonArray routeApplicationArray() const;
    QString engineStatusLabel(const QString &status) const;
    QString proxyStatusLabel(const QString &status, bool enabled) const;
    QString tunStatusLabel(const QString &status, bool enabled) const;
    QString routePolicyStatusLabel(const QString &status, bool supported) const;
    QString protectionStatusLabel(const QString &status, bool supported, bool enforcing) const;
    QString pingLabelFromProbe(const QJsonObject &probe) const;
    QString fallbackPingLabel(const QString &serverId) const;
    void appendLog(const QString &message);
    void updateSelectedServerProperties();
    QString stateFilePath() const;

    ServerListModel m_serverModel;
    QString m_page = "servers";
    QString m_subscriptionName = "Samhain Security";
    QString m_subscriptionMeta = "27.04.2026 23:22 | Автообновление - 24ч.";
    QString m_selectedServerName = "Samhain NL Amsterdam #3";
    QString m_selectedServerFlag = "🇳🇱";
    QString m_selectedServerProtocol = "VLESS / TCP / REALITY";
    QString m_selectedServerPing = "360ms";
    QString m_statusText = "Готово";
    bool m_connected = false;
    int m_routeModeIndex = 0;
    QString m_downloadSpeed = "0.0 KB/s";
    QString m_uploadSpeed = "0.0 KB/s";
    QString m_sessionTraffic = "↓ 0 B / ↑ 0 B";
    QString m_sessionTime = "00:00:00";
    QString m_engineStatus = "Остановлен";
    QString m_engineDetail = "Движок ещё не запускался";
    QString m_engineConfigPreview = "Выберите сервер и нажмите подготовку конфигурации.";
    QStringList m_engineCatalog;
    QString m_proxyStatus = "Не активен";
    QString m_proxyDetail = "Системный proxy не изменялся";
    QString m_tunStatus = "Не активен";
    QString m_tunDetail = "TUN path не запускался";
    QVector<RouteApplicationItem> m_routeApplications;
    QString m_routePolicyStatus = "Не активна";
    QString m_routePolicyDetail = "Режим всего компьютера не требует списка приложений.";
    QString m_protectionStatus = "Готова";
    QString m_protectionDetail = "Kill switch, DNS guard, IPv6 policy и watchdog будут применены сервисом.";
    bool m_minimizeToTray = true;
    bool m_autostartEnabled = false;
    QString m_desktopIntegrationStatus = "Трей готов";
    QStringList m_logs;
    QSystemTrayIcon *m_trayIcon = nullptr;
    QMenu *m_trayMenu = nullptr;
    QAction *m_trayShowAction = nullptr;
    QAction *m_trayConnectAction = nullptr;
    QAction *m_trayQuitAction = nullptr;
    QTimer m_statsTimer;
    QTimer m_probeTimer;
    QDateTime m_connectedAt;
    double m_downTotalMb = 0.0;
    double m_upTotalMb = 0.0;
};
