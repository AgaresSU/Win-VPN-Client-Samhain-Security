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
                            opacity: 0.95
                        }
                        Rectangle {
                            width: parent.dialSize * 0.78
                            height: width
                            radius: width / 2
                            anchors.centerIn: parent
                            color: "#222027"
                            border.color: "#343141"
                            border.width: 2
                            opacity: 0.94
                        }
                        Rectangle {
                            width: parent.dialSize * 0.56
                            height: width
                            radius: width / 2
                            anchors.centerIn: parent
                            color: "#161417"
                            border.color: appController.connected ? root.accent : "#5C3339"
                            border.width: 2
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
                        Button {
                            width: root.tight ? 86 : 104
                            height: width
                            anchors.centerIn: parent
                            onClicked: appController.toggleConnection()
                            background: Rectangle {
                                radius: width / 2
                                color: appController.connected ? root.samhainRed : "#4B252C"
                                border.color: appController.connected ? "#CF5961" : "#7B3A42"
                                border.width: 2
                            }
                            contentItem: Column {
                                anchors.centerIn: parent
                                spacing: 4
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: "⏻"
                                    color: "white"
                                    font.pixelSize: 36
                                    font.bold: true
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: appController.connected ? appController.sessionTime : "Старт"
                                    color: "#F1EDEE"
                                    font.pixelSize: 12
                                }
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: root.tight ? 104 : 122
                        color: "#171517"
                        border.color: "#2F292C"
                        radius: 8
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 16
                            spacing: 8
                            Text {
                                text: appController.selectedServerFlag
                                color: root.text
                                font.pixelSize: root.tight ? 28 : 36
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
                                font.pixelSize: 14
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

                        Rectangle {
                            visible: selected && !isSubscription
                            width: 4
                            height: parent.height - 16
                            color: root.accent
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            radius: 2
                        }

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

                            Text { text: flag; font.pixelSize: 30; Layout.preferredWidth: 36 }
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
                SettingsCard {
                    title: "Режим"
                    ComboBox {
                        id: routeCombo
                        Layout.fillWidth: true
                        model: ["Весь компьютер", "Только выбранные приложения", "Кроме выбранных приложений"]
                        currentIndex: appController.routeModeIndex
                        onActivated: appController.routeModeIndex = currentIndex
                    }
                }
                SettingsCard {
                    title: "Приложения"
                    Text {
                        text: appController.routeAppCountLabel + " · " + appController.routePolicyStatus
                        color: root.muted
                        font.pixelSize: 16
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    Button {
                        text: "Изменить"
                        Layout.preferredWidth: 120
                        onClicked: appRoutingDialog.open()
                        background: Rectangle { color: "#333333"; radius: 8 }
                        contentItem: Text { text: parent.text; color: root.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    }
                }
                SettingsCard {
                    title: "Защита"
                    Text {
                        text: appController.protectionStatus
                        color: root.muted
                        font.pixelSize: 16
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    Button {
                        text: "Обновить"
                        Layout.preferredWidth: 120
                        onClicked: appController.refreshProtectionPolicy()
                        background: Rectangle { color: "#333333"; radius: 8 }
                        contentItem: Text { text: parent.text; color: root.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    }
                }
                SettingsCard {
                    title: "Интеграция"
                    Text {
                        text: appController.desktopIntegrationStatus
                        color: root.muted
                        font.pixelSize: 16
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    Switch {
                        checked: appController.autostartEnabled
                        onToggled: appController.setAutostartEnabled(checked)
                    }
                    Button {
                        text: "Ссылки"
                        Layout.preferredWidth: 104
                        onClicked: appController.registerLinkHandler()
                        background: Rectangle { color: "#333333"; radius: 8 }
                        contentItem: Text { text: parent.text; color: root.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
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
            MetricRow { title: "Версия"; value: "1.0.3" }
            MetricRow { title: "Интерфейс"; value: "Qt 6 / QML" }
            MetricRow { title: "Ядро"; value: "Rust workspace" }
            MetricRow { title: "Статус"; value: appController.statusText }
            Item { Layout.fillHeight: true }
        }
    }

    component NavButton: Button {
        property string iconText: ""
        property string label: ""
        property bool active: false
        Layout.fillWidth: true
        Layout.preferredHeight: root.compact ? 56 : 60
        leftPadding: 0
        rightPadding: 0
        background: Rectangle {
            color: active ? "#090708" : "transparent"
            radius: 6
            Rectangle {
                visible: active
                width: 5
                height: parent.height - 20
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                color: root.accent
                radius: 2
            }
        }
        contentItem: RowLayout {
            spacing: root.compact ? 0 : 18
            anchors.leftMargin: root.compact ? 22 : 22
            anchors.rightMargin: root.compact ? 22 : 10
            Text { text: iconText; color: root.text; font.pixelSize: 28; Layout.preferredWidth: 38; horizontalAlignment: Text.AlignHCenter }
            Text { visible: !root.compact; text: label; color: root.text; font.pixelSize: 22; Layout.fillWidth: true; elide: Text.ElideRight }
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

    component SettingsCard: Rectangle {
        default property alias content: contentRow.data
        property string title: ""
        Layout.fillWidth: true
        Layout.preferredHeight: 72
        color: root.fieldHot
        radius: 6
        border.color: root.line
        RowLayout {
            id: contentRow
            anchors.fill: parent
            anchors.leftMargin: 20
            anchors.rightMargin: 20
            spacing: 16
            Text { text: title; color: root.text; font.pixelSize: 18; Layout.fillWidth: true }
        }
    }

    component AdvancedSettingsBox: Rectangle {
        property bool expanded: false
        Layout.fillWidth: true
        Layout.preferredHeight: expanded ? 860 : 72
        color: root.fieldHot
        radius: 6
        border.color: root.line
        clip: true

        ColumnLayout {
            anchors.fill: parent
            spacing: 14

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
                spacing: 12

                Text {
                    text: "Статус: " + appController.engineStatus
                    color: root.text
                    font.pixelSize: 17
                    font.bold: true
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
                Text {
                    text: appController.engineDetail
                    color: root.muted
                    font.pixelSize: 14
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                    maximumLineCount: 3
                    elide: Text.ElideRight
                }
                Text {
                    text: "Proxy path: " + appController.proxyStatus
                    color: root.text
                    font.pixelSize: 16
                    font.bold: true
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
                Text {
                    text: appController.proxyDetail
                    color: root.muted
                    font.pixelSize: 13
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }
                Text {
                    text: "TUN path: " + appController.tunStatus
                    color: root.text
                    font.pixelSize: 16
                    font.bold: true
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
                Text {
                    text: appController.tunDetail
                    color: root.muted
                    font.pixelSize: 13
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }
                Text {
                    text: "Защита: " + appController.protectionStatus
                    color: root.text
                    font.pixelSize: 16
                    font.bold: true
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
                Text {
                    text: appController.protectionDetail
                    color: root.muted
                    font.pixelSize: 13
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                    maximumLineCount: 3
                    elide: Text.ElideRight
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Button {
                        text: "Обновить"
                        Layout.preferredWidth: 118
                        onClicked: appController.refreshEngineStatus()
                        background: Rectangle { color: "#242424"; radius: 8 }
                        contentItem: Text { text: parent.text; color: root.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    }
                    Button {
                        text: "Preview"
                        Layout.preferredWidth: 118
                        onClicked: appController.previewSelectedEngineConfig()
                        background: Rectangle { color: "#242424"; radius: 8 }
                        contentItem: Text { text: parent.text; color: root.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    }
                    Button {
                        text: "Restart"
                        Layout.preferredWidth: 118
                        onClicked: appController.restartEngine()
                        background: Rectangle { color: "#242424"; radius: 8 }
                        contentItem: Text { text: parent.text; color: root.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    }
                    Button {
                        text: "Stop"
                        Layout.preferredWidth: 90
                        onClicked: appController.stopEngine()
                        background: Rectangle { color: "#3B2020"; radius: 8 }
                        contentItem: Text { text: parent.text; color: root.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    }
                    Item { Layout.fillWidth: true }
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Button {
                        text: "Proxy"
                        Layout.preferredWidth: 118
                        onClicked: appController.refreshProxyStatus()
                        background: Rectangle { color: "#242424"; radius: 8 }
                        contentItem: Text { text: parent.text; color: root.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    }
                    Button {
                        text: "Restore"
                        Layout.preferredWidth: 118
                        onClicked: appController.restoreProxyPolicy()
                        background: Rectangle { color: "#3B2020"; radius: 8 }
                        contentItem: Text { text: parent.text; color: root.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    }
                    Button {
                        text: "TUN"
                        Layout.preferredWidth: 118
                        onClicked: appController.refreshTunStatus()
                        background: Rectangle { color: "#242424"; radius: 8 }
                        contentItem: Text { text: parent.text; color: root.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    }
                    Button {
                        text: "Restore TUN"
                        Layout.preferredWidth: 132
                        onClicked: appController.restoreTunPolicy()
                        background: Rectangle { color: "#3B2020"; radius: 8 }
                        contentItem: Text { text: parent.text; color: root.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    }
                    Item { Layout.fillWidth: true }
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Button {
                        text: "Защита"
                        Layout.preferredWidth: 118
                        onClicked: appController.refreshProtectionPolicy()
                        background: Rectangle { color: "#242424"; radius: 8 }
                        contentItem: Text { text: parent.text; color: root.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    }
                    Button {
                        text: "Восстановить"
                        Layout.preferredWidth: 118
                        onClicked: appController.restoreProtectionPolicy()
                        background: Rectangle { color: "#3B2020"; radius: 8 }
                        contentItem: Text { text: parent.text; color: root.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    }
                    Button {
                        text: "Восстановить всё"
                        Layout.preferredWidth: 170
                        onClicked: appController.emergencyRestore()
                        background: Rectangle { color: "#4A2020"; radius: 8 }
                        contentItem: Text { text: parent.text; color: root.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    }
                    Item { Layout.fillWidth: true }
                }
                Text {
                    text: "Каталог:\n" + (appController.engineCatalog.length > 0 ? appController.engineCatalog.join("\n") : "нет данных")
                    color: root.muted
                    font.pixelSize: 13
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                    maximumLineCount: 5
                    elide: Text.ElideRight
                }
                ScrollView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
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
