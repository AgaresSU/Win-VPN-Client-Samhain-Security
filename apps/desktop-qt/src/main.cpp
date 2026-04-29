#include "AppController.h"

#include <QApplication>
#include <QIcon>
#include <QLocalServer>
#include <QLocalSocket>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QTimer>

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
}

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);
    app.setApplicationName("Samhain Security");
    app.setOrganizationName("Samhain Security");
    app.setApplicationVersion("0.8.5");
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

    QTimer::singleShot(0, &controller, [&controller, activationArguments]() {
        controller.handleExternalActivation(activationArguments);
    });

    return app.exec();
}
