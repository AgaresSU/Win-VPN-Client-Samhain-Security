#include "AppController.h"

#include <QApplication>
#include <QIcon>
#include <QLocalServer>
#include <QLocalSocket>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QTimer>
#include <QWindow>

#ifdef Q_OS_WIN
#include <windows.h>
#include <dwmapi.h>

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif
#ifndef DWMWA_CAPTION_COLOR
#define DWMWA_CAPTION_COLOR 35
#endif
#ifndef DWMWA_TEXT_COLOR
#define DWMWA_TEXT_COLOR 36
#endif
#endif

namespace {
constexpr auto SingleInstanceServerName = "SamhainSecurityNative.SingleInstance";

bool sendToRunningInstance(const QStringList &arguments)
{
    QLocalSocket socket;
    socket.connectToServer(SingleInstanceServerName, QIODevice::WriteOnly);
    if (!socket.waitForConnected(180)) {
        return false;
    }

    socket.write(arguments.join(u'\n').toUtf8());
    socket.flush();
    socket.waitForBytesWritten(180);
    return true;
}

void applyDarkTitleBar(QWindow *window)
{
#ifdef Q_OS_WIN
    if (!window) {
        return;
    }

    const auto hwnd = reinterpret_cast<HWND>(window->winId());
    if (!hwnd) {
        return;
    }

    const BOOL darkMode = TRUE;
    const DWORD captionColor = RGB(18, 16, 18);
    const DWORD textColor = RGB(241, 237, 238);
    DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &darkMode, sizeof(darkMode));
    DwmSetWindowAttribute(hwnd, DWMWA_CAPTION_COLOR, &captionColor, sizeof(captionColor));
    DwmSetWindowAttribute(hwnd, DWMWA_TEXT_COLOR, &textColor, sizeof(textColor));
#else
    Q_UNUSED(window);
#endif
}
}

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);
    app.setApplicationName("Samhain Security");
    app.setOrganizationName("Samhain Security");
    app.setApplicationVersion("1.4.2");
    app.setWindowIcon(QIcon(":/qt/qml/SamhainSecurityNative/resources/app-icon.png"));

    const auto activationArguments = app.arguments().mid(1);
    const auto handoffArguments = activationArguments.isEmpty()
        ? QStringList {"--show"}
        : activationArguments;
    if (sendToRunningInstance(handoffArguments)) {
        return 0;
    }

    QLocalServer::removeServer(SingleInstanceServerName);
    QLocalServer singleInstanceServer;
    singleInstanceServer.listen(SingleInstanceServerName);

    AppController controller;

    QObject::connect(&singleInstanceServer, &QLocalServer::newConnection, &controller, [&]() {
        while (auto *connection = singleInstanceServer.nextPendingConnection()) {
            QObject::connect(connection, &QLocalSocket::readyRead, &controller, [connection, &controller]() {
                const auto payload = QString::fromUtf8(connection->readAll());
                controller.handleExternalActivation(payload.split(u'\n', Qt::SkipEmptyParts));
            });
            QObject::connect(connection, &QLocalSocket::disconnected, connection, &QObject::deleteLater);
        }
    });

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("appController", &controller);
    engine.loadFromModule("SamhainSecurityNative", "Main");

    if (engine.rootObjects().isEmpty()) {
        return -1;
    }

    if (auto *window = qobject_cast<QWindow *>(engine.rootObjects().first())) {
        applyDarkTitleBar(window);
        QObject::connect(window, &QWindow::visibleChanged, window, [window]() {
            if (window->isVisible()) {
                applyDarkTitleBar(window);
            }
        });
    }

    QTimer::singleShot(0, &controller, [&controller, activationArguments]() {
        controller.handleExternalActivation(activationArguments);
    });

    return app.exec();
}
