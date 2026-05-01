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
    palette.window: bg
    palette.windowText: text
    palette.base: field
    palette.alternateBase: panel
    palette.text: text
    palette.button: field
    palette.buttonText: text
    palette.highlight: "#4A2228"
    palette.highlightedText: text
    palette.link: accent

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

    function routeModeTitle() {
        if (appController.routeModeIndex === 1) {
            return "Только выбранные"
        }
        if (appController.routeModeIndex === 2) {
            return "Исключения"
        }
        return "Весь компьютер"
    }

    function routeModeBody() {
        if (appController.routeModeIndex === 1) {
            return "Через туннель идут только приложения из списка."
        }
        if (appController.routeModeIndex === 2) {
            return "Весь компьютер идет через туннель, кроме приложений из списка."
        }
        return "Список приложений не используется в этом режиме."
    }

    function routeEmptyBody() {
        if (appController.routeModeIndex === 1) {
            return "Добавьте приложения, которые должны идти через туннель."
        }
        if (appController.routeModeIndex === 2) {
            return "Добавьте приложения, которые должны идти мимо туннеля."
        }
        return "Переключите режим работы, чтобы использовать список."
    }

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
                DialogIconButton {
                    symbol: "×"
                    onClicked: addDialog.close()
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
                DialogActionButton {
                    text: "Отмена"
                    Layout.preferredWidth: 118
                    onClicked: addDialog.close()
                }
                DialogActionButton {
                    text: "Из буфера"
                    Layout.preferredWidth: 126
                    onClicked: {
                        appController.pasteFromClipboard()
                        addDialog.close()
                    }
                }
                DialogActionButton {
                    text: "Добавить"
                    enabled: subscriptionUrlInput.text.trim().length > 0
                    Layout.preferredWidth: 126
                    accentButton: true
                    onClicked: {
                        appController.addSubscription(subscriptionNameInput.text, subscriptionUrlInput.text)
                        addDialog.close()
                    }
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
            color: "#201C1E"
            radius: 12
            border.color: "#3E3337"
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
                    color: root.field
                    radius: 6
                    border.color: renameSubscriptionNameInput.activeFocus ? root.accent : "#463B3F"
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                DialogActionButton {
                    text: "Отмена"
                    Layout.preferredWidth: 120
                    onClicked: renameDialog.close()
                }
                DialogActionButton {
                    text: "Сохранить"
                    Layout.preferredWidth: 132
                    accentButton: true
                    onClicked: {
                        appController.renameSubscription(renameDialog.rowIndex, renameSubscriptionNameInput.text)
                        renameDialog.close()
                    }
                }
            }
        }
    }

    Popup {
        id: subscriptionActionsPopup
        parent: Overlay.overlay
        property int rowIndex: -1
        property string subscriptionName: ""
        width: 286
        height: subscriptionActionsColumn.implicitHeight + 12
        padding: 6
        modal: false
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        function openFor(row, button, name) {
            rowIndex = row
            subscriptionName = name
            var point = button.mapToItem(Overlay.overlay, button.width - subscriptionActionsPopup.width, button.height + 6)
            x = Math.max(8, Math.min(point.x, root.width - subscriptionActionsPopup.width - 8))
            y = Math.max(8, Math.min(point.y, root.height - subscriptionActionsPopup.height - 8))
            open()
        }

        background: Rectangle {
            color: "#302D2B"
            radius: 6
            border.color: "#514A47"
        }

        contentItem: ColumnLayout {
            id: subscriptionActionsColumn
            spacing: 0

            PopupAction {
                iconKind: "refresh"
                text: "Обновить"
                onTriggered: {
                    var row = subscriptionActionsPopup.rowIndex
                    subscriptionActionsPopup.close()
                    appController.refreshSubscription(row)
                }
            }
            PopupDivider {}
            PopupAction {
                iconKind: "latency"
                text: "Тест пинга"
                onTriggered: {
                    var row = subscriptionActionsPopup.rowIndex
                    subscriptionActionsPopup.close()
                    appController.testSubscriptionPings(row)
                }
            }
            PopupDivider {}
            PopupAction {
                iconKind: "pin"
                text: "Закрепить"
                onTriggered: {
                    var row = subscriptionActionsPopup.rowIndex
                    subscriptionActionsPopup.close()
                    appController.pinSubscription(row)
                }
            }
            PopupDivider {}
            PopupAction {
                iconKind: "copy"
                text: "Копировать URL"
                onTriggered: {
                    var row = subscriptionActionsPopup.rowIndex
                    subscriptionActionsPopup.close()
                    appController.copySubscriptionUrl(row)
                }
            }
            PopupDivider {}
            PopupAction {
                iconKind: "edit"
                text: "Редактировать"
                onTriggered: {
                    var row = subscriptionActionsPopup.rowIndex
                    var name = subscriptionActionsPopup.subscriptionName
                    subscriptionActionsPopup.close()
                    renameDialog.rowIndex = row
                    renameSubscriptionNameInput.text = name
                    renameDialog.open()
                }
            }
            PopupDivider {}
            PopupAction {
                iconKind: "delete"
                text: "Удалить"
                danger: true
                onTriggered: {
                    var row = subscriptionActionsPopup.rowIndex
                    subscriptionActionsPopup.close()
                    appController.deleteSubscription(row)
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
        width: Math.min(root.width - 80, 760)
        height: Math.min(root.height - 80, 650)
        padding: 0
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            color: "#171314"
            radius: 18
            border.color: "#3A2D31"
        }

        contentItem: ColumnLayout {
            spacing: 14
            anchors.fill: parent
            anchors.margins: 34

            RowLayout {
                Layout.fillWidth: true
                spacing: 14
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    Text {
                        text: "Приложения"
                        color: root.text
                        font.pixelSize: 28
                        font.bold: true
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                    }
                    Text {
                        text: appController.routePolicyStatus
                        color: root.muted
                        font.pixelSize: 14
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                    }
                }
                RouteStatePill {
                    text: root.routeModeTitle()
                    active: appController.routeModeIndex !== 0
                }
                DialogIconButton {
                    symbol: "×"
                    onClicked: appRoutingDialog.close()
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 76
                color: root.panelHot
                radius: 8
                border.color: root.line
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 18
                    anchors.rightMargin: 18
                    spacing: 14
                    Rectangle {
                        Layout.preferredWidth: 40
                        Layout.preferredHeight: 40
                        radius: 10
                        color: "#211B1D"
                        border.color: "#4A353A"
                        Text {
                            anchors.centerIn: parent
                            text: "↔"
                            color: root.accent
                            font.pixelSize: 22
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        Text {
                            text: root.routeModeTitle()
                            color: root.text
                            font.pixelSize: 17
                            font.bold: true
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                        }
                        Text {
                            text: root.routeModeBody()
                            color: root.muted
                            font.pixelSize: 14
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                        }
                    }
                    Text {
                        text: appController.routeAppCountLabel
                        color: root.text
                        font.pixelSize: 15
                        font.bold: true
                        horizontalAlignment: Text.AlignRight
                        Layout.maximumWidth: 140
                        elide: Text.ElideRight
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: root.field
                radius: 8
                border.color: root.line
                clip: true

                ListView {
                    id: routeAppList
                    anchors.fill: parent
                    anchors.margins: 8
                    clip: true
                    spacing: 4
                    model: appController.routeApplicationItems
                    delegate: Rectangle {
                        id: routeAppRow
                        width: ListView.view.width
                        height: 70
                        radius: 7
                        color: routeAppHover.hovered ? "#2B2326" : (index % 2 === 0 ? "#211D1F" : "#1B1819")
                        border.color: routeAppHover.hovered ? "#46373C" : "transparent"
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 10
                            spacing: 12
                            Rectangle {
                                Layout.preferredWidth: 38
                                Layout.preferredHeight: 38
                                radius: 10
                                color: "#171516"
                                border.color: "#4A353A"
                                Text {
                                    anchors.centerIn: parent
                                    text: "EXE"
                                    color: root.muted
                                    font.pixelSize: 12
                                    font.bold: true
                                }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 4
                                Text {
                                    text: modelData.name
                                    color: root.text
                                    font.pixelSize: 16
                                    font.bold: true
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                }
                                Text {
                                    text: modelData.path
                                    color: root.muted
                                    font.pixelSize: 12
                                    Layout.fillWidth: true
                                    elide: Text.ElideMiddle
                                }
                            }
                            RouteStatePill {
                                text: modelData.state
                                active: appController.routeModeIndex !== 0
                                Layout.maximumWidth: 130
                            }
                            DialogIconButton {
                                symbol: "×"
                                danger: true
                                onClicked: appController.removeRouteApplication(index)
                            }
                        }
                        HoverHandler { id: routeAppHover }
                    }
                }

                EmptyState {
                    anchors.centerIn: parent
                    visible: routeAppList.count === 0
                    title: "Список пуст"
                    body: root.routeEmptyBody()
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                TextField {
                    id: appPathInput
                    Layout.fillWidth: true
                    height: 46
                    color: root.text
                    placeholderText: "C:\\Program Files\\App\\app.exe"
                    placeholderTextColor: "#777177"
                    selectByMouse: true
                    background: Rectangle {
                        color: root.field
                        radius: 8
                        border.color: appPathInput.activeFocus ? root.accent : "#4A3A3F"
                    }
                }
                DialogActionButton {
                    text: "Выбрать"
                    Layout.preferredWidth: 112
                    onClicked: appFileDialog.open()
                }
                DialogActionButton {
                    text: "Добавить"
                    accentButton: true
                    Layout.preferredWidth: 112
                    enabled: appPathInput.text.trim().length > 0
                    onClicked: {
                        appController.addRouteApplication(appPathInput.text)
                        appPathInput.text = ""
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Text {
                    text: appController.routePolicyDetail
                    color: root.muted
                    font.pixelSize: 13
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
                DialogActionButton {
                    text: "Восстановить"
                    Layout.preferredWidth: 136
                    danger: true
                    onClicked: appController.restoreAppRoutingPolicy()
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
                        iconKind: "add"
                        active: appController.page === "add"
                        onClicked: {
                            appController.navigate("add")
                            addDialog.open()
                        }
                    }
                    NavButton {
                        label: "Серверы"
                        iconKind: "servers"
                        active: appController.page === "servers"
                        onClicked: appController.navigate("servers")
                    }
                    NavButton {
                        label: "Настройки"
                        iconKind: "settings"
                        active: appController.page === "settings"
                        onClicked: appController.navigate("settings")
                    }
                    NavButton {
                        label: "Статистика"
                        iconKind: "stats"
                        active: appController.page === "stats"
                        onClicked: appController.navigate("stats")
                    }
                    NavButton {
                        label: "Логи"
                        iconKind: "logs"
                        active: appController.page === "logs"
                        onClicked: appController.navigate("logs")
                    }

                    Item { Layout.fillHeight: true }

                    NavButton {
                        label: "О программе"
                        iconKind: "about"
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
                        GradientStop { position: 0.0; color: "#141113" }
                        GradientStop { position: 1.0; color: "#0C0D0F" }
                    }
                }
                Rectangle {
                    width: parent.width * 1.12
                    height: parent.height * 0.60
                    x: parent.width * 0.06
                    y: parent.height * 0.36
                    rotation: 38
                    radius: 80
                    color: "#100E10"
                    opacity: 0.38
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
                        color: appController.connected ? "#14211B" : "#191719"
                        border.color: appController.connected ? "#2F6F55" : "#342B2E"
                        Text {
                            anchors.centerIn: parent
                            text: appController.connected ? "Подключён" : "Ожидание"
                            color: appController.connected ? "#75B28F" : root.muted
                            font.pixelSize: 15
                            font.bold: true
                        }
                    }

                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: root.tight ? 290 : 374
                        property int dialSize: root.tight ? 230 : 306

                        Rectangle {
                            width: parent.dialSize * 0.88
                            height: width
                            radius: width / 2
                            anchors.centerIn: parent
                            color: "transparent"
                            border.color: appController.connected ? "#173628" : "#272025"
                            border.width: 1
                            opacity: 0.74
                        }
                        Rectangle {
                            width: parent.dialSize * 0.66
                            height: width
                            radius: width / 2
                            anchors.centerIn: parent
                            color: "transparent"
                            border.color: appController.connected ? "#28463B" : "#26242C"
                            border.width: root.tight ? 26 : 34
                            opacity: appController.connected ? 0.58 : 0.34
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
                        color: "#131112"
                        border.color: "#2A2225"
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

                    RightActionButton {
                        text: "Тест пинга"
                        Layout.preferredWidth: 288
                        Layout.preferredHeight: root.tight ? 42 : 48
                        Layout.alignment: Qt.AlignHCenter
                        onClicked: appController.testPing()
                    }

                    RowLayout {
                        Layout.alignment: Qt.AlignHCenter
                        spacing: 8
                        PathChip {
                            text: root.routeModeTitle()
                            active: true
                            onClicked: appController.openAdvancedSettings()
                        }
                        PathChip {
                            text: appController.routeModeIndex === 0 ? "Маршрут" : appController.routeAppCountLabel
                            active: appController.routeModeIndex !== 0
                            onClicked: appRoutingDialog.open()
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: root.tight ? 80 : 92
                        color: "#131112"
                        border.color: "#2B2326"
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
                ButtonIcon { iconKind: "refresh"; onClicked: appController.testAllPings() }
                ButtonIcon { iconKind: "more"; onClicked: addDialog.open() }
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
                            ButtonIcon {
                                iconKind: "refresh"
                                onClicked: appController.refreshSubscription(index)
                            }
                            ButtonIcon {
                                id: subscriptionActionsButton
                                iconKind: "more"
                                onClicked: subscriptionActionsPopup.openFor(index, subscriptionActionsButton, name)
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
                    iconKind: "copy"
                    label: "Из буфера"
                    onClicked: appController.pasteFromClipboard()
                }
                QuickActionButton {
                    iconKind: "add"
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
                    title: "Список приложений"
                    subtitle: appController.routeAppCountLabel + " · " + appController.routePolicyStatus
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
                QuietButton {
                    text: "Обновить"
                    Layout.preferredWidth: 110
                    onClicked: appController.refreshServiceLogs()
                }
                QuietButton {
                    text: "Экспорт"
                    Layout.preferredWidth: 104
                    accentButton: true
                    onClicked: appController.exportSupportBundle()
                }
                QuietButton {
                    text: "Очистить"
                    Layout.preferredWidth: 104
                    onClicked: appController.clearLogs()
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
            MetricRow { title: "Версия"; value: "1.5.1" }
            MetricRow { title: "Интерфейс"; value: "Qt 6 / QML" }
            MetricRow { title: "Ядро"; value: "Rust workspace" }
            MetricRow { title: "Статус"; value: appController.statusText }
            Item { Layout.fillHeight: true }
        }
    }

    component NavButton: Rectangle {
        id: navButton
        property string iconKind: ""
        property string label: ""
        property bool active: false
        signal clicked()
        Layout.fillWidth: true
        Layout.preferredHeight: root.compact ? 54 : 62
        Layout.leftMargin: root.compact ? 6 : 8
        Layout.rightMargin: root.compact ? 6 : 10
        color: active ? "#090708" : (navMouse.containsMouse ? "#171214" : "transparent")
        radius: 8
        border.color: active ? "#3A2930" : "transparent"
        border.width: 1

        RowLayout {
            anchors.fill: parent
            spacing: root.compact ? 0 : 14
            anchors.leftMargin: root.compact ? 14 : 16
            anchors.rightMargin: root.compact ? 14 : 14

            NavIcon {
                iconKind: navButton.iconKind
                active: navButton.active
                hovered: navMouse.containsMouse
                Layout.preferredWidth: 34
                Layout.preferredHeight: 34
            }
            Text {
                visible: !root.compact
                text: navButton.label
                color: navButton.active ? "#FFFFFF" : root.text
                font.pixelSize: 18
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

    component NavIcon: Canvas {
        id: navIcon
        property string iconKind: ""
        property bool active: false
        property bool hovered: false
        implicitWidth: 34
        implicitHeight: 34
        onIconKindChanged: requestPaint()
        onActiveChanged: requestPaint()
        onHoveredChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
            var ctx = getContext("2d")
            var w = width
            var h = height
            var color = active ? "#FFFFFF" : (hovered ? "#E8E1E4" : "#F2F0F0")
            ctx.clearRect(0, 0, w, h)
            ctx.save()
            ctx.translate(w / 2, h / 2)
            ctx.scale(Math.min(w, h) / 34, Math.min(w, h) / 34)
            ctx.translate(-17, -17)
            ctx.strokeStyle = color
            ctx.fillStyle = color
            ctx.lineWidth = 2
            ctx.lineCap = "round"
            ctx.lineJoin = "round"

            function roundedRect(x, y, rw, rh, radius) {
                ctx.beginPath()
                ctx.moveTo(x + radius, y)
                ctx.lineTo(x + rw - radius, y)
                ctx.quadraticCurveTo(x + rw, y, x + rw, y + radius)
                ctx.lineTo(x + rw, y + rh - radius)
                ctx.quadraticCurveTo(x + rw, y + rh, x + rw - radius, y + rh)
                ctx.lineTo(x + radius, y + rh)
                ctx.quadraticCurveTo(x, y + rh, x, y + rh - radius)
                ctx.lineTo(x, y + radius)
                ctx.quadraticCurveTo(x, y, x + radius, y)
            }

            if (iconKind === "add") {
                roundedRect(5, 5, 24, 24, 6)
                ctx.stroke()
                ctx.beginPath()
                ctx.moveTo(17, 11)
                ctx.lineTo(17, 23)
                ctx.moveTo(11, 17)
                ctx.lineTo(23, 17)
                ctx.stroke()
            } else if (iconKind === "servers") {
                ctx.beginPath()
                ctx.arc(17, 17, 12, 0, Math.PI * 2)
                ctx.stroke()
                ctx.beginPath()
                ctx.moveTo(5, 17)
                ctx.lineTo(29, 17)
                ctx.moveTo(17, 5)
                ctx.bezierCurveTo(12, 9, 12, 25, 17, 29)
                ctx.moveTo(17, 5)
                ctx.bezierCurveTo(22, 9, 22, 25, 17, 29)
                ctx.moveTo(8, 10.5)
                ctx.lineTo(26, 10.5)
                ctx.moveTo(8, 23.5)
                ctx.lineTo(26, 23.5)
                ctx.stroke()
            } else if (iconKind === "settings") {
                ctx.lineWidth = 1.9
                ctx.beginPath()
                for (var i = 0; i < 24; ++i) {
                    var a = -Math.PI / 2 + i * Math.PI / 12
                    var tooth = i % 3 === 0
                    var r1 = tooth ? 13 : 10.2
                    var x = 17 + Math.cos(a) * r1
                    var y = 17 + Math.sin(a) * r1
                    if (i === 0) {
                        ctx.moveTo(x, y)
                    } else {
                        ctx.lineTo(x, y)
                    }
                }
                ctx.closePath()
                ctx.stroke()
                ctx.beginPath()
                ctx.arc(17, 17, 5.1, 0, Math.PI * 2)
                ctx.stroke()
            } else if (iconKind === "stats") {
                roundedRect(6, 7, 22, 20, 5)
                ctx.stroke()
                ctx.beginPath()
                ctx.moveTo(10, 20)
                ctx.lineTo(14, 20)
                ctx.lineTo(16, 15)
                ctx.lineTo(20, 23)
                ctx.lineTo(23, 14)
                ctx.lineTo(26, 14)
                ctx.stroke()
            } else if (iconKind === "logs") {
                roundedRect(8, 8, 18, 20, 4)
                ctx.stroke()
                ctx.beginPath()
                ctx.moveTo(13, 8)
                ctx.lineTo(13, 5)
                ctx.moveTo(21, 8)
                ctx.lineTo(21, 5)
                ctx.moveTo(13, 14)
                ctx.lineTo(22, 14)
                ctx.moveTo(13, 19)
                ctx.lineTo(21, 19)
                ctx.moveTo(13, 24)
                ctx.lineTo(19, 24)
                ctx.stroke()
            } else if (iconKind === "about") {
                ctx.beginPath()
                ctx.arc(17, 17, 12, 0, Math.PI * 2)
                ctx.stroke()
                ctx.beginPath()
                ctx.arc(17, 11, 1.1, 0, Math.PI * 2)
                ctx.fill()
                ctx.beginPath()
                ctx.moveTo(17, 16)
                ctx.lineTo(17, 23)
                ctx.stroke()
            }
            ctx.restore()
        }
    }

    component PowerButton: Rectangle {
        id: powerButton
        property bool connected: false
        property string label: ""
        signal clicked()
        color: "transparent"
        border.width: 0
        onConnectedChanged: powerCanvas.requestPaint()
        onWidthChanged: powerCanvas.requestPaint()
        onHeightChanged: powerCanvas.requestPaint()

        Canvas {
            id: powerCanvas
            anchors.fill: parent
            antialiasing: true
            onPaint: {
                var ctx = getContext("2d")
                var w = width
                var h = height
                var cx = w / 2
                var cy = h * 0.38
                var r = Math.min(w, h) * 0.18
                ctx.clearRect(0, 0, w, h)
                ctx.lineCap = "round"
                ctx.lineJoin = "round"
                ctx.strokeStyle = powerButton.connected ? "#2F7A5D" : "#B83A43"
                ctx.lineWidth = Math.max(5, w * 0.06)
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
            anchors.bottomMargin: 17
            text: powerButton.label
            color: powerButton.connected ? "#F1EDEE" : "#C8BFC2"
            opacity: 0.92
            font.pixelSize: 12
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: powerButton.clicked()
        }
    }

    component RightActionButton: Rectangle {
        id: actionButton
        property string text: ""
        signal clicked()
        radius: 8
        color: actionMouse.pressed ? "#331B20" : (actionMouse.containsMouse ? "#452329" : "#3A1E23")
        border.color: actionMouse.containsMouse ? "#8E3A43" : "#63313A"
        border.width: 1
        Text {
            anchors.centerIn: parent
            text: actionButton.text
            color: "#F1EDEE"
            font.pixelSize: 17
            font.bold: true
        }
        MouseArea {
            id: actionMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: actionButton.clicked()
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

    component ButtonIcon: Item {
        id: iconButton
        property string iconKind: ""
        property string label: ""
        property bool danger: false
        signal clicked()
        Layout.preferredWidth: 42
        Layout.preferredHeight: 42
        implicitWidth: 42
        implicitHeight: 42

        Rectangle {
            anchors.centerIn: parent
            width: 38
            height: 38
            radius: 8
            color: iconMouse.pressed ? "#2A1E22" : (iconMouse.containsMouse ? "#211A1D" : "transparent")
            border.color: iconMouse.containsMouse ? "#4A373D" : "transparent"
            border.width: 1
        }

        LineIcon {
            anchors.centerIn: parent
            width: 24
            height: 24
            iconKind: iconButton.iconKind.length > 0 ? iconButton.iconKind : iconButton.label
            iconColor: danger ? "#D4515A" : (iconMouse.containsMouse ? "#C9C1C5" : root.muted)
        }

        MouseArea {
            id: iconMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: iconButton.clicked()
        }
    }

    component LineIcon: Canvas {
        id: lineIcon
        property string iconKind: ""
        property color iconColor: root.muted
        implicitWidth: 24
        implicitHeight: 24
        antialiasing: true
        onIconKindChanged: requestPaint()
        onIconColorChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            var ctx = getContext("2d")
            var w = width
            var h = height
            var s = Math.min(w, h)
            ctx.clearRect(0, 0, w, h)
            ctx.save()
            ctx.translate(w / 2, h / 2)
            ctx.scale(s / 24, s / 24)
            ctx.translate(-12, -12)
            ctx.strokeStyle = iconColor
            ctx.fillStyle = iconColor
            ctx.lineWidth = 1.9
            ctx.lineCap = "round"
            ctx.lineJoin = "round"

            function roundedRect(x, y, rw, rh, radius) {
                ctx.beginPath()
                ctx.moveTo(x + radius, y)
                ctx.lineTo(x + rw - radius, y)
                ctx.quadraticCurveTo(x + rw, y, x + rw, y + radius)
                ctx.lineTo(x + rw, y + rh - radius)
                ctx.quadraticCurveTo(x + rw, y + rh, x + rw - radius, y + rh)
                ctx.lineTo(x + radius, y + rh)
                ctx.quadraticCurveTo(x, y + rh, x, y + rh - radius)
                ctx.lineTo(x, y + radius)
                ctx.quadraticCurveTo(x, y, x + radius, y)
            }

            if (iconKind === "refresh" || iconKind === "↻") {
                ctx.beginPath()
                ctx.arc(12, 12, 7.2, Math.PI * 0.18, Math.PI * 1.58)
                ctx.stroke()
                ctx.beginPath()
                ctx.moveTo(5.5, 5.5)
                ctx.lineTo(5.5, 10.2)
                ctx.lineTo(10.2, 10.2)
                ctx.stroke()
            } else if (iconKind === "more" || iconKind === "⋯") {
                for (var i = 0; i < 3; ++i) {
                    ctx.beginPath()
                    ctx.arc(7 + i * 5, 12, 1.15, 0, Math.PI * 2)
                    ctx.fill()
                }
            } else if (iconKind === "add" || iconKind === "+") {
                ctx.beginPath()
                ctx.moveTo(12, 5.5)
                ctx.lineTo(12, 18.5)
                ctx.moveTo(5.5, 12)
                ctx.lineTo(18.5, 12)
                ctx.stroke()
            } else if (iconKind === "copy") {
                roundedRect(7, 7, 10, 10, 1.5)
                ctx.stroke()
                roundedRect(4, 4, 10, 10, 1.5)
                ctx.stroke()
            } else {
                ctx.beginPath()
                ctx.arc(12, 12, 4, 0, Math.PI * 2)
                ctx.stroke()
            }
            ctx.restore()
        }
    }

    component PopupDivider: Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 1
        Layout.leftMargin: 0
        Layout.rightMargin: 0
        color: "#74706C"
        opacity: 0.78
    }

    component PopupAction: Rectangle {
        id: popupAction
        property string iconKind: ""
        property string text: ""
        property bool danger: false
        signal triggered()
        Layout.fillWidth: true
        Layout.preferredHeight: 48
        radius: 4
        color: popupActionMouse.pressed ? "#272322" : (popupActionMouse.containsMouse ? "#3A3432" : "transparent")

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 15
            anchors.rightMargin: 16
            spacing: 15

            PopupIcon {
                iconKind: popupAction.iconKind
                iconColor: popupAction.danger ? "#DFA0A4" : "#AAA6A2"
                Layout.preferredWidth: 34
                Layout.preferredHeight: 34
            }
            Text {
                text: popupAction.text
                color: popupAction.danger ? "#FFE0E0" : "#FFFFFF"
                font.pixelSize: 18
                Layout.fillWidth: true
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
            }
        }

        MouseArea {
            id: popupActionMouse
            anchors.fill: parent
            hoverEnabled: true
            preventStealing: true
            cursorShape: Qt.PointingHandCursor
            onClicked: popupAction.triggered()
        }
    }

    component PopupIcon: Item {
        id: popupIcon
        property string iconKind: ""
        property color iconColor: "#AAA6A2"
        readonly property string iconSource: "qrc:/qt/qml/SamhainSecurityNative/resources/action-" + iconKind + ".svg"
        implicitWidth: 34
        implicitHeight: 34

        Image {
            anchors.centerIn: parent
            width: 24
            height: 24
            source: popupIcon.iconSource
            sourceSize.width: 24
            sourceSize.height: 24
            fillMode: Image.PreserveAspectFit
            smooth: true
        }
    }

    component QuickActionButton: Rectangle {
        id: quickButton
        property string iconKind: ""
        property string label: ""
        signal clicked()
        Layout.fillWidth: true
        Layout.preferredHeight: 58
        radius: 8
        color: quickMouse.pressed ? "#2D2024" : (quickMouse.containsMouse ? "#211B1D" : "#171516")
        border.color: quickMouse.containsMouse ? "#514248" : "#2E272A"
        border.width: 1

        RowLayout {
            anchors.fill: parent
            spacing: 12
            Item { Layout.fillWidth: true }
            LineIcon {
                iconKind: quickButton.iconKind
                iconColor: root.accent
                Layout.preferredWidth: 28
                Layout.preferredHeight: 28
            }
            Text {
                text: quickButton.label
                color: root.text
                font.pixelSize: 18
                elide: Text.ElideRight
            }
            Item { Layout.fillWidth: true }
        }

        MouseArea {
            id: quickMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: quickButton.clicked()
        }
    }

    component PathChip: Rectangle {
        id: chip
        property string text: ""
        property bool active: false
        signal clicked()
        width: chipLabel.implicitWidth + 28
        height: 34
        radius: 6
        color: active ? "#251519" : "#151315"
        border.color: active
            ? (chipMouse.containsMouse ? "#B83A43" : "#9E3740")
            : (chipMouse.containsMouse ? "#68404A" : "#493038")
        border.width: 1
        Text {
            id: chipLabel
            anchors.centerIn: parent
            text: chip.text
            color: chip.active ? "#F1D1D5" : "#D7C8CC"
            font.pixelSize: 16
        }
        MouseArea {
            id: chipMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.clicked()
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

    component RouteStatePill: Rectangle {
        id: statePill
        property string text: ""
        property bool active: true
        implicitWidth: Math.min(statePillLabel.implicitWidth + 22, 142)
        implicitHeight: 28
        Layout.preferredWidth: implicitWidth
        Layout.preferredHeight: implicitHeight
        radius: 14
        color: active ? "#2E2225" : "#1B1819"
        border.color: active ? "#5C3A40" : "#363033"
        Text {
            id: statePillLabel
            anchors.fill: parent
            anchors.leftMargin: 11
            anchors.rightMargin: 11
            text: statePill.text
            color: active ? "#F0C4CA" : root.muted
            font.pixelSize: 12
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
    }

    component DialogActionButton: Rectangle {
        id: dialogActionButton
        property string text: ""
        property bool accentButton: false
        property bool danger: false
        signal clicked()
        implicitHeight: 46
        Layout.preferredHeight: 46
        radius: 8
        opacity: enabled ? 1 : 0.5
        color: !enabled
            ? "#1A1718"
            : (dialogActionMouse.pressed
                ? (danger ? "#341E22" : (accentButton ? "#8E3037" : "#211B1D"))
                : (dialogActionMouse.containsMouse
                    ? (danger ? "#2A1D20" : (accentButton ? "#A7353D" : "#241D20"))
                    : (accentButton ? root.accent : "#171516")))
        border.color: dialogActionMouse.containsMouse
            ? (danger ? "#6A353B" : (accentButton ? "#D05B64" : "#4A3A3F"))
            : (danger ? "#563038" : "#3A3034")
        Text {
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            text: dialogActionButton.text
            color: danger ? "#F08A91" : root.text
            font.pixelSize: 15
            font.bold: accentButton
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
        MouseArea {
            id: dialogActionMouse
            anchors.fill: parent
            enabled: dialogActionButton.enabled
            hoverEnabled: true
            cursorShape: dialogActionButton.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: dialogActionButton.clicked()
        }
    }

    component DialogIconButton: Rectangle {
        id: dialogIconButton
        property string symbol: ""
        property bool danger: false
        signal clicked()
        implicitWidth: 42
        implicitHeight: 42
        Layout.preferredWidth: implicitWidth
        Layout.preferredHeight: implicitHeight
        radius: 10
        color: dialogIconMouse.pressed
            ? (danger ? "#341E22" : "#211B1D")
            : (dialogIconMouse.containsMouse ? (danger ? "#2A1D20" : "#241D20") : "#171516")
        border.color: dialogIconMouse.containsMouse ? (danger ? "#6A353B" : "#4A3A3F") : "#3A3034"
        Text {
            anchors.centerIn: parent
            text: dialogIconButton.symbol
            color: danger ? "#F08A91" : root.muted
            font.pixelSize: 26
            font.bold: danger
        }
        MouseArea {
            id: dialogIconMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: dialogIconButton.clicked()
        }
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
                        text: "Стоп"
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
                        text: "Сброс"
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
                        text: "Сброс TUN"
                        Layout.preferredWidth: 132
                        danger: true
                        onClicked: appController.restoreTunPolicy()
                    }
                    Item { Layout.fillWidth: true }
                }

                AdvancedGroupTitle { text: "Маршрутизация и защита" }
                AdvancedStatusRow { title: "Привилегии"; value: appController.serviceReadinessStatus; detail: appController.serviceReadinessDetail }
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
