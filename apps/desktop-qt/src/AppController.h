#pragma once

#include <QAbstractListModel>
#include <QDateTime>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QTimer>
#include <QVector>

struct ServerItem {
    QString name;
    QString flag;
    QString protocol;
    QString endpoint;
    QString ping;
    bool selected = false;
};

class ServerListModel final : public QAbstractListModel {
    Q_OBJECT

public:
    enum Roles {
        NameRole = Qt::UserRole + 1,
        FlagRole,
        ProtocolRole,
        EndpointRole,
        PingRole,
        SelectedRole
    };

    explicit ServerListModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role = Qt::DisplayRole) const override;
    QHash<int, QByteArray> roleNames() const override;

    void setServers(QVector<ServerItem> servers);
    void selectRow(int row);
    void setPing(int row, const QString &ping);
    const ServerItem *selectedServer() const;
    int selectedRow() const;

private:
    QVector<ServerItem> m_servers;
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
    QStringList logs() const;

    Q_INVOKABLE void navigate(const QString &page);
    Q_INVOKABLE void selectServer(int row);
    Q_INVOKABLE void toggleConnection();
    Q_INVOKABLE void testPing();
    Q_INVOKABLE void pasteFromClipboard();
    Q_INVOKABLE void addSubscription(const QString &name, const QString &url);
    Q_INVOKABLE void clearLogs();
    Q_INVOKABLE void openAdvancedSettings();

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
    void logsChanged();

private:
    void loadState();
    bool loadStateFromService();
    bool applyServiceState(const QJsonObject &state);
    void saveState() const;
    void loadSampleSubscription();
    QVector<ServerItem> buildServersForUrl(const QString &url) const;
    QString requestService(const QJsonObject &command, int timeoutMs) const;
    QString protocolLabel(const QString &wireProtocol) const;
    QString flagForCountry(const QString &countryCode) const;
    QString routeModeWireValue() const;
    int routeModeIndexFromWire(const QString &routeMode) const;
    void appendLog(const QString &message);
    void updateSelectedServerProperties();
    QString stateFilePath() const;

    ServerListModel m_serverModel;
    QString m_page = "servers";
    QString m_subscriptionName = "Samhain Security";
    QString m_subscriptionUrl;
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
    QStringList m_logs;
    QTimer m_statsTimer;
    QDateTime m_connectedAt;
    double m_downTotalMb = 0.0;
    double m_upTotalMb = 0.0;
};
