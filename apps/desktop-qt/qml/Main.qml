import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ApplicationWindow {
    id: root
    width: 1496
    height: 998
    minimumWidth: 1180
    minimumHeight: 760
    visible: true
    title: "Samhain Security"
    color: "#111111"

    readonly property color bg: "#111111"
    readonly property color rail: "#171717"
    readonly property color panel: "#202020"
    readonly property color panelHot: "#303030"
    readonly property color row: "#242424"
    readonly property color rowSelected: "#484848"
    readonly property color text: "#F2F2F2"
    readonly property color muted: "#A8A8AE"
    readonly property color line: "#3A3A3D"
    readonly property color accent: "#756BFF"
    readonly property color samhainRed: "#C9343D"

    Shortcut {
        sequences: [StandardKey.Paste]
        onActivated: appController.pasteFromClipboard()
    }

    Dialog {
        id: addDialog
        modal: true
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        width: 520
        height: 360
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

            RowLayout {
                Layout.fillWidth: true
                Text {
                    text: "Добавить подписку"
                    color: root.text
                    font.pixelSize: 28
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
                        font.pixelSize: 34
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
                placeholderTextColor: "#77777F"
                background: Rectangle {
                    color: "#3A3A3A"
                    radius: 8
                    border.color: subscriptionNameInput.activeFocus ? root.accent : "#4A4A4A"
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
                placeholderTextColor: "#77777F"
                background: Rectangle {
                    color: "#3A3A3A"
                    radius: 8
                    border.color: subscriptionUrlInput.activeFocus ? root.accent : "#4A4A4A"
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                Button {
                    text: "Из буфера"
                    Layout.preferredWidth: 132
                    height: 48
                    onClicked: appController.pasteFromClipboard()
                    background: Rectangle { color: "#333333"; radius: 8 }
                    contentItem: Text { text: parent.text; color: root.text; font.pixelSize: 16; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                }
                Button {
                    text: "Добавить"
                    Layout.preferredWidth: 132
                    height: 48
                    onClicked: {
                        appController.addSubscription(subscriptionNameInput.text, subscriptionUrlInput.text)
                        addDialog.close()
                    }
                    background: Rectangle { color: root.accent; radius: 8 }
                    contentItem: Text { text: parent.text; color: "white"; font.pixelSize: 16; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
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

    Rectangle {
        anchors.fill: parent
        color: root.bg

        RowLayout {
            anchors.fill: parent
            spacing: 0

            Rectangle {
                Layout.preferredWidth: 246
                Layout.fillHeight: true
                color: root.rail

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 0
                    spacing: 0

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 84
                        Layout.leftMargin: 22
                        Layout.rightMargin: 18
                        spacing: 14

                        Text {
                            text: "←"
                            color: root.text
                            font.pixelSize: 34
                            Layout.preferredWidth: 42
                        }
                        Text {
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
                Layout.preferredWidth: 626
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
                color: "#191B22"
                clip: true

                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "#20232D" }
                        GradientStop { position: 1.0; color: "#15171D" }
                    }
                }
                Rectangle {
                    width: parent.width * 1.15
                    height: parent.height * 0.62
                    x: parent.width * 0.08
                    y: parent.height * 0.35
                    rotation: 38
                    radius: 80
                    color: "#11131A"
                    opacity: 0.7
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 44
                    spacing: 26

                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 520

                        Rectangle {
                            width: 334
                            height: 334
                            radius: 167
                            anchors.centerIn: parent
                            color: "transparent"
                            border.color: "#35205F"
                            border.width: 2
                        }
                        Rectangle {
                            width: 238
                            height: 238
                            radius: 119
                            anchors.centerIn: parent
                            color: "#30364A"
                            opacity: 0.92
                        }
                        Rectangle {
                            width: 174
                            height: 174
                            radius: 87
                            anchors.centerIn: parent
                            color: "#1C202B"
                            border.color: "#515A78"
                            border.width: 3
                        }
                        Button {
                            width: 110
                            height: 110
                            anchors.centerIn: parent
                            onClicked: appController.toggleConnection()
                            background: Rectangle {
                                radius: 55
                                color: appController.connected ? root.samhainRed : root.accent
                                border.color: appController.connected ? "#F28B91" : "#9C95FF"
                                border.width: 2
                            }
                            contentItem: Column {
                                anchors.centerIn: parent
                                spacing: 6
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: "⏻"
                                    color: "white"
                                    font.pixelSize: 38
                                    font.bold: true
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: appController.connected ? "ПОДКЛЮЧЁН" : "ГОТОВ"
                                    color: "#D8D8E6"
                                    font.pixelSize: 12
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: appController.connected ? appController.sessionTime : ""
                                    color: "white"
                                    font.pixelSize: 13
                                }
                            }
                        }
                    }

                    Text {
                        text: appController.selectedServerFlag
                        color: root.text
                        font.pixelSize: 46
                        Layout.alignment: Qt.AlignHCenter
                    }
                    Text {
                        text: appController.selectedServerName
                        color: root.text
                        font.pixelSize: 22
                        Layout.alignment: Qt.AlignHCenter
                        horizontalAlignment: Text.AlignHCenter
                    }
                    Text {
                        text: appController.selectedServerProtocol + " · " + appController.selectedServerPing
                        color: root.muted
                        font.pixelSize: 15
                        Layout.alignment: Qt.AlignHCenter
                    }
                    Button {
                        text: "Тест пинга"
                        Layout.preferredWidth: 288
                        Layout.preferredHeight: 48
                        Layout.alignment: Qt.AlignHCenter
                        onClicked: appController.testPing()
                        background: Rectangle { radius: 6; color: root.accent }
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
                        Layout.preferredHeight: 92
                        color: "#1C1F28"
                        border.color: "#2F3444"
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
            anchors.margins: 36
            spacing: 22

            Text {
                text: "Серверы"
                color: root.text
                font.pixelSize: 36
                font.bold: true
            }

            RowLayout {
                Layout.fillWidth: true
                TextField {
                    id: searchField
                    Layout.fillWidth: true
                    Layout.preferredHeight: 60
                    color: root.text
                    placeholderText: "Введите текст для поиска"
                    placeholderTextColor: root.muted
                    font.pixelSize: 18
                    background: Rectangle {
                        color: "#1B1B1B"
                        radius: 6
                        border.color: searchField.activeFocus ? root.accent : "#6A6A70"
                        border.width: 2
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
                        height: isSubscription ? 78 : 72
                        color: isSubscription ? "#343434" : (selected ? root.rowSelected : root.row)
                        border.color: "#3A3A3A"
                        border.width: 1
                        radius: isSubscription ? 8 : 0

                        Rectangle {
                            visible: selected && !isSubscription
                            width: 5
                            height: parent.height
                            color: root.accent
                            anchors.left: parent.left
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
                                font.pixelSize: 24
                                Layout.preferredWidth: 24
                                horizontalAlignment: Text.AlignHCenter
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 5
                                Text {
                                    text: name
                                    color: root.text
                                    font.pixelSize: 20
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
                            ButtonIcon {
                                label: "✎"
                                onClicked: {
                                    renameDialog.rowIndex = index
                                    renameSubscriptionNameInput.text = name
                                    renameDialog.open()
                                }
                            }
                            ButtonIcon { label: "⧉"; onClicked: appController.copySubscriptionDiagnostics(index) }
                            ButtonIcon { label: "×"; danger: true; onClicked: appController.deleteSubscription(index) }
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
                                    font.pixelSize: 19
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
                                color: root.text
                                font.pixelSize: 14
                                Layout.preferredWidth: 72
                                horizontalAlignment: Text.AlignRight
                            }
                            Text { text: "›"; color: root.muted; font.pixelSize: 26 }
                        }
                    }
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
                spacing: 22
                anchors.margins: 36
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
                    Text { text: appController.routeModeIndex === 0 ? "Не требуется" : "0 выбрано"; color: root.muted; font.pixelSize: 16 }
                    Button {
                        text: "Изменить"
                        Layout.preferredWidth: 120
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
            anchors.margins: 36
            spacing: 18
            PageTitle { text: "Статистика" }
            MetricRow { title: "Время подключения"; value: appController.sessionTime }
            MetricRow { title: "Загрузка"; value: appController.downloadSpeed }
            MetricRow { title: "Выгрузка"; value: appController.uploadSpeed }
            MetricRow { title: "Трафик за сессию"; value: appController.sessionTraffic }
            Item { Layout.fillHeight: true }
        }
    }

    Component {
        id: logsPage
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 36
            spacing: 18
            RowLayout {
                Layout.fillWidth: true
                PageTitle { text: "Логи"; Layout.fillWidth: true }
                Button {
                    text: "Очистить"
                    onClicked: appController.clearLogs()
                    background: Rectangle { color: "#333333"; radius: 8 }
                    contentItem: Text { text: parent.text; color: root.text; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                }
            }
            ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
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
        }
    }

    Component {
        id: aboutPage
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 36
            spacing: 18
            PageTitle { text: "О программе" }
            MetricRow { title: "Программа"; value: "Samhain Security Native" }
            MetricRow { title: "Версия"; value: "0.7.9" }
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
        Layout.preferredHeight: 60
        leftPadding: 0
        rightPadding: 0
        background: Rectangle {
            color: active ? "#000000" : "transparent"
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
            spacing: 18
            anchors.leftMargin: 22
            anchors.rightMargin: 10
            Text { text: iconText; color: root.text; font.pixelSize: 28; Layout.preferredWidth: 38; horizontalAlignment: Text.AlignHCenter }
            Text { text: label; color: root.text; font.pixelSize: 22; Layout.fillWidth: true; elide: Text.ElideRight }
        }
    }

    component ButtonIcon: Button {
        property string label: ""
        property bool danger: false
        Layout.preferredWidth: 46
        Layout.preferredHeight: 46
        background: Rectangle { color: "transparent"; radius: 23 }
        contentItem: Text {
            text: label
            color: danger ? root.samhainRed : root.muted
            font.pixelSize: 28
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    component Chip: Rectangle {
        property string text: ""
        width: 78
        height: 36
        radius: 6
        color: root.accent
        border.color: "#A19BFF"
        Text { anchors.centerIn: parent; text: parent.text; color: "white"; font.pixelSize: 18 }
    }

    component StatText: ColumnLayout {
        property string title: ""
        property string value: ""
        Layout.fillWidth: true
        spacing: 4
        Text { text: title; color: root.muted; font.pixelSize: 13 }
        Text { text: value; color: root.text; font.pixelSize: 17; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
    }

    component PageTitle: Text {
        color: root.text
        font.pixelSize: 36
        font.bold: true
    }

    component MetricRow: Rectangle {
        property string title: ""
        property string value: ""
        Layout.fillWidth: true
        Layout.preferredHeight: 66
        color: "#333333"
        radius: 6
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 20
            anchors.rightMargin: 20
            Text { text: title; color: root.text; font.pixelSize: 18; Layout.fillWidth: true }
            Text { text: value; color: root.muted; font.pixelSize: 18; horizontalAlignment: Text.AlignRight }
        }
    }

    component SettingsCard: Rectangle {
        default property alias content: contentRow.data
        property string title: ""
        Layout.fillWidth: true
        Layout.preferredHeight: 72
        color: "#333333"
        radius: 6
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
        Layout.preferredHeight: expanded ? 720 : 72
        color: "#333333"
        radius: 6
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
