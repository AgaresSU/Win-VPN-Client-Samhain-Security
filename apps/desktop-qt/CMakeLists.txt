cmake_minimum_required(VERSION 3.24)

project(SamhainSecurityNativeDesktop VERSION 1.4.2 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Network Quick QuickControls2 Svg Widgets)

qt_standard_project_setup(REQUIRES 6.10)

qt_add_executable(SamhainSecurityNative
    WIN32
    src/main.cpp
    src/AppController.cpp
    src/AppController.h
)

qt_add_qml_module(SamhainSecurityNative
    URI SamhainSecurityNative
    VERSION 1.0
    QML_FILES
        qml/Main.qml
    RESOURCES
        resources/app-icon.png
        resources/tray-icon.png
        resources/action-copy.svg
        resources/action-delete.svg
        resources/action-edit.svg
        resources/action-latency.svg
        resources/action-pin.svg
        resources/action-refresh.svg
)

target_link_libraries(SamhainSecurityNative
    PRIVATE
        Qt6::Quick
        Qt6::QuickControls2
        Qt6::Network
        Qt6::Svg
        Qt6::Widgets
)

if(WIN32)
    target_link_libraries(SamhainSecurityNative PRIVATE dwmapi)
endif()

set_target_properties(SamhainSecurityNative PROPERTIES
    OUTPUT_NAME "SamhainSecurityNative"
)
