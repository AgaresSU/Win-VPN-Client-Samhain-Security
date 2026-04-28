#include "AppController.h"

#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QIcon>

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    app.setApplicationName("Samhain Security");
    app.setOrganizationName("Samhain Security");
    app.setApplicationVersion("0.7.3");
    app.setWindowIcon(QIcon(":/qt/qml/SamhainSecurityNative/resources/app-icon.png"));

    AppController controller;

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("appController", &controller);
    engine.loadFromModule("SamhainSecurityNative", "Main");

    if (engine.rootObjects().isEmpty()) {
        return -1;
    }

    return app.exec();
}
