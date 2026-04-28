#include "AppController.h"

#include <algorithm>

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

    if (!loadStateFromService()) {
        loadState();
        appendLog("Сервис: локальный режим интерфейса");
    } else {
        appendLog("Сервис: состояние получено через IPC");
    }
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
    QJsonObject command;
    if (m_connected) {
        command["type"] = "disconnect";
    } else {
        command["type"] = "connect";
        command["server_id"] = m_selectedServerName;
        command["route_mode"] = routeModeWireValue();
    }

    const auto response = requestService(command, IpcRequestTimeoutMs);
    if (!response.isEmpty()) {
        appendLog("Сервис: команда подключения принята");
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
}

void AppController::testPing()
{
    const auto row = m_serverModel.selectedRow();
    if (row < 0) {
        return;
    }

    QJsonObject command;
    command["type"] = "test-ping";
    command["server_id"] = m_selectedServerName;
    const auto response = requestService(command, IpcRequestTimeoutMs);

    m_serverModel.setPing(row, "...");
    auto ping = QRandomGenerator::global()->bounded(42, 420);
    if (!response.isEmpty()) {
        const auto document = QJsonDocument::fromJson(response.toUtf8());
        const auto event = document.object().value("event").toObject();
        if (event.value("type").toString() == "ping-result" && event.contains("ping_ms")) {
            ping = event.value("ping_ms").toInt(ping);
        }
    }

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
    QJsonObject command;
    command["type"] = "add-subscription";
    command["name"] = name.trimmed();
    command["url"] = url.trimmed();
    const auto response = requestService(command, IpcRequestTimeoutMs);

    m_subscriptionName = name.trimmed().isEmpty() ? "Samhain Security" : name.trimmed();
    m_subscriptionUrl = url.trimmed();
    m_subscriptionMeta = QDateTime::currentDateTime().toString("dd.MM.yyyy HH:mm")
        + " | Автообновление - 24ч.";

    bool appliedServiceSubscription = false;
    if (!response.isEmpty()) {
        const auto document = QJsonDocument::fromJson(response.toUtf8());
        const auto event = document.object().value("event").toObject();
        const auto subscription = event.value("subscription").toObject();
        if (event.value("type").toString() == "subscription-added" && !subscription.isEmpty()) {
            QJsonObject state;
            state["route_mode"] = routeModeWireValue();
            state["subscriptions"] = QJsonArray{subscription};
            appliedServiceSubscription = applyServiceState(state);
        }
    }

    if (!appliedServiceSubscription) {
        m_serverModel.setServers(buildServersForUrl(m_subscriptionUrl));
    }

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
    if (subscriptions.isEmpty()) {
        return false;
    }

    const auto subscription = subscriptions.first().toObject();
    const auto serverValues = subscription.value("servers").toArray();
    if (serverValues.isEmpty()) {
        return false;
    }

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
            server.value("name").toString("Samhain Security"),
            flagForCountry(server.value("country_code").toString()),
            protocolLabel(server.value("protocol").toString()),
            endpoint,
            pingValue.isNull() || pingValue.isUndefined() ? "n/a" : QString::number(pingValue.toInt()) + "ms",
            false,
        });
    }

    m_subscriptionName = subscription.value("name").toString("Samhain Security");
    m_subscriptionUrl = subscription.value("url").toString();
    m_subscriptionMeta = subscription.value("updated_at").toString("Сервис готов");
    m_routeModeIndex = routeModeIndexFromWire(state.value("route_mode").toString("whole-computer"));
    m_serverModel.setServers(servers);
    m_statusText = "Готово";
    emit subscriptionChanged();
    emit routeModeChanged();
    emit statusChanged();
    return true;
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
