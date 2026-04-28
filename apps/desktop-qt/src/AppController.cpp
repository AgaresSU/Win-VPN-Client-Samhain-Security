#include "AppController.h"

#include <QClipboard>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QRandomGenerator>
#include <QStandardPaths>
#include <QTime>

ServerListModel::ServerListModel(QObject *parent)
    : QAbstractListModel(parent)
{
}

int ServerListModel::rowCount(const QModelIndex &parent) const
{
    if (parent.isValid()) {
        return 0;
    }

    return static_cast<int>(m_servers.size());
}

QVariant ServerListModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_servers.size()) {
        return {};
    }

    const auto &server = m_servers.at(index.row());
    switch (role) {
    case NameRole:
        return server.name;
    case FlagRole:
        return server.flag;
    case ProtocolRole:
        return server.protocol;
    case EndpointRole:
        return server.endpoint;
    case PingRole:
        return server.ping;
    case SelectedRole:
        return server.selected;
    default:
        return {};
    }
}

QHash<int, QByteArray> ServerListModel::roleNames() const
{
    return {
        {NameRole, "name"},
        {FlagRole, "flag"},
        {ProtocolRole, "protocol"},
        {EndpointRole, "endpoint"},
        {PingRole, "ping"},
        {SelectedRole, "selected"},
    };
}

void ServerListModel::setServers(QVector<ServerItem> servers)
{
    beginResetModel();
    m_servers = std::move(servers);
    if (!m_servers.isEmpty() && selectedRow() < 0) {
        const auto preferred = std::min<qsizetype>(2, m_servers.size() - 1);
        m_servers[preferred].selected = true;
    }
    endResetModel();
}

void ServerListModel::selectRow(int row)
{
    if (row < 0 || row >= m_servers.size()) {
        return;
    }

    const auto oldRow = selectedRow();
    if (oldRow == row) {
        return;
    }

    if (oldRow >= 0) {
        m_servers[oldRow].selected = false;
        emit dataChanged(index(oldRow), index(oldRow), {SelectedRole});
    }

    m_servers[row].selected = true;
    emit dataChanged(index(row), index(row), {SelectedRole});
}

void ServerListModel::setPing(int row, const QString &ping)
{
    if (row < 0 || row >= m_servers.size()) {
        return;
    }

    m_servers[row].ping = ping;
    emit dataChanged(index(row), index(row), {PingRole});
}

const ServerItem *ServerListModel::selectedServer() const
{
    const auto row = selectedRow();
    if (row < 0) {
        return nullptr;
    }

    return &m_servers[row];
}

int ServerListModel::selectedRow() const
{
    for (int i = 0; i < m_servers.size(); ++i) {
        if (m_servers.at(i).selected) {
            return i;
        }
    }

    return -1;
}

AppController::AppController(QObject *parent)
    : QObject(parent)
{
    connect(&m_statsTimer, &QTimer::timeout, this, [this]() {
        if (!m_connected) {
            return;
        }

        const auto down = QRandomGenerator::global()->bounded(480, 4200) / 100.0;
        const auto up = QRandomGenerator::global()->bounded(120, 1200) / 100.0;
        m_downTotalMb += down / 8.0;
        m_upTotalMb += up / 12.0;
        m_downloadSpeed = QString::number(down, 'f', 1) + " MB/s";
        m_uploadSpeed = QString::number(up, 'f', 1) + " MB/s";
        m_sessionTraffic = QString("↓ %1 MB / ↑ %2 MB")
            .arg(m_downTotalMb, 0, 'f', 1)
            .arg(m_upTotalMb, 0, 'f', 1);

        const auto seconds = m_connectedAt.secsTo(QDateTime::currentDateTime());
        m_sessionTime = QTime(0, 0).addSecs(static_cast<int>(seconds)).toString("hh:mm:ss");
        emit statsChanged();
    });
    m_statsTimer.setInterval(1000);

    loadState();
    updateSelectedServerProperties();
}

QAbstractListModel *AppController::serverModel()
{
    return &m_serverModel;
}

QString AppController::page() const
{
    return m_page;
}

QString AppController::subscriptionName() const
{
    return m_subscriptionName;
}

QString AppController::subscriptionMeta() const
{
    return m_subscriptionMeta;
}

QString AppController::selectedServerName() const
{
    return m_selectedServerName;
}

QString AppController::selectedServerFlag() const
{
    return m_selectedServerFlag;
}

QString AppController::selectedServerProtocol() const
{
    return m_selectedServerProtocol;
}

QString AppController::selectedServerPing() const
{
    return m_selectedServerPing;
}

QString AppController::statusText() const
{
    return m_statusText;
}

bool AppController::connected() const
{
    return m_connected;
}

int AppController::routeModeIndex() const
{
    return m_routeModeIndex;
}

QString AppController::downloadSpeed() const
{
    return m_downloadSpeed;
}

QString AppController::uploadSpeed() const
{
    return m_uploadSpeed;
}

QString AppController::sessionTraffic() const
{
    return m_sessionTraffic;
}

QString AppController::sessionTime() const
{
    return m_sessionTime;
}

QStringList AppController::logs() const
{
    return m_logs;
}

void AppController::navigate(const QString &page)
{
    if (m_page == page) {
        return;
    }

    m_page = page;
    emit pageChanged();
}

void AppController::selectServer(int row)
{
    m_serverModel.selectRow(row);
    updateSelectedServerProperties();
    appendLog("Выбран сервер: " + m_selectedServerName);
}

void AppController::toggleConnection()
{
    m_connected = !m_connected;
    if (m_connected) {
        m_connectedAt = QDateTime::currentDateTime();
        m_statusText = "Подключён";
        m_downTotalMb = 0.0;
        m_upTotalMb = 0.0;
        m_statsTimer.start();
        appendLog("Подключение: " + m_selectedServerName);
    } else {
        m_statusText = "Отключено";
        m_downloadSpeed = "0.0 KB/s";
        m_uploadSpeed = "0.0 KB/s";
        m_statsTimer.stop();
        appendLog("Отключено");
        emit statsChanged();
    }

    emit statusChanged();
    emit connectionChanged();
}

void AppController::testPing()
{
    const auto row = m_serverModel.selectedRow();
    if (row < 0) {
        return;
    }

    m_serverModel.setPing(row, "...");
    const auto ping = QRandomGenerator::global()->bounded(42, 420);
    QTimer::singleShot(650, this, [this, row, ping]() {
        m_serverModel.setPing(row, QString::number(ping) + "ms");
        updateSelectedServerProperties();
        appendLog("Пинг: " + m_selectedServerName + " - " + QString::number(ping) + "ms");
    });
}

void AppController::pasteFromClipboard()
{
    const auto text = QGuiApplication::clipboard()->text().trimmed();
    if (text.isEmpty()) {
        m_statusText = "Буфер пуст";
        emit statusChanged();
        return;
    }

    const auto lower = text.toLower();
    const auto looksLikeSubscription = lower.startsWith("http://")
        || lower.startsWith("https://")
        || lower.startsWith("vless://")
        || lower.startsWith("trojan://")
        || lower.startsWith("ss://")
        || lower.startsWith("hysteria2://")
        || lower.startsWith("hy2://")
        || lower.startsWith("tuic://")
        || lower.startsWith("wg://")
        || lower.startsWith("awg://");

    if (!looksLikeSubscription) {
        m_statusText = "В буфере не похожая ссылка";
        emit statusChanged();
        return;
    }

    addSubscription("Новая подписка", text);
    m_statusText = "Подписка добавлена из буфера";
    emit statusChanged();
}

void AppController::addSubscription(const QString &name, const QString &url)
{
    m_subscriptionName = name.trimmed().isEmpty() ? "Samhain Security" : name.trimmed();
    m_subscriptionUrl = url.trimmed();
    m_subscriptionMeta = QDateTime::currentDateTime().toString("dd.MM.yyyy HH:mm")
        + " | Автообновление - 24ч.";
    m_serverModel.setServers(buildServersForUrl(m_subscriptionUrl));
    updateSelectedServerProperties();
    saveState();
    appendLog("Добавлена подписка: " + m_subscriptionName);
    emit subscriptionChanged();
}

void AppController::clearLogs()
{
    m_logs.clear();
    emit logsChanged();
}

void AppController::openAdvancedSettings()
{
    navigate("settings");
    appendLog("Открыты расширенные настройки");
}

void AppController::setRouteModeIndex(int routeModeIndex)
{
    if (m_routeModeIndex == routeModeIndex) {
        return;
    }

    m_routeModeIndex = routeModeIndex;
    saveState();
    appendLog("Режим маршрутизации изменён");
    emit routeModeChanged();
}

void AppController::loadState()
{
    QFile file(stateFilePath());
    if (!file.open(QIODevice::ReadOnly)) {
        loadSampleSubscription();
        return;
    }

    const auto document = QJsonDocument::fromJson(file.readAll());
    const auto object = document.object();
    m_subscriptionName = object.value("name").toString("Samhain Security");
    m_subscriptionUrl = object.value("url").toString();
    m_subscriptionMeta = object.value("meta").toString("27.04.2026 23:22 | Автообновление - 24ч.");
    m_routeModeIndex = object.value("routeMode").toInt(0);

    QVector<ServerItem> servers;
    for (const auto value : object.value("servers").toArray()) {
        const auto item = value.toObject();
        servers.push_back({
            item.value("name").toString(),
            item.value("flag").toString(),
            item.value("protocol").toString(),
            item.value("endpoint").toString(),
            item.value("ping").toString("n/a"),
            item.value("selected").toBool(false),
        });
    }

    if (servers.isEmpty()) {
        loadSampleSubscription();
    } else {
        m_serverModel.setServers(servers);
    }
}

void AppController::saveState() const
{
    QJsonArray servers;
    for (int row = 0; row < m_serverModel.rowCount(); ++row) {
        const auto modelIndex = m_serverModel.index(row);
        QJsonObject item;
        item["name"] = m_serverModel.data(modelIndex, ServerListModel::NameRole).toString();
        item["flag"] = m_serverModel.data(modelIndex, ServerListModel::FlagRole).toString();
        item["protocol"] = m_serverModel.data(modelIndex, ServerListModel::ProtocolRole).toString();
        item["endpoint"] = m_serverModel.data(modelIndex, ServerListModel::EndpointRole).toString();
        item["ping"] = m_serverModel.data(modelIndex, ServerListModel::PingRole).toString();
        item["selected"] = m_serverModel.data(modelIndex, ServerListModel::SelectedRole).toBool();
        servers.push_back(item);
    }

    QJsonObject root;
    root["name"] = m_subscriptionName;
    root["url"] = m_subscriptionUrl;
    root["meta"] = m_subscriptionMeta;
    root["routeMode"] = m_routeModeIndex;
    root["servers"] = servers;

    const auto path = stateFilePath();
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    if (file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        file.write(QJsonDocument(root).toJson(QJsonDocument::Indented));
    }
}

void AppController::loadSampleSubscription()
{
    m_serverModel.setServers({
        {"Samhain GB London #1", "🇬🇧", "VLESS / TCP / REALITY", "gb-london-1.samhain", "1277ms", false},
        {"Samhain GB London #2", "🇬🇧", "VLESS / TCP / REALITY", "gb-london-2.samhain", "1189ms", false},
        {"Samhain NL Amsterdam #3", "🇳🇱", "VLESS / TCP / REALITY", "nl-amsterdam-3.samhain", "360ms", true},
        {"Samhain SE Evle #4", "🇸🇪", "Trojan", "se-evle-4.samhain", "248ms", false},
        {"Samhain SE Evle #5", "🇸🇪", "Shadowsocks", "se-evle-5.samhain", "251ms", false},
        {"Samhain DE Frankfurt #6", "🇩🇪", "AmneziaWG", "de-frankfurt-6.samhain", "n/a", false},
        {"Samhain DE Frankfurt #7", "🇩🇪", "Hysteria2", "de-frankfurt-7.samhain", "n/a", false},
    });
}

QVector<ServerItem> AppController::buildServersForUrl(const QString &url) const
{
    const auto lower = url.toLower();
    const auto seedName = m_subscriptionName.trimmed().isEmpty() ? "Samhain" : m_subscriptionName.trimmed();

    if (lower.startsWith("vless://")
        || lower.startsWith("trojan://")
        || lower.startsWith("ss://")
        || lower.startsWith("hysteria2://")
        || lower.startsWith("hy2://")
        || lower.startsWith("tuic://")
        || lower.startsWith("wg://")
        || lower.startsWith("awg://")) {
        QString protocol = "VLESS / TCP / REALITY";
        if (lower.startsWith("trojan://")) {
            protocol = "Trojan";
        } else if (lower.startsWith("ss://")) {
            protocol = "Shadowsocks";
        } else if (lower.startsWith("hysteria2://") || lower.startsWith("hy2://")) {
            protocol = "Hysteria2";
        } else if (lower.startsWith("tuic://")) {
            protocol = "TUIC";
        } else if (lower.startsWith("wg://")) {
            protocol = "WireGuard";
        } else if (lower.startsWith("awg://")) {
            protocol = "AmneziaWG";
        }

        return {
            {seedName + " импорт #1", "◉", protocol, url.left(42), "n/a", true},
        };
    }

    return {
        {seedName + " GB London #1", "🇬🇧", "VLESS / TCP / REALITY", "gb-london-1.samhain", "n/a", false},
        {seedName + " NL Amsterdam #2", "🇳🇱", "VLESS / TCP / REALITY", "nl-amsterdam-2.samhain", "n/a", true},
        {seedName + " DE Frankfurt #3", "🇩🇪", "AmneziaWG", "de-frankfurt-3.samhain", "n/a", false},
        {seedName + " SE Evle #4", "🇸🇪", "Trojan", "se-evle-4.samhain", "n/a", false},
    };
}

void AppController::appendLog(const QString &message)
{
    m_logs.prepend(QDateTime::currentDateTime().toString("[dd.MM HH:mm:ss] ") + message);
    while (m_logs.size() > 200) {
        m_logs.removeLast();
    }
    emit logsChanged();
}

void AppController::updateSelectedServerProperties()
{
    const auto *server = m_serverModel.selectedServer();
    if (!server) {
        return;
    }

    m_selectedServerName = server->name;
    m_selectedServerFlag = server->flag;
    m_selectedServerProtocol = server->protocol;
    m_selectedServerPing = server->ping;
    emit selectedServerChanged();
}

QString AppController::stateFilePath() const
{
    const auto appData = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    return QDir(appData).filePath("subscriptions.json");
}
