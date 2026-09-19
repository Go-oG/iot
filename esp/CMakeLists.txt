cmake_minimum_required(VERSION 3.22)

set(IDF_TARGET "esp32c5" CACHE STRING "ESP-IDF target")
set(COMPONENTS main)
set(PROJECT_VER "0.7.0")
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(esp32c5_ble_gateway)
