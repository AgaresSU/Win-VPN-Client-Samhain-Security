#include "AppController.h"

#include <algorithm>
#include <numeric>

#include <QClipboard>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QRandomGenerator>
#include <QStandardPaths>
#include <QTime>

#ifdef Q_OS_WIN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace {
constexpr int IpcProtocolVersion = 1;
constexpr int IpcRequestTimeoutMs = 350;
constexpr int IpcEngineTimeoutMs = 1500;
constexpr auto IpcPipeName = L"\\\\.\\pipe\\SamhainSecurity.Native.Ipc";
}

ServerListModel::ServerListModel(QObject *parent)
    : QAbstractListModel(parent)
{
}

int ServerListModel::rowCount(const QModelIndex &parent) const
{
    if (parent.isValid()) {
        return 0;
    }

    return static_cast<int>(m_rows.size());
}

QVariant ServerListModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_rows.size()) {
        return {};
    }

    const auto &row = m_rows.at(index.row());
    if (row.subscriptionIndex < 0 || row.subscriptionIndex >= m_subscriptions.size()) {
        return {};
    }

    const auto &subscription = m_subscriptions.at(row.subscriptionIndex);
    if (row.isSubscription) {
        switch (role) {
        case IsSubscriptionRole:
            return true;
        case SubscriptionIdRole:
            return subscription.id;
        case NameRole:
            return subscription.name;
        case ExpandedRole:
            return subscription.expanded;
        case MetaRole:
            return subscription.meta;
        case ServerCountRole:
            return subscription.servers.size();
        default:
            return {};
        }
    }

    if (row.serverIndex < 0 || row.serverIndex >= subscription.servers.size()) {
        return {};
    }

    const auto &server = subscription.servers.at(row.serverIndex);
    switch (role) {
    case IsSubscriptionRole:
        return false;
    case SubscriptionIdRole:
        return server.subscriptionId;
    case ServerIdRole:
        return server.id;
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
        {IsSubscriptionRole, "isSubscription"},
        {SubscriptionIdRole, "subscriptionId"},
        {ServerIdRole, "serverId"},
        {NameRole, "name"},
        {FlagRole, "flag"},
        {ProtocolRole, "protocol"},
        {EndpointRole, "endpoint"},
        {PingRole, "ping"},
        {SelectedRole, "selected"},
        {ExpandedRole, "expanded"},
        {MetaRole, "meta"},
        {ServerCountRole, "serverCount"},
    };
}

void ServerListModel::setSubscriptions(QVector<SubscriptionItem> subscriptions, const QString &preferredServerId)
{
    auto selectedServerId = preferredServerId;
    if (selectedServerId.isEmpty()) {
        if (const auto *server = selectedServer()) {
            selectedServerId = server->id;
        }
    }

    beginResetModel();
    m_subscriptions = std::move(subscriptions);

    auto hasSelection = false;
    for (auto &subscription : m_subscriptions) {
        if (subscription.id.isEmpty()) {
            subscription.id = "subscription-" + QString::number(qHash(subscription.name));
        }
        for (auto &server : subscription.servers) {
            server.subscriptionId = subscription.id;
            if (server.id.isEmpty()) {
                server.id = subscription.id + "-" + server.name;
            }
            server.selected = !selectedServerId.isEmpty() && server.id == selectedServerId;
            hasSelection = hasSelection || server.selected;
        }
    }

    if (!hasSelection) {
        for (auto &subscription : m_subscriptions) {
            if (!subscription.servers.isEmpty()) {
                const auto preferred = std::min<qsizetype>(2, subscription.servers.size() - 1);
                subscription.servers[preferred].selected = true;
                break;
            }
        }
    }

    rebuildRows();
    endResetModel();
}

void ServerListModel::setServers(QVector<ServerItem> servers)
{
    SubscriptionItem subscription;
    subscription.id = "local-samhain";
    subscription.name = "Samhain Security";
    subscription.meta = "Локальный профиль";
    subscription.expanded = true;
    subscription.servers = std::move(servers);
    setSubscriptions({subscription});
}

void ServerListModel::selectRow(int row)
{
    if (row < 0 || row >= m_rows.size() || m_rows.at(row).isSubscription) {
        return;
    }

    const auto &targetRow = m_rows.at(row);
    auto &targetServer = m_subscriptions[targetRow.subscriptionIndex].servers[targetRow.serverIndex];
    if (targetServer.selected) {
        return;
    }

    const auto oldRow = selectedRow();
    clearSelection();
    targetServer.selected = true;

    if (oldRow >= 0) {
        emit dataChanged(index(oldRow, 0), index(oldRow, 0), {SelectedRole});
    }
    emit dataChanged(index(row, 0), index(row, 0), {SelectedRole});
}

void ServerListModel::setPing(int row, const QString &ping)
{
    if (row < 0 || row >= m_rows.size() || m_rows.at(row).isSubscription) {
        return;
    }

    const auto visibleRow = m_rows.at(row);
    auto &server = m_subscriptions[visibleRow.subscriptionIndex].servers[visibleRow.serverIndex];
    server.ping = ping;
    emit dataChanged(index(row, 0), index(row, 0), {PingRole});
}

void ServerListModel::setPingByServerId(const QString &serverId, const QString &ping)
{
    if (serverId.isEmpty()) {
        return;
    }

    for (auto &subscription : m_subscriptions) {
        for (auto &server : subscription.servers) {
            if (server.id == serverId) {
                server.ping = ping;
                const auto visibleRow = visibleRowForServer(serverId);
                if (visibleRow >= 0) {
                    emit dataChanged(index(visibleRow, 0), index(visibleRow, 0), {PingRole});
                }
                return;
            }
        }
    }
}

void ServerListModel::toggleSubscription(int row)
{
    if (row < 0 || row >= m_rows.size() || !m_rows.at(row).isSubscription) {
        return;
    }

    const auto subscriptionIndex = m_rows.at(row).subscriptionIndex;
    if (subscriptionIndex < 0 || subscriptionIndex >= m_subscriptions.size()) {
        return;
    }

    beginResetModel();
    m_subscriptions[subscriptionIndex].expanded = !m_subscriptions[subscriptionIndex].expanded;
    rebuildRows();
    endResetModel();
}

bool ServerListModel::isSubscriptionRow(int row) const
{
    return row >= 0 && row < m_rows.size() && m_rows.at(row).isSubscription;
}

QString ServerListModel::subscriptionIdAtRow(int row) const
{
    if (row < 0 || row >= m_rows.size()) {
        return {};
    }

    const auto subscriptionIndex = m_rows.at(row).subscriptionIndex;
    if (subscriptionIndex < 0 || subscriptionIndex >= m_subscriptions.size()) {
        return {};
    }

    return m_subscriptions.at(subscriptionIndex).id;
}

QString ServerListModel::subscriptionNameAtRow(int row) const
{
    if (row < 0 || row >= m_rows.size()) {
        return {};
    }

    const auto subscriptionIndex = m_rows.at(row).subscriptionIndex;
    if (subscriptionIndex < 0 || subscriptionIndex >= m_subscriptions.size()) {
        return {};
    }

    return m_subscriptions.at(subscriptionIndex).name;
}

int ServerListModel::serverCountAtRow(int row) const
{
    if (row < 0 || row >= m_rows.size()) {
        return 0;
    }

    const auto subscriptionIndex = m_rows.at(row).subscriptionIndex;
    if (subscriptionIndex < 0 || subscriptionIndex >= m_subscriptions.size()) {
        return 0;
    }

    return static_cast<int>(m_subscriptions.at(subscriptionIndex).servers.size());
}

QVector<QString> ServerListModel::serverIds() const
{
    QVector<QString> ids;
    for (const auto &subscription : m_subscriptions) {
        for (const auto &server : subscription.servers) {
            if (!server.id.isEmpty()) {
                ids.push_back(server.id);
            }
        }
    }
    return ids;
}

const ServerItem *ServerListModel::selectedServer() const
{
    for (const auto &subscription : m_subscriptions) {
        for (const auto &server : subscription.servers) {
            if (server.selected) {
                return &server;
            }
        }
    }

    return nullptr;
}

const SubscriptionItem *ServerListModel::selectedSubscription() const
{
    const auto *server = selectedServer();
    if (!server) {
        return m_subscriptions.isEmpty() ? nullptr : &m_subscriptions.first();
    }

    for (const auto &subscription : m_subscriptions) {
        if (subscription.id == server->subscriptionId) {
            return &subscription;
        }
    }

    return nullptr;
}

const QVector<SubscriptionItem> &ServerListModel::subscriptions() const
{
    return m_subscriptions;
}

int ServerListModel::selectedRow() const
{
    const auto *server = selectedServer();
    if (!server) {
        return -1;
    }

    return visibleRowForServer(server->id);
}

void ServerListModel::rebuildRows()
{
    m_rows.clear();
    for (int subscriptionIndex = 0; subscriptionIndex < m_subscriptions.size(); ++subscriptionIndex) {
        m_rows.push_back({true, subscriptionIndex, -1});
        const auto &subscription = m_subscriptions.at(subscriptionIndex);
        if (!subscription.expanded) {
            continue;
        }

        for (int serverIndex = 0; serverIndex < subscription.servers.size(); ++serverIndex) {
            m_rows.push_back({false, subscriptionIndex, serverIndex});
        }
    }
}

int ServerListModel::visibleRowForServer(const QString &serverId) const
{
    if (serverId.isEmpty()) {
        return -1;
    }

    for (int row = 0; row < m_rows.size(); ++row) {
        const auto &visibleRow = m_rows.at(row);
        if (visibleRow.isSubscription) {
            continue;
        }
        const auto &server = m_subscriptions
                                 .at(visibleRow.subscriptionIndex)
                                 .servers
                                 .at(visibleRow.serverIndex);
        if (server.id == serverId) {
            return row;
        }
    }

    return -1;
}

void ServerListModel::clearSelection()
{
    for (auto &subscription : m_subscriptions) {
        for (auto &server : subscription.servers) {
            server.selected = false;
        }
    }
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

    connect(&m_probeTimer, &QTimer::timeout, this, &AppController::testAllPings);
    m_probeTimer.setInterval(5 * 60 * 1000);
    m_probeTimer.start();

    if (!loadStateFromService()) {
        loadState();
        appendLog("Сервис: локальный режим интерфейса");
    } else {
        appendLog("Сервис: состояние получено через IPC");
    }
    updateSelectedServerProperties();
    QTimer::singleShot(1200, this, &AppController::testAllPings);
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

QString AppController::engineStatus() const
{
    return m_engineStatus;
}

QString AppController::engineDetail() const
{
    return m_engineDetail;
}

QString AppController::engineConfigPreview() const
{
    return m_engineConfigPreview;
}

QStringList AppController::engineCatalog() const
{
    return m_engineCatalog;
}

QString AppController::proxyStatus() const
{
    return m_proxyStatus;
}

QString AppController::proxyDetail() const
{
    return m_proxyDetail;
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
    if (m_serverModel.isSubscriptionRow(row)) {
        toggleSubscription(row);
        return;
    }

    m_serverModel.selectRow(row);
    updateSelectedServerProperties();

    if (const auto *server = m_serverModel.selectedServer()) {
        QJsonObject command;
        command["type"] = "select-server";
        command["server_id"] = server->id;
        requestService(command, IpcRequestTimeoutMs);
    }

    saveState();
    appendLog("Выбран сервер: " + m_selectedServerName);
}

void AppController::toggleSubscription(int row)
{
    m_serverModel.toggleSubscription(row);
    saveState();
}

void AppController::toggleConnection()
{
    const auto *server = m_serverModel.selectedServer();
    if (!server) {
        m_statusText = "Выберите сервер";
        emit statusChanged();
        return;
    }

    QJsonObject command;
    if (m_connected) {
        command["type"] = "disconnect";
    } else {
        command["type"] = "connect";
        command["server_id"] = server->id;
        command["route_mode"] = routeModeWireValue();
    }

    const auto response = requestService(command, IpcEngineTimeoutMs);
    if (!response.isEmpty()) {
        const auto document = QJsonDocument::fromJson(response.toUtf8());
        const auto root = document.object();
        const auto event = root.value("event").toObject();
        if (!root.value("ok").toBool(false) || event.value("type").toString() == "error") {
            const auto message = event.value("message").toString("Команда не выполнена");
            m_statusText = message;
            appendLog("Сервис: " + message);
            emit statusChanged();
            return;
        }

        if (applyEngineStatusEvent(event)) {
            const auto engineReady = m_engineStatus == "Запущен";
            if (!m_connected && !engineReady) {
                m_statusText = m_engineDetail;
                emit statusChanged();
                emit engineChanged();
                return;
            }
            refreshProxyStatus();
            appendLog("Сервис: состояние движка обновлено");
        }
    } else {
        appendLog("Сервис: недоступен, локальный режим интерфейса");
    }

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
    emit proxyChanged();
}

void AppController::testPing()
{
    const auto row = m_serverModel.selectedRow();
    const auto *server = m_serverModel.selectedServer();
    if (row < 0) {
        m_statusText = "Раскройте подписку с выбранным сервером";
        emit statusChanged();
        return;
    }

    const auto serverId = server ? server->id : QString();
    const auto serverName = server ? server->name : m_selectedServerName;
    QJsonObject command;
    command["type"] = "test-ping";
    command["server_id"] = serverId;
    const auto response = requestService(command, IpcRequestTimeoutMs);

    m_serverModel.setPing(row, "...");
    if (!response.isEmpty()) {
        const auto document = QJsonDocument::fromJson(response.toUtf8());
        const auto root = document.object();
        const auto event = root.value("event").toObject();
        if (root.value("ok").toBool(false) && applyPingEvent(event)) {
            updateSelectedServerProperties();
            saveState();
            appendLog("Пинг: " + serverName + " - " + m_selectedServerPing);
            return;
        }
    }

    QTimer::singleShot(350, this, [this, serverId, serverName]() {
        const auto ping = fallbackPingLabel(serverId);
        m_serverModel.setPingByServerId(serverId, ping);
        updateSelectedServerProperties();
        saveState();
        appendLog("Пинг: " + serverName + " - " + ping);
    });
}

void AppController::testAllPings()
{
    const auto serverIds = m_serverModel.serverIds();
    if (serverIds.isEmpty()) {
        return;
    }

    QJsonArray ids;
    for (const auto &serverId : serverIds) {
        ids.push_back(serverId);
        m_serverModel.setPingByServerId(serverId, "...");
    }

    QJsonObject command;
    command["type"] = "test-pings";
    command["server_ids"] = ids;
    const auto response = requestService(command, IpcRequestTimeoutMs);

    if (!response.isEmpty()) {
        const auto document = QJsonDocument::fromJson(response.toUtf8());
        const auto root = document.object();
        const auto event = root.value("event").toObject();
        if (root.value("ok").toBool(false) && applyPingEvent(event)) {
            updateSelectedServerProperties();
            saveState();
            m_statusText = "Проверка задержки завершена";
            emit statusChanged();
            appendLog("Пинг: проверены серверы");
            return;
        }
    }

    QTimer::singleShot(350, this, [this, serverIds]() {
        for (const auto &serverId : serverIds) {
            m_serverModel.setPingByServerId(serverId, fallbackPingLabel(serverId));
        }
        updateSelectedServerProperties();
        saveState();
        m_statusText = "Проверка задержки завершена локально";
        emit statusChanged();
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
    const auto normalizedName = name.trimmed().isEmpty() ? "Samhain Security" : name.trimmed();
    const auto normalizedUrl = url.trimmed();
    if (normalizedUrl.isEmpty()) {
        m_statusText = "Введите ссылку подписки";
        emit statusChanged();
        return;
    }

    QJsonObject command;
    command["type"] = "add-subscription";
    command["name"] = normalizedName;
    command["url"] = normalizedUrl;
    const auto response = requestService(command, IpcRequestTimeoutMs);

    m_subscriptionName = normalizedName;
    m_subscriptionMeta = QDateTime::currentDateTime().toString("dd.MM.yyyy HH:mm")
        + " | Автообновление - 24ч.";

    bool appliedServiceSubscription = false;
    if (!response.isEmpty()) {
        const auto document = QJsonDocument::fromJson(response.toUtf8());
        const auto root = document.object();
        const auto event = root.value("event").toObject();
        if (!root.value("ok").toBool(false) || event.value("type").toString() == "error") {
            const auto message = event.value("message").toString("Не удалось добавить подписку");
            m_statusText = message;
            appendLog("Сервис: " + message);
        } else if (event.value("type").toString() == "subscription-added") {
            appliedServiceSubscription = loadStateFromService();
        }
    }

    if (!appliedServiceSubscription) {
        auto subscription = buildLocalSubscription(
            "local-" + QString::number(QDateTime::currentMSecsSinceEpoch()),
            m_subscriptionName,
            m_subscriptionMeta,
            buildServersForUrl(normalizedUrl));
        auto subscriptions = m_serverModel.subscriptions();
        subscriptions.erase(
            std::remove_if(
                subscriptions.begin(),
                subscriptions.end(),
                [](const SubscriptionItem &item) {
                    return item.id == "default-samhain" || item.id == "local-samhain";
                }),
            subscriptions.end());
        const auto preferredServerId = subscription.servers.isEmpty()
            ? QString()
            : subscription.servers.first().id;
        subscriptions.push_back(std::move(subscription));
        m_serverModel.setSubscriptions(subscriptions, preferredServerId);
    }

    updateSelectedServerProperties();
    saveState();
    appendLog("Добавлена подписка: " + m_subscriptionName);
    emit subscriptionChanged();
}

void AppController::refreshSubscription(int row)
{
    const auto subscriptionId = m_serverModel.subscriptionIdAtRow(row);
    if (subscriptionId.isEmpty()) {
        return;
    }

    QJsonObject command;
    command["type"] = "refresh-subscription";
    command["subscription_id"] = subscriptionId;
    const auto response = requestService(command, IpcRequestTimeoutMs);
    if (response.isEmpty()) {
        m_statusText = "Сервис недоступен для обновления";
        emit statusChanged();
        return;
    }

    const auto document = QJsonDocument::fromJson(response.toUtf8());
    const auto root = document.object();
    const auto event = root.value("event").toObject();
    if (!root.value("ok").toBool(false) || event.value("type").toString() == "error") {
        const auto message = event.value("message").toString("Не удалось обновить подписку");
        m_statusText = message;
        appendLog("Сервис: " + message);
    } else {
        loadStateFromService();
        m_statusText = "Подписка обновлена";
        appendLog("Обновлена подписка: " + m_serverModel.subscriptionNameAtRow(row));
    }
    updateSelectedServerProperties();
    emit statusChanged();
}

void AppController::renameSubscription(int row, const QString &name)
{
    const auto subscriptionId = m_serverModel.subscriptionIdAtRow(row);
    const auto normalizedName = name.trimmed();
    if (subscriptionId.isEmpty() || normalizedName.isEmpty()) {
        return;
    }

    QJsonObject command;
    command["type"] = "rename-subscription";
    command["subscription_id"] = subscriptionId;
    command["name"] = normalizedName;
    const auto response = requestService(command, IpcRequestTimeoutMs);
    if (response.isEmpty()) {
        m_statusText = "Сервис недоступен для переименования";
        emit statusChanged();
        return;
    }

    const auto document = QJsonDocument::fromJson(response.toUtf8());
    const auto root = document.object();
    const auto event = root.value("event").toObject();
    if (!root.value("ok").toBool(false) || event.value("type").toString() == "error") {
        const auto message = event.value("message").toString("Не удалось переименовать подписку");
        m_statusText = message;
        appendLog("Сервис: " + message);
    } else {
        loadStateFromService();
        m_statusText = "Подписка переименована";
        appendLog("Подписка переименована: " + normalizedName);
    }
    updateSelectedServerProperties();
    emit statusChanged();
}

void AppController::deleteSubscription(int row)
{
    const auto subscriptionId = m_serverModel.subscriptionIdAtRow(row);
    const auto subscriptionName = m_serverModel.subscriptionNameAtRow(row);
    if (subscriptionId.isEmpty()) {
        return;
    }

    QJsonObject command;
    command["type"] = "delete-subscription";
    command["subscription_id"] = subscriptionId;
    const auto response = requestService(command, IpcRequestTimeoutMs);
    if (response.isEmpty()) {
        m_statusText = "Сервис недоступен для удаления";
        emit statusChanged();
        return;
    }

    const auto document = QJsonDocument::fromJson(response.toUtf8());
    const auto root = document.object();
    const auto event = root.value("event").toObject();
    if (!root.value("ok").toBool(false) || event.value("type").toString() == "error") {
        const auto message = event.value("message").toString("Не удалось удалить подписку");
        m_statusText = message;
        appendLog("Сервис: " + message);
    } else {
        loadStateFromService();
        updateSelectedServerProperties();
        saveState();
        m_statusText = "Подписка удалена";
        appendLog("Удалена подписка: " + subscriptionName);
    }
    emit statusChanged();
}

void AppController::copySubscriptionDiagnostics(int row)
{
    const auto subscriptionName = m_serverModel.subscriptionNameAtRow(row);
    if (subscriptionName.isEmpty()) {
        return;
    }

    const auto text = QString("Samhain Security\nПодписка: %1\nСерверов: %2\nСтатус: %3")
        .arg(subscriptionName)
        .arg(m_serverModel.serverCountAtRow(row))
        .arg(m_statusText);
    QGuiApplication::clipboard()->setText(text);
    m_statusText = "Диагностика скопирована";
    appendLog("Скопирована диагностика подписки: " + subscriptionName);
    emit statusChanged();
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

void AppController::refreshEngineStatus()
{
    QJsonObject command;
    command["type"] = "get-engine-status";
    const auto response = requestService(command, IpcEngineTimeoutMs);
    if (response.isEmpty()) {
        m_engineStatus = "Сервис недоступен";
        m_engineDetail = "Запустите службу, чтобы увидеть состояние движка.";
        appendLog("Движок: служба недоступна");
        emit engineChanged();
        return;
    }

    const auto document = QJsonDocument::fromJson(response.toUtf8());
    const auto root = document.object();
    const auto event = root.value("event").toObject();
    if (!root.value("ok").toBool(false) || !applyEngineStatusEvent(event)) {
        m_engineStatus = "Неизвестно";
        m_engineDetail = event.value("message").toString("Состояние движка не получено");
    }
    emit engineChanged();
}

void AppController::previewSelectedEngineConfig()
{
    const auto *server = m_serverModel.selectedServer();
    if (!server) {
        m_engineConfigPreview = "Выберите сервер.";
        emit engineChanged();
        return;
    }

    QJsonObject command;
    command["type"] = "preview-engine-config";
    command["server_id"] = server->id;
    const auto response = requestService(command, IpcEngineTimeoutMs);
    if (response.isEmpty()) {
        m_engineConfigPreview = "Служба недоступна для подготовки конфигурации.";
        appendLog("Движок: preview недоступен");
        emit engineChanged();
        return;
    }

    const auto document = QJsonDocument::fromJson(response.toUtf8());
    const auto root = document.object();
    const auto event = root.value("event").toObject();
    if (!root.value("ok").toBool(false) || event.value("type").toString() != "engine-config-preview") {
        m_engineConfigPreview = event.value("message").toString("Конфигурация не подготовлена");
        emit engineChanged();
        return;
    }

    const auto preview = event.value("preview").toObject();
    m_engineConfigPreview = preview.value("redacted_config").toString();
    const auto warnings = preview.value("warnings").toArray();
    if (!warnings.isEmpty()) {
        QStringList warningLines;
        for (const auto warning : warnings) {
            warningLines.push_back(warning.toString());
        }
        m_engineConfigPreview += "\n\n# " + warningLines.join("\n# ");
    }
    appendLog("Движок: конфигурация подготовлена без секретов");
    emit engineChanged();
}

void AppController::restartEngine()
{
    const auto *server = m_serverModel.selectedServer();
    if (!server) {
        m_statusText = "Выберите сервер";
        emit statusChanged();
        return;
    }

    QJsonObject command;
    command["type"] = "restart-engine";
    command["server_id"] = server->id;
    command["route_mode"] = routeModeWireValue();
    const auto response = requestService(command, IpcEngineTimeoutMs);
    if (response.isEmpty()) {
        m_statusText = "Сервис недоступен";
        emit statusChanged();
        return;
    }

    const auto document = QJsonDocument::fromJson(response.toUtf8());
    const auto event = document.object().value("event").toObject();
    applyEngineStatusEvent(event);
    m_statusText = m_engineDetail;
    appendLog("Движок: перезапуск");
    emit statusChanged();
    emit engineChanged();
}

void AppController::stopEngine()
{
    QJsonObject command;
    command["type"] = "stop-engine";
    const auto response = requestService(command, IpcEngineTimeoutMs);
    if (response.isEmpty()) {
        m_statusText = "Сервис недоступен";
        emit statusChanged();
        return;
    }

    const auto document = QJsonDocument::fromJson(response.toUtf8());
    const auto event = document.object().value("event").toObject();
    applyEngineStatusEvent(event);
    refreshProxyStatus();
    m_connected = false;
    m_statsTimer.stop();
    m_statusText = m_engineDetail;
    emit connectionChanged();
    emit statusChanged();
    emit engineChanged();
}

void AppController::refreshProxyStatus()
{
    QJsonObject command;
    command["type"] = "get-proxy-status";
    const auto response = requestService(command, IpcEngineTimeoutMs);
    if (response.isEmpty()) {
        m_proxyStatus = "Сервис недоступен";
        m_proxyDetail = "Состояние proxy path не получено";
        emit proxyChanged();
        return;
    }

    const auto document = QJsonDocument::fromJson(response.toUtf8());
    const auto root = document.object();
    const auto event = root.value("event").toObject();
    if (!root.value("ok").toBool(false) || !applyProxyStatusEvent(event)) {
        m_proxyStatus = "Неизвестно";
        m_proxyDetail = event.value("message").toString("Состояние proxy path не получено");
    }
    emit proxyChanged();
}

void AppController::restoreProxyPolicy()
{
    QJsonObject command;
    command["type"] = "restore-proxy-policy";
    const auto response = requestService(command, IpcEngineTimeoutMs);
    if (response.isEmpty()) {
        m_proxyStatus = "Сервис недоступен";
        m_proxyDetail = "Восстановление недоступно";
        emit proxyChanged();
        return;
    }

    const auto document = QJsonDocument::fromJson(response.toUtf8());
    const auto root = document.object();
    const auto event = root.value("event").toObject();
    if (!root.value("ok").toBool(false) || !applyProxyStatusEvent(event)) {
        m_proxyStatus = "Ошибка";
        m_proxyDetail = event.value("message").toString("Proxy path не восстановлен");
    } else {
        appendLog("Proxy path: выполнено восстановление");
    }
    emit proxyChanged();
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
    m_routeModeIndex = object.value("routeMode").toInt(0);

    QVector<SubscriptionItem> subscriptions;
    const auto subscriptionValues = object.value("subscriptions").toArray();
    for (const auto subscriptionValue : subscriptionValues) {
        const auto subscriptionObject = subscriptionValue.toObject();
        QVector<ServerItem> servers;
        for (const auto value : subscriptionObject.value("servers").toArray()) {
            const auto item = value.toObject();
            servers.push_back({
                item.value("id").toString(),
                subscriptionObject.value("id").toString(),
                item.value("name").toString(),
                item.value("flag").toString(),
                item.value("protocol").toString(),
                item.value("endpoint").toString(),
                item.value("ping").toString("n/a"),
                item.value("selected").toBool(false),
            });
        }
        subscriptions.push_back({
            subscriptionObject.value("id").toString(),
            subscriptionObject.value("name").toString("Samhain Security"),
            subscriptionObject.value("meta").toString("Локальный профиль"),
            subscriptionObject.value("expanded").toBool(true),
            servers,
        });
    }

    if (subscriptions.isEmpty()) {
        m_subscriptionName = object.value("name").toString("Samhain Security");
        m_subscriptionMeta = object.value("meta").toString("27.04.2026 23:22 | Автообновление - 24ч.");
        QVector<ServerItem> servers;
        for (const auto value : object.value("servers").toArray()) {
            const auto item = value.toObject();
            servers.push_back({
                item.value("id").toString(),
                "local-samhain",
                item.value("name").toString(),
                item.value("flag").toString(),
                item.value("protocol").toString(),
                item.value("endpoint").toString(),
                item.value("ping").toString("n/a"),
                item.value("selected").toBool(false),
            });
        }
        if (!servers.isEmpty()) {
            subscriptions.push_back(buildLocalSubscription(
                "local-samhain",
                m_subscriptionName,
                m_subscriptionMeta,
                servers));
        }
    }

    if (subscriptions.isEmpty()) {
        loadSampleSubscription();
    } else {
        m_serverModel.setSubscriptions(subscriptions, object.value("selectedServerId").toString());
    }
}

bool AppController::loadStateFromService()
{
    QJsonObject command;
    command["type"] = "get-state";
    const auto response = requestService(command, IpcRequestTimeoutMs);
    if (response.isEmpty()) {
        return false;
    }

    const auto document = QJsonDocument::fromJson(response.toUtf8());
    const auto root = document.object();
    if (!root.value("ok").toBool(false)) {
        const auto error = root.value("event").toObject().value("message").toString();
        if (!error.isEmpty()) {
            appendLog("Сервис: " + error);
        }
        return false;
    }

    const auto event = root.value("event").toObject();
    if (event.value("type").toString() != "state") {
        return false;
    }

    return applyServiceState(event);
}

bool AppController::applyServiceState(const QJsonObject &state)
{
    const auto subscriptions = state.value("subscriptions").toArray();
    QVector<SubscriptionItem> items;
    items.reserve(subscriptions.size());

    for (const auto subscriptionValue : subscriptions) {
        const auto subscription = subscriptionValue.toObject();
        const auto subscriptionId = subscription.value("id").toString();
        const auto serverValues = subscription.value("servers").toArray();
        QVector<ServerItem> servers;
        servers.reserve(serverValues.size());
        for (const auto value : serverValues) {
            const auto server = value.toObject();
            const auto host = server.value("host").toString();
            const auto portValue = server.value("port");
            auto endpoint = host;
            if (!portValue.isNull() && !portValue.isUndefined()) {
                endpoint += ":" + QString::number(portValue.toInt());
            }

            const auto pingValue = server.value("ping_ms");
            servers.push_back({
                server.value("id").toString(),
                subscriptionId,
                server.value("name").toString("Samhain Security"),
                flagForCountry(server.value("country_code").toString()),
                protocolLabel(server.value("protocol").toString()),
                endpoint,
                pingValue.isNull() || pingValue.isUndefined() ? "n/a" : QString::number(pingValue.toInt()) + "ms",
                false,
            });
        }

        items.push_back({
            subscriptionId,
            subscription.value("name").toString("Samhain Security"),
            subscription.value("updated_at").toString("Сервис готов"),
            true,
            servers,
        });
    }

    m_routeModeIndex = routeModeIndexFromWire(state.value("route_mode").toString("whole-computer"));
    applyEngineStateObject(state.value("engine_state").toObject());
    applyEngineCatalogArray(state.value("engine_catalog").toArray());
    applyProxyStateObject(state.value("proxy_state").toObject());
    m_connected = !state.value("connected_server_id").toString().isEmpty()
        && m_engineStatus == "Запущен";
    m_serverModel.setSubscriptions(items, state.value("selected_server_id").toString());
    if (const auto *subscription = m_serverModel.selectedSubscription()) {
        m_subscriptionName = subscription->name;
        m_subscriptionMeta = subscription->meta;
    }
    m_statusText = "Готово";
    emit subscriptionChanged();
    emit routeModeChanged();
    emit connectionChanged();
    emit engineChanged();
    emit proxyChanged();
    emit statusChanged();
    return true;
}

void AppController::saveState() const
{
    QJsonArray subscriptions;
    for (const auto &subscription : m_serverModel.subscriptions()) {
        QJsonArray servers;
        for (const auto &server : subscription.servers) {
            QJsonObject item;
            item["id"] = server.id;
            item["name"] = server.name;
            item["flag"] = server.flag;
            item["protocol"] = server.protocol;
            item["endpoint"] = server.endpoint;
            item["ping"] = server.ping;
            item["selected"] = server.selected;
            servers.push_back(item);
        }

        QJsonObject subscriptionObject;
        subscriptionObject["id"] = subscription.id;
        subscriptionObject["name"] = subscription.name;
        subscriptionObject["meta"] = subscription.meta;
        subscriptionObject["expanded"] = subscription.expanded;
        subscriptionObject["servers"] = servers;
        subscriptions.push_back(subscriptionObject);
    }

    QJsonObject root;
    root["name"] = m_subscriptionName;
    root["meta"] = m_subscriptionMeta;
    root["routeMode"] = m_routeModeIndex;
    root["selectedServerId"] = m_serverModel.selectedServer() ? m_serverModel.selectedServer()->id : "";
    root["subscriptions"] = subscriptions;

    const auto path = stateFilePath();
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    if (file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        file.write(QJsonDocument(root).toJson(QJsonDocument::Indented));
    }
}

void AppController::loadSampleSubscription()
{
    auto subscription = buildLocalSubscription(
        "default-samhain",
        "Samhain Security",
        "27.04.2026 23:22 | Автообновление - 24ч.",
        {
            {"server-1", "default-samhain", "Samhain GB London #1", "🇬🇧", "VLESS / TCP / REALITY", "gb-london-1.samhain", "1277ms", false},
            {"server-2", "default-samhain", "Samhain GB London #2", "🇬🇧", "VLESS / TCP / REALITY", "gb-london-2.samhain", "1189ms", false},
            {"server-3", "default-samhain", "Samhain NL Amsterdam #3", "🇳🇱", "VLESS / TCP / REALITY", "nl-amsterdam-3.samhain", "360ms", true},
            {"server-4", "default-samhain", "Samhain SE Evle #4", "🇸🇪", "Trojan", "se-evle-4.samhain", "248ms", false},
            {"server-5", "default-samhain", "Samhain SE Evle #5", "🇸🇪", "Shadowsocks", "se-evle-5.samhain", "251ms", false},
            {"server-6", "default-samhain", "Samhain DE Frankfurt #6", "🇩🇪", "AmneziaWG", "de-frankfurt-6.samhain", "n/a", false},
            {"server-7", "default-samhain", "Samhain DE Frankfurt #7", "🇩🇪", "Hysteria2", "de-frankfurt-7.samhain", "n/a", false},
        });
    m_serverModel.setSubscriptions({subscription}, "server-3");
    m_subscriptionName = subscription.name;
    m_subscriptionMeta = subscription.meta;
}

QString AppController::requestService(const QJsonObject &command, int timeoutMs) const
{
#ifdef Q_OS_WIN
    if (!WaitNamedPipeW(IpcPipeName, static_cast<DWORD>(timeoutMs))) {
        return {};
    }

    const auto pipe = CreateFileW(
        IpcPipeName,
        GENERIC_READ | GENERIC_WRITE,
        0,
        nullptr,
        OPEN_EXISTING,
        0,
        nullptr);

    if (pipe == INVALID_HANDLE_VALUE) {
        return {};
    }

    DWORD mode = PIPE_READMODE_MESSAGE;
    SetNamedPipeHandleState(pipe, &mode, nullptr, nullptr);

    QJsonObject envelope;
    envelope["protocol_version"] = IpcProtocolVersion;
    envelope["request_id"] = QString("desktop-%1").arg(QDateTime::currentMSecsSinceEpoch());
    envelope["command"] = command;

    const auto payload = QJsonDocument(envelope).toJson(QJsonDocument::Compact);
    DWORD written = 0;
    const auto writeOk = WriteFile(
        pipe,
        payload.constData(),
        static_cast<DWORD>(payload.size()),
        &written,
        nullptr);

    if (!writeOk) {
        CloseHandle(pipe);
        return {};
    }

    QByteArray buffer(64 * 1024, Qt::Uninitialized);
    DWORD read = 0;
    const auto readOk = ReadFile(
        pipe,
        buffer.data(),
        static_cast<DWORD>(buffer.size()),
        &read,
        nullptr);

    CloseHandle(pipe);

    if (!readOk || read == 0) {
        return {};
    }

    buffer.truncate(static_cast<qsizetype>(read));
    return QString::fromUtf8(buffer);
#else
    Q_UNUSED(command)
    Q_UNUSED(timeoutMs)
    return {};
#endif
}

QString AppController::protocolLabel(const QString &wireProtocol) const
{
    if (wireProtocol == "vless-reality") {
        return "VLESS / TCP / REALITY";
    }
    if (wireProtocol == "amnezia-wg") {
        return "AmneziaWG";
    }
    if (wireProtocol == "wire-guard") {
        return "WireGuard";
    }
    if (wireProtocol == "shadowsocks") {
        return "Shadowsocks";
    }
    if (wireProtocol == "hysteria2") {
        return "Hysteria2";
    }
    if (wireProtocol == "tuic") {
        return "TUIC";
    }
    if (wireProtocol == "trojan") {
        return "Trojan";
    }
    return "Unknown";
}

QString AppController::flagForCountry(const QString &countryCode) const
{
    const auto code = countryCode.toUpper();
    if (code == "GB") {
        return "🇬🇧";
    }
    if (code == "NL") {
        return "🇳🇱";
    }
    if (code == "DE") {
        return "🇩🇪";
    }
    if (code == "SE") {
        return "🇸🇪";
    }
    if (code == "US") {
        return "🇺🇸";
    }
    return "◉";
}

QString AppController::routeModeWireValue() const
{
    switch (m_routeModeIndex) {
    case 1:
        return "selected-apps-only";
    case 2:
        return "exclude-selected-apps";
    default:
        return "whole-computer";
    }
}

int AppController::routeModeIndexFromWire(const QString &routeMode) const
{
    if (routeMode == "selected-apps-only") {
        return 1;
    }
    if (routeMode == "exclude-selected-apps") {
        return 2;
    }
    return 0;
}

bool AppController::applyEngineStatusEvent(const QJsonObject &event)
{
    const auto type = event.value("type").toString();
    if (type == "engine-status") {
        applyEngineStateObject(event.value("state").toObject());
        return true;
    }
    return false;
}

bool AppController::applyProxyStatusEvent(const QJsonObject &event)
{
    const auto type = event.value("type").toString();
    if (type == "proxy-status") {
        applyProxyStateObject(event.value("state").toObject());
        return true;
    }
    return false;
}

void AppController::applyEngineStateObject(const QJsonObject &state)
{
    const auto status = state.value("status").toString("stopped");
    const auto engine = state.value("engine").toString("unknown");
    const auto message = state.value("message").toString();
    const auto pid = state.value("pid");
    const auto serverId = state.value("server_id").toString();

    m_engineStatus = engineStatusLabel(status);
    QStringList detail;
    detail.push_back(engine == "unknown" ? "Движок: не выбран" : "Движок: " + engine);
    if (!serverId.isEmpty()) {
        detail.push_back("Сервер: " + serverId);
    }
    if (!pid.isNull() && !pid.isUndefined()) {
        detail.push_back("PID: " + QString::number(pid.toInt()));
    }
    if (!message.isEmpty()) {
        detail.push_back(message);
    }
    m_engineDetail = detail.join(" · ");

    const auto logs = state.value("log_tail").toArray();
    for (const auto value : logs) {
        const auto entry = value.toObject();
        const auto stream = entry.value("stream").toString("engine");
        const auto line = entry.value("message").toString();
        if (!line.isEmpty()) {
            appendLog("Движок/" + stream + ": " + line);
        }
    }
}

void AppController::applyProxyStateObject(const QJsonObject &state)
{
    const auto status = state.value("status").toString("inactive");
    const auto enabled = state.value("enabled").toBool(false);
    const auto endpoint = state.value("endpoint").toString();
    const auto previousServer = state.value("previous_server").toString();
    const auto message = state.value("message").toString();

    m_proxyStatus = proxyStatusLabel(status, enabled);
    QStringList detail;
    if (!endpoint.isEmpty()) {
        detail.push_back("Текущий: " + endpoint);
    }
    if (!previousServer.isEmpty()) {
        detail.push_back("Предыдущий: " + previousServer);
    }
    if (!message.isEmpty()) {
        detail.push_back(message);
    }
    m_proxyDetail = detail.isEmpty() ? "Системный proxy не изменялся" : detail.join(" · ");
}

void AppController::applyEngineCatalogArray(const QJsonArray &catalog)
{
    QStringList lines;
    for (const auto value : catalog) {
        const auto item = value.toObject();
        const auto name = item.value("name").toString("unknown");
        const auto available = item.value("available").toBool(false);
        const auto path = item.value("executable_path").toString();
        lines.push_back(name + ": " + (available ? "найден" : "не найден")
            + (path.isEmpty() ? QString() : " · " + path));
    }
    m_engineCatalog = lines;
}

QString AppController::engineStatusLabel(const QString &status) const
{
    if (status == "running") {
        return "Запущен";
    }
    if (status == "starting") {
        return "Запускается";
    }
    if (status == "missing") {
        return "Не найден";
    }
    if (status == "crashed") {
        return "Сбой";
    }
    if (status == "adapter-pending") {
        return "Ожидает адаптер";
    }
    return "Остановлен";
}

QString AppController::proxyStatusLabel(const QString &status, bool enabled) const
{
    if (status == "active") {
        return enabled ? "Активен" : "Ожидает";
    }
    if (status == "restored") {
        return "Восстановлен";
    }
    if (status == "error") {
        return "Ошибка";
    }
    return "Не активен";
}

bool AppController::applyPingEvent(const QJsonObject &event)
{
    const auto type = event.value("type").toString();
    if (type == "ping-result") {
        const auto serverId = event.value("server_id").toString();
        if (serverId.isEmpty()) {
            return false;
        }
        m_serverModel.setPingByServerId(serverId, pingLabelFromProbe(event));
        return true;
    }

    if (type == "ping-batch-result") {
        auto applied = false;
        for (const auto value : event.value("results").toArray()) {
            const auto probe = value.toObject();
            const auto serverId = probe.value("server_id").toString();
            if (serverId.isEmpty()) {
                continue;
            }
            m_serverModel.setPingByServerId(serverId, pingLabelFromProbe(probe));
            applied = true;
        }
        return applied;
    }

    return false;
}

QString AppController::pingLabelFromProbe(const QJsonObject &probe) const
{
    const auto pingValue = probe.value("ping_ms");
    if (pingValue.isNull() || pingValue.isUndefined()) {
        return "n/a";
    }

    const auto ping = pingValue.toInt(-1);
    if (ping < 0) {
        return "n/a";
    }
    return QString::number(ping) + "ms";
}

QString AppController::fallbackPingLabel(const QString &serverId) const
{
    const auto checksum = std::accumulate(serverId.begin(), serverId.end(), 0u, [](uint acc, QChar ch) {
        return acc + ch.unicode();
    });
    return QString::number(45 + checksum % 380) + "ms";
}

SubscriptionItem AppController::buildLocalSubscription(
    const QString &id,
    const QString &name,
    const QString &meta,
    QVector<ServerItem> servers) const
{
    SubscriptionItem subscription;
    subscription.id = id;
    subscription.name = name.trimmed().isEmpty() ? "Samhain Security" : name.trimmed();
    subscription.meta = meta.trimmed().isEmpty() ? "Локальный профиль" : meta.trimmed();
    subscription.expanded = true;
    for (int index = 0; index < servers.size(); ++index) {
        auto &server = servers[index];
        server.subscriptionId = subscription.id;
        if (server.id.isEmpty()) {
            server.id = QString("%1-server-%2").arg(subscription.id).arg(index + 1);
        }
    }
    subscription.servers = std::move(servers);
    return subscription;
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
            {"", "", seedName + " импорт #1", "◉", protocol, url.left(42), "n/a", true},
        };
    }

    return {
        {"", "", seedName + " GB London #1", "🇬🇧", "VLESS / TCP / REALITY", "gb-london-1.samhain", "n/a", false},
        {"", "", seedName + " NL Amsterdam #2", "🇳🇱", "VLESS / TCP / REALITY", "nl-amsterdam-2.samhain", "n/a", true},
        {"", "", seedName + " DE Frankfurt #3", "🇩🇪", "AmneziaWG", "de-frankfurt-3.samhain", "n/a", false},
        {"", "", seedName + " SE Evle #4", "🇸🇪", "Trojan", "se-evle-4.samhain", "n/a", false},
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
        m_selectedServerName = "Сервер не выбран";
        m_selectedServerFlag = "◉";
        m_selectedServerProtocol = "";
        m_selectedServerPing = "";
        emit selectedServerChanged();
        return;
    }

    m_selectedServerName = server->name;
    m_selectedServerFlag = server->flag;
    m_selectedServerProtocol = server->protocol;
    m_selectedServerPing = server->ping;
    if (const auto *subscription = m_serverModel.selectedSubscription()) {
        m_subscriptionName = subscription->name;
        m_subscriptionMeta = subscription->meta;
        emit subscriptionChanged();
    }
    emit selectedServerChanged();
}

QString AppController::stateFilePath() const
{
    const auto appData = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    return QDir(appData).filePath("subscriptions.json");
}
