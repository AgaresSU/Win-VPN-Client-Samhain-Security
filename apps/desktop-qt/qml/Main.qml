import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts

ApplicationWindow {
    id: root
    width: 1360
    height: 880
    minimumWidth: 980
    minimumHeight: 700
    visible: true
    title: "Samhain Security"
    color: bg

    readonly property bool compact: width < 1220
    readonly property bool tight: height < 790
    readonly property int pageMargin: compact ? 26 : 36
    readonly property string appIconSource: "qrc:/qt/qml/SamhainSecurityNative/resources/app-icon.png"
    readonly property color bg: "#0F0F10"
    readonly property color rail: "#161213"
    readonly property color panel: "#1A1718"
    readonly property color panelHot: "#282225"
    readonly property color row: "#201D1F"
    readonly property color rowSelected: "#382E32"
    readonly property color text: "#F1EDEE"
    readonly property color muted: "#A9A3A7"
    readonly property color line: "#3B3033"
    readonly property color accent: "#B83A43"
    readonly property color samhainRed: "#B83A43"
    readonly property color field: "#181617"
    readonly property color fieldHot: "#272124"

    Shortcut {
        sequences: [StandardKey.Paste]
        onActivated: appController.pasteFromClipboard()
    }

    Connections {
        target: appController
        function onShowMainWindowRequested() {
            root.show()
            root.raise()
            root.requestActivate()
        }
        function onHideMainWindowRequested() {
            root.hide()
        }
    }

    onClosing: function(close) {
        if (appController.minimizeToTray) {
            close.accepted = false
            root.hide()
            appController.notifyMinimizedToTray()
        }
    }

    Dialog {
        id: addDialog
        modal: true
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        width: 560
        height: 382
        padding: 0
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        onOpened: {
            subscriptionNameInput.text = "Samhain Security"
            subscriptionUrlInput.text = ""
            subscriptionUrlInput.forceActiveFocus()
        }

        background: Rectangle {
            color: "#201C1E"
            radius: 12
            border.color: "#3E3337"
        }

        contentItem: ColumnLayout {
            spacing: 16
            anchors.fill: parent
            anchors.margins: 32

            RowLayout {
                Layout.fillWidth: true
                Text {
                    text: "Добавить подписку"
                    color: root.text
                    font.pixelSize: 26
                    font.bold: true
                    Layout.fillWidth: true
                }
                Button {
                    text: "×"
                    width: 42
                    height: 42
                    onClicked: addDialog.close()
                    background: Rectangle { color: "transparent" }
                    contentItem: Text {
                        text: parent.text
                        color: root.muted
                        font.pixelSize: 30
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }

            Text {
                text: "Название"
                color: root.muted
                font.pixelSize: 15
            }
            TextField {
                id: subscriptionNameInput
                Layout.fillWidth: true
                height: 48
                text: "Samhain Security"
                color: root.text
                placeholderText: "Например: Samhain Security"
                placeholderTextColor: "#777176"
                selectionColor: root.accent
                background: Rectangle {
                    color: root.field
                    radius: 6
                    border.color: subscriptionNameInput.activeFocus ? root.accent : "#463B3F"
                }
            }

            Text {
                text: "URL подписки"
                color: root.muted
                font.pixelSize: 15
            }
            TextField {
                id: subscriptionUrlInput
                Layout.fillWidth: true
                height: 48
                color: root.text
                placeholderText: "https://..."
                placeholderTextColor: "#777176"
                selectionColor: root.accent
                background: Rectangle {
                    color: root.field
                    radius: 6
                    border.color: subscriptionUrlInput.activeFocus ? root.accent : "#463B3F"
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 12
                Item { Layout.fillWidth: true }
                Button {
                    text: "Отмена"
                    Layout.preferredWidth: 118
                    height: 46
                    onClicked: addDialog.close()
                    background: Rectangle {
                        color: parent.down ? "#2A2023" : "#181617"
                        radius: 6
                        border.color: "#30292C"
                    }
                    contentItem: Text { text: parent.text; color: root.muted; font.pixelSize: 16; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                }
                Button {
                    text: "Из буфера"
                    Layout.preferredWidth: 126
                    height: 46
                    onClicked: {
                        appController.pasteFromClipboard()
                        addDialog.close()
                    }
                    background: Rectangle {
                        color: parent.down ? "#2A2023" : "#181617"
                        radius: 6
                        border.color: parent.hovered ? "#4A3C41" : "#30292C"
                    }
                    contentItem: Text { text: parent.text; color: root.text; font.pixelSize: 16; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                }
                Button {
                    text: "Добавить"
                    enabled: subscriptionUrlInput.text.trim().length > 0
                    Layout.preferredWidth: 126
                    height: 46
                    onClicked: {
                        appController.addSubscription(subscriptionNameInput.text, subscriptionUrlInput.text)
                        addDialog.close()
                    }
                    background: Rectangle {
                        color: parent.enabled ? (parent.down ? "#8F2F36" : root.accent) : "#3B3034"
                        radius: 6
                        border.color: parent.enabled ? "#D15B63" : "#463B3F"
                    }
                    contentItem: Text { text: parent.text; color: parent.enabled ? "white" : root.muted; font.pixelSize: 16; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                }
            }
        }
    }

    Dialog {
        id: renameDialog
        property int rowIndex: -1
        modal: true
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        width: 480
        height: 250
        padding: 0
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            color: "#262626"
            radius: 18
            border.color: "#34343A"
        }

        contentItem: ColumnLayout {
            spacing: 18
            anchors.fill: parent
            anchors.margins: 34

            Text {
                text: "Переименовать"
                color: root.text
                font.pixelSize: 28
                font.bold: true
            }
            TextField {
                id: renameSubscriptionNameInput
                Layout.fillWidth: true
                height: 48
                color: root.text
                placeholderText: "Название подписки"
                placeholderTextColor: "#77777F"
                background: Rectangle {
                    color: "#3A3A3A"
                    radius: 8
                    border.color: renameSubscriptionNameInput.activeFocus ? root.accent : "#4A4A4A"
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                Button {
                    text: "Отмена"
                    Layout.preferredWidth: 120
                    height: 48
                    onClicked: renameDialog.close()
                    background: Rectangle { color: "#333333"; radius: 8 }
                    contentItem: Text { text: parent.text; color: root.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                }
                Button {
                    text: "Сохранить"
                    Layout.preferredWidth: 132
                    height: 48
                    onClicked: {
                        appController.renameSubscription(renameDialog.rowIndex, renameSubscriptionNameInput.text)
                        renameDialog.close()
                    }
                    background: Rectangle { color: root.accent; radius: 8 }
                    contentItem: Text { text: parent.text; color: "white"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                }
            }
        }
    }

    FileDialog {
        id: appFileDialog
        title: "Выбрать приложение"
        nameFilters: ["Приложения (*.exe)"]
        onAccepted: appPathInput.text = selectedFile.toString()
    }

    Dialog {
        id: appRoutingDialog
        modal: true
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        width: 680
        height: 560
        padding: 0
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            color: "#262626"
            radius: 18
            border.color: "#34343A"
        }

        contentItem: ColumnLayout {
            spacing: 16
            anchors.fill: parent
            anchors.margins: 34

            RowLayout {
                Layout.fillWidth: true
                Text {
                    text: "Приложения"
                    color: root.text
                    font.pixelSize: 28
                    font.bold: true
                    Layout.fillWidth: true
                }
                Button {
                    text: "×"
                    width: 42
                    height: 42
                    onClicked: appRoutingDialog.close()
                    background: Rectangle { color: "transparent" }
                    contentItem: Text {
                        text: parent.text
                        color: root.muted
                        font.pixelSize: 34
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                text: appController.routePolicyDetail
                color: root.muted
                font.pixelSize: 14
                wrapMode: Text.WordWrap
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: "#202020"
                radius: 8
                border.color: "#38383D"

                ListView {
                    id: routeAppList
                    anchors.fill: parent
                    anchors.margins: 8
                    clip: true
                    model: appController.routeApplications
                    delegate: Rectangle {
                        width: ListView.view.width
                        height: 56
                        color: index % 2 === 0 ? "#242424" : "#202020"
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 8
                            Text {
                                text: modelData
                                color: root.text
                                font.pixelSize: 14
                                elide: Text.ElideMiddle
                                Layout.fillWidth: true
                            }
                            Button {
                                text: "Удалить"
                                Layout.preferredWidth: 104
                                height: 38
                                onClicked: appController.removeRouteApplication(index)
                                background: Rectangle { color: "#3A2224"; radius: 7 }
                                contentItem: Text { text: parent.text; color: "#FF8C91"; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                            }
                        }
                    }
                }

                EmptyState {
                    anchors.centerIn: parent
                    visible: routeAppList.count === 0
                    title: "Список пуст"
                    body: "Приложения не выбраны"
                }
            }

            RowLayout {
                Layout.fillWidth: true
                TextField {
                    id: appPathInput
                    Layout.fillWidth: true
                    height: 46
                    color: root.text
                    placeholderText: "C:\\Program Files\\App\\app.exe"
                    placeholderTextColor: "#77777F"
                    background: Rectangle {
                        color: "#3A3A3A"
                        radius: 8
                        border.color: appPathInput.activeFocus ? root.accent : "#4A4A4A"
                    }
                }
                Button {
                    text: "Выбрать"
                    Layout.preferredWidth: 112
                    height: 46
                    onClicked: appFileDialog.open()
                    background: Rectangle { color: "#333333"; radius: 8 }
                    contentItem: Text { text: parent.text; color: root.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                }
                Button {
                    text: "Добавить"
                    Layout.preferredWidth: 112
                    height: 46
                    onClicked: {
                        appController.addRouteApplication(appPathInput.text)
                        appPathInput.text = ""
                    }
                    background: Rectangle { color: root.accent; radius: 8 }
                    contentItem: Text { text: parent.text; color: "white"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Text {
                    text: appController.routePolicyStatus
                    color: root.muted
                    font.pixelSize: 14
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
                Button {
                    text: "Восстановить"
                    Layout.preferredWidth: 136
                    height: 42
                    onClicked: appController.restoreAppRoutingPolicy()
                    background: Rectangle { color: "#333333"; radius: 8 }
                    contentItem: Text { text: parent.text; color: root.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                }
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        color: root.bg

        RowLayout {
            anchors.fill: parent
            spacing: 0

            Rectangle {
                Layout.preferredWidth: root.compact ? 92 : 246
                Layout.fillHeight: true
                color: root.rail

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 0
                    spacing: 0

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.preferredHeight: root.compact ? 76 : 84
                        Layout.leftMargin: root.compact ? 18 : 22
                        Layout.rightMargin: root.compact ? 18 : 18
                        spacing: root.compact ? 0 : 14

                        Rectangle {
                            Layout.preferredWidth: 42
                            Layout.preferredHeight: 42
                            radius: 8
                            color: "#24191C"
                            border.color: "#473137"
                            Image {
                                anchors.fill: parent
                                anchors.margins: 4
                                source: root.appIconSource
                                fillMode: Image.PreserveAspectFit
                                smooth: true
                            }
                        }
                        Text {
                            visible: !root.compact
                            text: "Samhain Security"
                            color: root.muted
                            font.pixelSize: 16
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                        }
                    }

                    NavButton {
                        label: "Добавить"
                        iconText: "+"
                        active: appController.page === "add"
                        onClicked: {
                            appController.navigate("add")
                            addDialog.open()
                        }
                    }
                    NavButton {
                        label: "Серверы"
                        iconText: "◎"
                        active: appController.page === "servers"
                        onClicked: appController.navigate("servers")
                    }
                    NavButton {
                        label: "Настройки"
                        iconText: "⚙"
                        active: appController.page === "settings"
                        onClicked: appController.navigate("settings")
                    }
                    NavButton {
                        label: "Статистика"
                        iconText: "⌁"
                        active: appController.page === "stats"
                        onClicked: appController.navigate("stats")
                    }
                    NavButton {
                        label: "Логи"
                        iconText: "↻"
                        active: appController.page === "logs"
                        onClicked: appController.navigate("logs")
                    }

                    Item { Layout.fillHeight: true }

                    NavButton {
                        label: "О программе"
                        iconText: "i"
                        active: appController.page === "about"
                        onClicked: appController.navigate("about")
                    }
                }
            }

            Rectangle {
                Layout.preferredWidth: root.compact ? Math.min(560, root.width * 0.56) : 626
                Layout.fillHeight: true
                color: root.bg

                Loader {
                    anchors.fill: parent
                    sourceComponent: {
                        if (appController.page === "settings") return settingsPage
                        if (appController.page === "stats") return statsPage
                        if (appController.page === "logs") return logsPage
                        if (appController.page === "about") return aboutPage
                        return serversPage
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: "#171416"
                clip: true

                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "#1B171A" }
                        GradientStop { position: 1.0; color: "#101012" }
                    }
                }
                Rectangle {
                    width: parent.width * 1.12
                    height: parent.height * 0.60
                    x: parent.width * 0.06
                    y: parent.height * 0.36
                    rotation: 38
                    radius: 80
                    color: "#151214"
                    opacity: 0.68
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: root.compact ? 28 : 42
                    spacing: root.tight ? 14 : 20

                    Rectangle {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: 178
                        Layout.preferredHeight: 38
                        radius: 6
                        color: appController.connected ? "#2C171B" : "#211C1E"
                        border.color: appController.connected ? root.accent : "#44363A"
                        Text {
                            anchors.centerIn: parent
                            text: appController.connected ? "Подключён" : "Ожидание"
                            color: appController.connected ? "#F4D9DC" : root.muted
                            font.pixelSize: 15
                            font.bold: true
                        }
                    }

                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: root.tight ? 290 : 374
                        property int dialSize: root.tight ? 230 : 306

                        Rectangle {
                            width: parent.dialSize
                            height: width
                            radius: width / 2
                            anchors.centerIn: parent
                            color: "transparent"
                            border.color: appController.connected ? "#5A2028" : "#33252A"
                            border.width: 2
                            opacity: 0.62
                        }
                        Rectangle {
                            width: parent.dialSize * 0.78
                            height: width
                            radius: width / 2
                            anchors.centerIn: parent
                            color: "#222027"
                            border.color: "#343141"
                            border.width: 2
                            opacity: 0.42
                        }
                        Rectangle {
                            width: parent.dialSize * 0.56
                            height: width
                            radius: width / 2
                            anchors.centerIn: parent
                            color: "transparent"
                            border.color: appController.connected ? root.accent : "#5C3339"
                            border.width: 2
                            opacity: 0.88
                        }
                        Rectangle {
                            width: parent.dialSize * 0.36
                            height: width
                            radius: width / 2
                            anchors.centerIn: parent
                            color: "transparent"
                            border.color: "#2F2930"
                            border.width: 1
                        }
                        PowerButton {
                            width: root.tight ? 96 : 118
                            height: width
                            anchors.centerIn: parent
                            connected: appController.connected
                            label: appController.connected ? appController.sessionTime : "Старт"
                            onClicked: appController.toggleConnection()
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: root.tight ? 124 : 140
                        color: "#171517"
                        border.color: "#2F292C"
                        radius: 8
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 18
                            spacing: root.tight ? 7 : 9
                            CountryFlag {
                                value: appController.selectedServerFlag
                                size: root.tight ? 38 : 44
                                Layout.alignment: Qt.AlignHCenter
                            }
                            Text {
                                text: appController.selectedServerName
                                color: root.text
                                font.pixelSize: root.tight ? 17 : 21
                                Layout.alignment: Qt.AlignHCenter
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                            Text {
                                text: appController.selectedServerProtocol + " · " + appController.selectedServerPing
                                color: root.muted
                                font.pixelSize: root.tight ? 13 : 14
                                Layout.alignment: Qt.AlignHCenter
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }
                    }

                    Button {
                        text: "Тест пинга"
                        Layout.preferredWidth: 288
                        Layout.preferredHeight: root.tight ? 42 : 48
                        Layout.alignment: Qt.AlignHCenter
                        onClicked: appController.testPing()
                        background: Rectangle {
                            radius: 6
                            color: parent.down ? "#8F2F36" : root.accent
                            border.color: "#D15B63"
                        }
                        contentItem: Text { text: parent.text; color: "white"; font.pixelSize: 18; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    }

                    RowLayout {
                        Layout.alignment: Qt.AlignHCenter
                        spacing: 8
                        Chip { text: "Proxy" }
                        Chip { text: "TUN" }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: root.tight ? 80 : 92
                        color: "#171517"
                        border.color: "#31292D"
                        radius: 8
                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 18
                            spacing: 20
                            StatText { title: "Загрузка"; value: appController.downloadSpeed }
                            StatText { title: "Выгрузка"; value: appController.uploadSpeed }
                            StatText { title: "Сессия"; value: appController.sessionTraffic }
                        }
                    }

                    Item { Layout.fillHeight: true }
                }
            }
        }
    }

    Component {
        id: serversPage
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: root.pageMargin
            spacing: 18

            Text {
                text: "Серверы"
                color: root.text
                font.pixelSize: 34
                font.bold: true
            }

            RowLayout {
                Layout.fillWidth: true
                TextField {
                    id: searchField
                    Layout.fillWidth: true
                    Layout.preferredHeight: 58
                    color: root.text
                    placeholderText: "Введите текст для поиска"
                    placeholderTextColor: root.muted
                    font.pixelSize: 18
                    background: Rectangle {
                        color: root.field
                        radius: 6
                        border.color: searchField.activeFocus ? root.accent : "#4B4145"
                        border.width: 1
                    }
                }
                ButtonIcon { label: "↻"; onClicked: appController.testAllPings() }
                ButtonIcon { label: "⋯"; onClicked: addDialog.open() }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: "transparent"

                ListView {
                    id: serverList
                    anchors.fill: parent
                    clip: true
                    model: appController.serverModel
                    spacing: 0
                    delegate: Rectangle {
                        width: serverList.width
                        height: isSubscription ? 76 : 70
                        color: isSubscription ? "#2A2728" : (selected ? root.rowSelected : root.row)
                        border.color: isSubscription ? "#43383C" : "#30292C"
                        border.width: 1
                        radius: isSubscription ? 7 : 0

                        MouseArea {
                            anchors.fill: parent
                            onClicked: appController.selectServer(index)
                        }

                        RowLayout {
                            visible: isSubscription
                            anchors.fill: parent
                            anchors.leftMargin: 22
                            anchors.rightMargin: 14
                            spacing: 12

                            Text {
                                text: expanded ? "⌄" : "›"
                                color: root.muted
                                font.pixelSize: 22
                                Layout.preferredWidth: 24
                                horizontalAlignment: Text.AlignHCenter
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 5
                                Text {
                                    text: name
                                    color: root.text
                                    font.pixelSize: 19
                                    font.bold: true
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                Text {
                                    text: meta + " · " + serverCount + " серверов"
                                    color: root.muted
                                    font.pixelSize: 14
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                            }
                            ButtonIcon { label: "↻"; onClicked: appController.refreshSubscription(index) }
                            ButtonIcon { label: "⋯"; onClicked: subscriptionActions.open() }

                            Menu {
                                id: subscriptionActions
                                modal: true
                                background: Rectangle {
                                    color: "#201C1E"
                                    radius: 8
                                    border.color: "#3E3337"
                                }
                                delegate: MenuItem {
                                    id: actionItem
                                    implicitWidth: 188
                                    implicitHeight: 42
                                    contentItem: Text {
                                        text: actionItem.text
                                        color: actionItem.text === "Удалить" ? "#F06A72" : root.text
                                        font.pixelSize: 15
                                        verticalAlignment: Text.AlignVCenter
                                        leftPadding: 10
                                        elide: Text.ElideRight
                                    }
                                    background: Rectangle {
                                        color: actionItem.highlighted ? "#302529" : "transparent"
                                        radius: 6
                                    }
                                }
                                MenuItem {
                                    text: "Переименовать"
                                    onTriggered: {
                                        renameDialog.rowIndex = index
                                        renameSubscriptionNameInput.text = name
                                        renameDialog.open()
                                    }
                                }
                                MenuItem {
                                    text: "Диагностика"
                                    onTriggered: appController.copySubscriptionDiagnostics(index)
                                }
                                MenuSeparator {
                                    contentItem: Rectangle {
                                        implicitHeight: 1
                                        color: "#3A3033"
                                    }
                                }
                                MenuItem {
                                    text: "Удалить"
                                    onTriggered: appController.deleteSubscription(index)
                                }
                            }
                        }

                        RowLayout {
                            visible: !isSubscription
                            anchors.fill: parent
                            anchors.leftMargin: 18
                            anchors.rightMargin: 18
                            spacing: 14

                            CountryFlag {
                                value: flag
                                size: 36
                                Layout.preferredWidth: 42
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 4
                                Text {
                                    text: name
                                    color: root.text
                                    font.pixelSize: 18
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                Text {
                                    text: protocol
                                    color: root.muted
                                    font.pixelSize: 13
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                            }
                            Text {
                                text: ping
                                color: selected ? root.text : root.muted
                                font.pixelSize: 14
                                Layout.preferredWidth: 72
                                horizontalAlignment: Text.AlignRight
                            }
                            Text { text: "›"; color: root.muted; font.pixelSize: 26 }
                        }
                    }
                }

                EmptyState {
                    anchors.centerIn: parent
                    visible: serverList.count === 0
                    title: "Серверов нет"
                    body: "Добавьте подписку"
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 16
                QuickActionButton {
                    iconText: "⧉"
                    label: "Из буфера"
                    onClicked: appController.pasteFromClipboard()
                }
                QuickActionButton {
                    iconText: "+"
                    label: "Добавить"
                    onClicked: addDialog.open()
                }
            }

            Text {
                text: appController.statusText
                color: root.muted
                font.pixelSize: 14
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }
    }

    Component {
        id: settingsPage
        ScrollView {
            anchors.fill: parent
            contentWidth: availableWidth
            ColumnLayout {
                width: parent.width
                spacing: 20
                anchors.margins: root.pageMargin
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top

                PageTitle { text: "Настройки" }
                SettingsSectionTitle { text: "Основное" }
                SettingsCard {
                    title: "Режим работы"
                    subtitle: appController.routePolicyStatus
                    DarkComboBox {
                        id: routeCombo
                        Layout.fillWidth: true
                        Layout.maximumWidth: 390
                        model: ["Весь компьютер", "Только выбранные приложения", "Кроме выбранных приложений"]
                        currentIndex: appController.routeModeIndex
                        onActivated: appController.routeModeIndex = currentIndex
                    }
                }
                SettingsCard {
                    title: "Приложения"
                    subtitle: appController.routeAppCountLabel
                    visible: appController.routeModeIndex !== 0
                    Text {
                        text: appController.routePolicyDetail
                        color: root.muted
                        font.pixelSize: 14
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        Layout.maximumWidth: parent.width * 0.44
                    }
                    QuietButton {
                        text: "Изменить"
                        Layout.preferredWidth: 120
                        onClicked: appRoutingDialog.open()
                    }
                }
                SettingsSectionTitle { text: "Запуск" }
                SettingsCard {
                    title: "Автозапуск"
                    subtitle: appController.desktopIntegrationStatus
                    DarkSwitch {
                        checked: appController.autostartEnabled
                        onToggled: appController.setAutostartEnabled(checked)
                    }
                }
                SettingsCard {
                    title: "Ссылки Samhain"
                    subtitle: "samhain://"
                    QuietButton {
                        text: "Включить"
                        Layout.preferredWidth: 104
                        onClicked: appController.registerLinkHandler()
                    }
                }
                AdvancedSettingsBox {}
            }
        }
    }

    Component {
        id: statsPage
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: root.pageMargin
            spacing: 18
            PageTitle { text: "Статистика" }
            MetricRow { title: "Время подключения"; value: appController.sessionTime }
            MetricRow { title: "Загрузка"; value: appController.downloadSpeed }
            MetricRow { title: "Выгрузка"; value: appController.uploadSpeed }
            MetricRow { title: "Трафик за сессию"; value: appController.sessionTraffic }
            MetricRow { title: "Источник"; value: appController.trafficDetail }
            Item { Layout.fillHeight: true }
        }
    }

    Component {
        id: logsPage
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: root.pageMargin
            spacing: 18
            RowLayout {
                Layout.fillWidth: true
                PageTitle { text: "Логи"; Layout.fillWidth: true }
                ComboBox {
                    Layout.preferredWidth: 150
                    model: appController.logCategories
                    currentIndex: appController.logCategoryIndex
                    onActivated: appController.logCategoryIndex = currentIndex
                    background: Rectangle {
                        color: "#2C2427"
                        radius: 8
                        border.color: "#49383D"
                    }
                    contentItem: Text {
                        text: parent.displayText
                        color: root.text
                        font.pixelSize: 15
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 12
                        elide: Text.ElideRight
                    }
                }
                Button {
                    text: "Обновить"
                    onClicked: appController.refreshServiceLogs()
                    background: Rectangle { color: "#333333"; radius: 8 }
                    contentItem: Text { text: parent.text; color: root.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                }
                Button {
                    text: "Экспорт"
                    onClicked: appController.exportSupportBundle()
                    background: Rectangle { color: root.accent; radius: 8 }
                    contentItem: Text { text: parent.text; color: "white"; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                }
                Button {
                    text: "Очистить"
                    onClicked: appController.clearLogs()
                    background: Rectangle { color: "#333333"; radius: 8 }
                    contentItem: Text { text: parent.text; color: root.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                }
            }
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                ListView {
                    id: logsList
                    anchors.fill: parent
                    clip: true
                    model: appController.logs
                    delegate: Text {
                        width: ListView.view.width
                        text: modelData
                        color: root.text
                        font.family: "Consolas"
                        font.pixelSize: 15
                        padding: 6
                    }
                }

                EmptyState {
                    anchors.centerIn: parent
                    visible: logsList.count === 0
                    title: "Логи пусты"
                    body: "Сервис пока ничего не сообщил"
                }
            }
            Text {
                text: appController.supportBundleStatus
                color: root.muted
                font.pixelSize: 14
                elide: Text.ElideMiddle
                Layout.fillWidth: true
            }
        }
    }

    Component {
        id: aboutPage
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: root.pageMargin
            spacing: 18
            PageTitle { text: "О программе" }
            MetricRow { title: "Программа"; value: "Samhain Security Native" }
            MetricRow { title: "Версия"; value: "1.0.6" }
            MetricRow { title: "Интерфейс"; value: "Qt 6 / QML" }
            MetricRow { title: "Ядро"; value: "Rust workspace" }
            MetricRow { title: "Статус"; value: appController.statusText }
            Item { Layout.fillHeight: true }
        }
    }

    component NavButton: Rectangle {
        id: navButton
        property string iconText: ""
        property string label: ""
        property bool active: false
        signal clicked()
        Layout.fillWidth: true
        Layout.preferredHeight: root.compact ? 58 : 64
        Layout.leftMargin: root.compact ? 6 : 8
        Layout.rightMargin: root.compact ? 6 : 10
        color: active ? "#0B0809" : (navMouse.containsMouse ? "#1B1517" : "transparent")
        radius: 10
        border.color: active ? "#35272B" : (navMouse.containsMouse ? "#31262A" : "transparent")
        border.width: 1

        RowLayout {
            anchors.fill: parent
            spacing: root.compact ? 0 : 16
            anchors.leftMargin: root.compact ? 17 : 18
            anchors.rightMargin: root.compact ? 17 : 14
            Rectangle {
                Layout.preferredWidth: 42
                Layout.preferredHeight: 42
                radius: 12
                color: navButton.active ? "#1C1114" : "#120F10"
                border.color: navButton.active ? root.accent : "#30272A"
                Text {
                    anchors.centerIn: parent
                    text: navButton.iconText
                    color: navButton.active ? "#FFFFFF" : "#D7D0D3"
                    font.pixelSize: navButton.iconText === "i" ? 22 : 24
                    font.bold: navButton.active
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
            Text {
                visible: !root.compact
                text: navButton.label
                color: navButton.active ? "#FFFFFF" : root.text
                font.pixelSize: 20
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
        }

        MouseArea {
            id: navMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: navButton.clicked()
        }
    }

    component PowerButton: Rectangle {
        id: powerButton
        property bool connected: false
        property string label: ""
        signal clicked()
        radius: width / 2
        color: connected ? Qt.rgba(0.72, 0.16, 0.22, 0.34) : Qt.rgba(0.28, 0.12, 0.16, 0.34)
        border.color: connected ? "#E04A56" : "#7A3841"
        border.width: 2

        Rectangle {
            anchors.centerIn: parent
            width: parent.width * 0.70
            height: width
            radius: width / 2
            color: connected ? Qt.rgba(0.72, 0.16, 0.22, 0.18) : Qt.rgba(0.12, 0.09, 0.10, 0.44)
            border.color: connected ? "#B83A43" : "#4A3036"
            border.width: 1
        }
        Canvas {
            id: powerCanvas
            anchors.fill: parent
            antialiasing: true
            onPaint: {
                var ctx = getContext("2d")
                var w = width
                var h = height
                var cx = w / 2
                var cy = h / 2 - h * 0.04
                var r = Math.min(w, h) * 0.21
                ctx.clearRect(0, 0, w, h)
                ctx.lineCap = "round"
                ctx.lineJoin = "round"
                ctx.strokeStyle = "#FFFFFF"
                ctx.lineWidth = Math.max(5, w * 0.055)
                ctx.beginPath()
                ctx.arc(cx, cy, r, Math.PI * 1.75, Math.PI * 3.25, false)
                ctx.stroke()
                ctx.beginPath()
                ctx.moveTo(cx, cy - r * 1.24)
                ctx.lineTo(cx, cy - r * 0.16)
                ctx.stroke()
            }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 16
            text: powerButton.label
            color: "#F1EDEE"
            opacity: 0.92
            font.pixelSize: 12
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: powerButton.clicked()
        }
    }

    component CountryFlag: Item {
        id: flagBadge
        property string value: ""
        property int size: 34
        readonly property string countryCode: normalizedCountry(value)
        onValueChanged: flagCanvas.requestPaint()
        implicitWidth: Math.round(size * 1.42)
        implicitHeight: size
        Layout.preferredWidth: Math.round(size * 1.42)
        Layout.preferredHeight: size

        function normalizedCountry(raw) {
            var v = (raw || "").toUpperCase()
            if (raw.indexOf("🇬🇧") >= 0 || v.indexOf("GB") >= 0 || v.indexOf("UK") >= 0) return "GB"
            if (raw.indexOf("🇳🇱") >= 0 || v.indexOf("NL") >= 0) return "NL"
            if (raw.indexOf("🇸🇪") >= 0 || v.indexOf("SE") >= 0) return "SE"
            if (raw.indexOf("🇩🇪") >= 0 || v.indexOf("DE") >= 0) return "DE"
            if (raw.indexOf("🇺🇸") >= 0 || v.indexOf("US") >= 0) return "US"
            return ""
        }

        Canvas {
            id: flagCanvas
            anchors.fill: parent
            antialiasing: true
            onPaint: {
                var ctx = getContext("2d")
                var w = width
                var h = height
                var code = flagBadge.countryCode
                var r = h / 2

                function roundedClip() {
                    ctx.beginPath()
                    ctx.moveTo(r, 0)
                    ctx.lineTo(w - r, 0)
                    ctx.quadraticCurveTo(w, 0, w, r)
                    ctx.lineTo(w, h - r)
                    ctx.quadraticCurveTo(w, h, w - r, h)
                    ctx.lineTo(r, h)
                    ctx.quadraticCurveTo(0, h, 0, h - r)
                    ctx.lineTo(0, r)
                    ctx.quadraticCurveTo(0, 0, r, 0)
                    ctx.closePath()
                }
                function fill(color, x, y, ww, hh) {
                    ctx.fillStyle = color
                    ctx.fillRect(x, y, ww, hh)
                }

                ctx.clearRect(0, 0, w, h)
                ctx.save()
                roundedClip()
                ctx.clip()
                fill("#211C1E", 0, 0, w, h)

                if (code === "GB") {
                    fill("#183A78", 0, 0, w, h)
                    ctx.strokeStyle = "#FFFFFF"
                    ctx.lineWidth = h * 0.18
                    ctx.beginPath()
                    ctx.moveTo(0, 0); ctx.lineTo(w, h)
                    ctx.moveTo(w, 0); ctx.lineTo(0, h)
                    ctx.stroke()
                    ctx.strokeStyle = "#C8102E"
                    ctx.lineWidth = h * 0.08
                    ctx.beginPath()
                    ctx.moveTo(0, 0); ctx.lineTo(w, h)
                    ctx.moveTo(w, 0); ctx.lineTo(0, h)
                    ctx.stroke()
                    fill("#FFFFFF", 0, h * 0.39, w, h * 0.22)
                    fill("#FFFFFF", w * 0.40, 0, w * 0.20, h)
                    fill("#C8102E", 0, h * 0.44, w, h * 0.12)
                    fill("#C8102E", w * 0.44, 0, w * 0.12, h)
                } else if (code === "NL") {
                    fill("#AE1C28", 0, 0, w, h / 3)
                    fill("#FFFFFF", 0, h / 3, w, h / 3)
                    fill("#21468B", 0, h * 2 / 3, w, h / 3)
                } else if (code === "DE") {
                    fill("#000000", 0, 0, w, h / 3)
                    fill("#DD0000", 0, h / 3, w, h / 3)
                    fill("#FFCE00", 0, h * 2 / 3, w, h / 3)
                } else if (code === "SE") {
                    fill("#006AA7", 0, 0, w, h)
                    fill("#FECC00", w * 0.32, 0, w * 0.16, h)
                    fill("#FECC00", 0, h * 0.40, w, h * 0.20)
                } else if (code === "US") {
                    for (var i = 0; i < 7; i++) {
                        fill(i % 2 === 0 ? "#B22234" : "#FFFFFF", 0, i * h / 7, w, h / 7)
                    }
                    fill("#3C3B6E", 0, 0, w * 0.54, h * 0.54)
                }
                ctx.restore()
                ctx.strokeStyle = "#31272B"
                ctx.lineWidth = 1
                roundedClip()
                ctx.stroke()
            }
        }
        Text {
            visible: flagBadge.countryCode === ""
            anchors.centerIn: parent
            text: "•"
            color: root.muted
            font.pixelSize: parent.height * 0.52
        }
    }

    component ButtonIcon: Button {
        id: iconButton
        property string label: ""
        property bool danger: false
        Layout.preferredWidth: 42
        Layout.preferredHeight: 42
        background: Rectangle {
            color: iconButton.down ? "#332126" : (iconButton.hovered ? "#211A1D" : "transparent")
            radius: 21
            border.color: iconButton.hovered ? "#4A373D" : "transparent"
        }
        contentItem: Text {
            text: iconButton.label
            color: danger ? root.samhainRed : root.muted
            font.pixelSize: 24
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    component QuickActionButton: Button {
        id: quickButton
        property string iconText: ""
        property string label: ""
        Layout.fillWidth: true
        Layout.preferredHeight: 58
        background: Rectangle {
            color: quickButton.down ? "#2D2024" : (quickButton.hovered ? "#211B1D" : "#171516")
            radius: 8
            border.color: quickButton.hovered ? "#514248" : "#2E272A"
        }
        contentItem: RowLayout {
            spacing: 12
            Item { Layout.fillWidth: true }
            Text {
                text: quickButton.iconText
                color: root.accent
                font.pixelSize: 24
                Layout.preferredWidth: 28
                horizontalAlignment: Text.AlignHCenter
            }
            Text {
                text: quickButton.label
                color: root.text
                font.pixelSize: 18
                elide: Text.ElideRight
            }
            Item { Layout.fillWidth: true }
        }
    }

    component Chip: Rectangle {
        id: chip
        property string text: ""
        width: chipLabel.implicitWidth + 28
        height: 34
        radius: 6
        color: "#191719"
        border.color: "#4A3036"
        Text {
            id: chipLabel
            anchors.centerIn: parent
            text: chip.text
            color: "#D7C8CC"
            font.pixelSize: 16
        }
    }

    component StatText: ColumnLayout {
        property string title: ""
        property string value: ""
        Layout.fillWidth: true
        spacing: 4
        Text { text: title; color: root.muted; font.pixelSize: 13 }
        Text { text: value; color: root.text; font.pixelSize: 17; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
    }

    component EmptyState: ColumnLayout {
        property string title: ""
        property string body: ""
        spacing: 8
        width: 260
        Text {
            Layout.alignment: Qt.AlignHCenter
            text: "◇"
            color: root.accent
            opacity: 0.85
            font.pixelSize: 28
        }
        Text {
            Layout.fillWidth: true
            text: title
            color: root.text
            font.pixelSize: 18
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
        }
        Text {
            Layout.fillWidth: true
            text: body
            color: root.muted
            font.pixelSize: 14
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
        }
    }

    component PageTitle: Text {
        color: root.text
        font.pixelSize: root.compact ? 32 : 36
        font.bold: true
    }

    component MetricRow: Rectangle {
        property string title: ""
        property string value: ""
        Layout.fillWidth: true
        Layout.preferredHeight: 66
        color: root.fieldHot
        radius: 6
        border.color: root.line
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 20
            anchors.rightMargin: 20
            Text { text: title; color: root.text; font.pixelSize: 18; Layout.fillWidth: true }
            Text { text: value; color: root.muted; font.pixelSize: 18; horizontalAlignment: Text.AlignRight; elide: Text.ElideRight; Layout.maximumWidth: parent.width * 0.56 }
        }
    }

    component SettingsSectionTitle: Text {
        Layout.fillWidth: true
        text: ""
        color: root.text
        font.pixelSize: 20
        font.bold: true
        topPadding: 6
        bottomPadding: 0
    }

    component SettingsCard: Rectangle {
        default property alias content: contentRow.data
        property string title: ""
        property string subtitle: ""
        Layout.fillWidth: true
        Layout.preferredHeight: subtitle.length > 0 ? 86 : 72
        color: root.fieldHot
        radius: 6
        border.color: root.line
        RowLayout {
            id: contentRow
            anchors.fill: parent
            anchors.leftMargin: 20
            anchors.rightMargin: 20
            spacing: 16
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 4
                Text {
                    text: title
                    color: root.text
                    font.pixelSize: 18
                    font.bold: true
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
                Text {
                    visible: subtitle.length > 0
                    text: subtitle
                    color: root.muted
                    font.pixelSize: 14
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
            }
        }
    }

    component QuietButton: Button {
        id: quietButton
        property bool accentButton: false
        property bool danger: false
        Layout.preferredHeight: 42
        background: Rectangle {
            color: quietButton.down
                ? (danger ? "#3A1E22" : (accentButton ? "#8F2F36" : "#231B1E"))
                : (quietButton.hovered ? (danger ? "#312024" : "#211B1D") : (accentButton ? root.accent : "#171516"))
            radius: 6
            border.color: quietButton.hovered ? (danger ? "#5C2D34" : "#4A3C41") : "#30292C"
        }
        contentItem: Text {
            text: quietButton.text
            color: danger ? "#F06A72" : root.text
            font.pixelSize: 15
            font.bold: accentButton
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }

    component DarkComboBox: ComboBox {
        id: darkCombo
        Layout.preferredHeight: 44
        background: Rectangle {
            color: root.field
            radius: 6
            border.color: darkCombo.activeFocus ? root.accent : "#463B3F"
        }
        contentItem: Text {
            text: darkCombo.displayText
            color: root.text
            font.pixelSize: 15
            verticalAlignment: Text.AlignVCenter
            leftPadding: 14
            rightPadding: 38
            elide: Text.ElideRight
        }
        indicator: Text {
            x: darkCombo.width - width - 12
            y: Math.round((darkCombo.height - height) / 2)
            text: "⌄"
            color: root.muted
            font.pixelSize: 22
        }
        delegate: ItemDelegate {
            width: darkCombo.width
            height: 42
            highlighted: darkCombo.highlightedIndex === index
            contentItem: Text {
                text: modelData
                color: root.text
                font.pixelSize: 15
                verticalAlignment: Text.AlignVCenter
                leftPadding: 12
                elide: Text.ElideRight
            }
            background: Rectangle {
                color: highlighted ? "#302529" : "#201C1E"
            }
        }
        popup: Popup {
            y: darkCombo.height + 4
            width: darkCombo.width
            implicitHeight: contentItem.implicitHeight + 8
            padding: 4
            contentItem: ListView {
                clip: true
                implicitHeight: contentHeight
                model: darkCombo.popup.visible ? darkCombo.delegateModel : null
                currentIndex: darkCombo.highlightedIndex
            }
            background: Rectangle {
                color: "#201C1E"
                radius: 8
                border.color: "#3E3337"
            }
        }
    }

    component DarkSwitch: Switch {
        id: darkSwitch
        Layout.preferredWidth: 58
        Layout.preferredHeight: 32
        padding: 0
        indicator: Rectangle {
            implicitWidth: 58
            implicitHeight: 32
            radius: 16
            color: darkSwitch.checked ? root.accent : "#171516"
            border.color: darkSwitch.checked ? "#D15B63" : "#4A3C41"
            Rectangle {
                x: darkSwitch.checked ? parent.width - width - 4 : 4
                anchors.verticalCenter: parent.verticalCenter
                width: 24
                height: 24
                radius: 12
                color: darkSwitch.checked ? "#FFFFFF" : root.muted
            }
        }
        contentItem: Item {}
    }

    component AdvancedGroupTitle: Text {
        Layout.fillWidth: true
        text: ""
        color: root.muted
        font.pixelSize: 14
        font.bold: true
        topPadding: 6
    }

    component AdvancedStatusRow: Rectangle {
        property string title: ""
        property string value: ""
        property string detail: ""
        Layout.fillWidth: true
        Layout.preferredHeight: detail.length > 0 ? 76 : 56
        color: "#211C1E"
        radius: 6
        border.color: "#342B2F"
        ColumnLayout {
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            spacing: 4
            RowLayout {
                Layout.fillWidth: true
                Text {
                    text: title
                    color: root.text
                    font.pixelSize: 15
                    font.bold: true
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
                Text {
                    text: value
                    color: root.muted
                    font.pixelSize: 15
                    horizontalAlignment: Text.AlignRight
                    Layout.maximumWidth: parent.width * 0.48
                    elide: Text.ElideRight
                }
            }
            Text {
                visible: detail.length > 0
                text: detail
                color: root.muted
                font.pixelSize: 13
                Layout.fillWidth: true
                elide: Text.ElideRight
            }
        }
    }

    component AdvancedSettingsBox: Rectangle {
        property bool expanded: false
        Layout.fillWidth: true
        Layout.preferredHeight: expanded ? 930 : 72
        color: root.fieldHot
        radius: 6
        border.color: root.line
        clip: true

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 72
                color: "transparent"
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 20
                    anchors.rightMargin: 20
                    Text { text: "Расширенные настройки"; color: root.text; font.pixelSize: 18; Layout.fillWidth: true }
                    Text { text: expanded ? "⌃" : "⌄"; color: root.muted; font.pixelSize: 22 }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: expanded = !expanded
                }
            }

            ColumnLayout {
                visible: expanded
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.leftMargin: 20
                Layout.rightMargin: 20
                Layout.bottomMargin: 18
                spacing: 10

                AdvancedGroupTitle { text: "Движок" }
                AdvancedStatusRow { title: "Состояние"; value: appController.engineStatus; detail: appController.engineDetail }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    QuietButton {
                        text: "Обновить"
                        Layout.preferredWidth: 118
                        onClicked: appController.refreshEngineStatus()
                    }
                    QuietButton {
                        text: "Конфиг"
                        Layout.preferredWidth: 118
                        onClicked: appController.previewSelectedEngineConfig()
                    }
                    QuietButton {
                        text: "Перезапуск"
                        Layout.preferredWidth: 118
                        onClicked: appController.restartEngine()
                    }
                    QuietButton {
                        text: "Stop"
                        Layout.preferredWidth: 90
                        danger: true
                        onClicked: appController.stopEngine()
                    }
                    Item { Layout.fillWidth: true }
                }

                AdvancedGroupTitle { text: "Пути подключения" }
                AdvancedStatusRow { title: "Proxy"; value: appController.proxyStatus; detail: appController.proxyDetail }
                AdvancedStatusRow { title: "TUN"; value: appController.tunStatus; detail: appController.tunDetail }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    QuietButton {
                        text: "Proxy"
                        Layout.preferredWidth: 118
                        onClicked: appController.refreshProxyStatus()
                    }
                    QuietButton {
                        text: "Restore"
                        Layout.preferredWidth: 118
                        danger: true
                        onClicked: appController.restoreProxyPolicy()
                    }
                    QuietButton {
                        text: "TUN"
                        Layout.preferredWidth: 118
                        onClicked: appController.refreshTunStatus()
                    }
                    QuietButton {
                        text: "Restore TUN"
                        Layout.preferredWidth: 132
                        danger: true
                        onClicked: appController.restoreTunPolicy()
                    }
                    Item { Layout.fillWidth: true }
                }

                AdvancedGroupTitle { text: "Маршрутизация и защита" }
                AdvancedStatusRow { title: "Приложения"; value: appController.routePolicyStatus; detail: appController.routePolicyDetail }
                AdvancedStatusRow { title: "Защита"; value: appController.protectionStatus; detail: appController.protectionDetail }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    QuietButton {
                        text: "Маршрут"
                        Layout.preferredWidth: 118
                        onClicked: appController.refreshAppRoutingPolicy()
                    }
                    QuietButton {
                        text: "Сброс маршрута"
                        Layout.preferredWidth: 142
                        danger: true
                        onClicked: appController.restoreAppRoutingPolicy()
                    }
                    QuietButton {
                        text: "Защита"
                        Layout.preferredWidth: 118
                        onClicked: appController.refreshProtectionPolicy()
                    }
                    QuietButton {
                        text: "Сброс защиты"
                        Layout.preferredWidth: 132
                        danger: true
                        onClicked: appController.restoreProtectionPolicy()
                    }
                    QuietButton {
                        text: "Сбросить всё"
                        Layout.preferredWidth: 132
                        danger: true
                        onClicked: appController.emergencyRestore()
                    }
                    Item { Layout.fillWidth: true }
                }

                AdvancedGroupTitle { text: "Диагностика" }
                AdvancedStatusRow {
                    title: "Каталог"
                    value: appController.engineCatalog.length > 0 ? appController.engineCatalog.length + " записей" : "нет данных"
                    detail: appController.engineCatalog.length > 0 ? appController.engineCatalog.join(" · ") : ""
                }
                ScrollView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    background: Rectangle {
                        color: "#171415"
                        radius: 6
                        border.color: "#342B2F"
                    }
                    Text {
                        width: parent.width
                        text: appController.engineConfigPreview
                        color: root.text
                        font.family: "Consolas"
                        font.pixelSize: 12
                        wrapMode: Text.WrapAnywhere
                    }
                }
            }
        }
    }

    component ExpanderLike: Rectangle {
        property string title: ""
        property string body: ""
        property bool expanded: false
        Layout.fillWidth: true
        Layout.preferredHeight: expanded ? 150 : 72
        color: "#333333"
        radius: 6
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 20
            RowLayout {
                Layout.fillWidth: true
                Text { text: title; color: root.text; font.pixelSize: 18; Layout.fillWidth: true }
                Text { text: expanded ? "⌃" : "⌄"; color: root.muted; font.pixelSize: 22 }
            }
            Text {
                visible: expanded
                text: body
                color: root.muted
                font.pixelSize: 15
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
        }
        MouseArea {
            anchors.fill: parent
            onClicked: expanded = !expanded
        }
    }
}
