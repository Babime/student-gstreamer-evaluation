cmake_minimum_required(VERSION 3.16)
project(monitor_sender C)

set(CMAKE_C_STANDARD 11)

find_package(PkgConfig REQUIRED)
pkg_check_modules(GST REQUIRED IMPORTED_TARGET gstreamer-1.0)

add_executable(monitor_sender src/monitor_sender.c)
target_link_libraries(monitor_sender PRIVATE PkgConfig::GST)
target_compile_options(monitor_sender PRIVATE -Wall -Wextra)
