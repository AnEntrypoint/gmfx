cmake_minimum_required(VERSION 3.20)
project(fx_txiki LANGUAGES C CXX)

find_package(Threads REQUIRED)

set(FX_TXIKI_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/txiki)
set(FX_QUICKJS_DIR ${FX_TXIKI_ROOT}/quickjs)
set(FX_TXIKI_DIR ${FX_TXIKI_ROOT}/txiki)
set(FX_GLUE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/glue)

add_library(fx_quickjs_ng STATIC
    ${FX_QUICKJS_DIR}/dtoa.c
    ${FX_QUICKJS_DIR}/libregexp.c
    ${FX_QUICKJS_DIR}/libunicode.c
    ${FX_QUICKJS_DIR}/quickjs.c
)
set_target_properties(fx_quickjs_ng PROPERTIES C_STANDARD 11 C_EXTENSIONS ON C_VISIBILITY_PRESET hidden)
target_include_directories(fx_quickjs_ng SYSTEM PUBLIC ${FX_QUICKJS_DIR})
target_compile_definitions(fx_quickjs_ng PRIVATE QUICKJS_NG_BUILD _GNU_SOURCE)
target_compile_options(fx_quickjs_ng PRIVATE -funsigned-char -w)
target_link_libraries(fx_quickjs_ng PUBLIC m ${CMAKE_DL_LIBS} Threads::Threads)

set(LIBUV_BUILD_SHARED OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
add_subdirectory(${FX_TXIKI_ROOT}/libuv ${CMAKE_CURRENT_BINARY_DIR}/libuv EXCLUDE_FROM_ALL)
target_compile_options(uv_a PRIVATE -w)

set(FX_TXIKI_SOURCES
    builtins.c error.c eval.c mem.c mod_channel.c mod_dns.c mod_engine.c mod_fs.c mod_fswatch.c mod_os.c
    mod_process.c mod_streams.c mod_sys.c mod_udp.c modules.c signals.c tbuf.c text-coding.c timers.c url.c
    utils.c version.c vm.c worker.c
    bundles/c/core/core.c bundles/c/core/polyfills.c bundles/c/core/run-main.c bundles/c/core/worker-bootstrap.c
    mod_posix-socket.c
)
list(TRANSFORM FX_TXIKI_SOURCES PREPEND ${FX_TXIKI_DIR}/src/)

add_library(fx_txiki STATIC
    ${FX_TXIKI_SOURCES}
    ${FX_TXIKI_DIR}/deps/ada/ada.cpp
    ${FX_GLUE_DIR}/txiki_stubs.c
    ${FX_GLUE_DIR}/txiki_shim.c
    ${FX_GLUE_DIR}/runcode_shim.c
)
set_target_properties(fx_txiki PROPERTIES C_STANDARD 11 C_EXTENSIONS ON C_VISIBILITY_PRESET hidden CXX_STANDARD 20)
string(TOLOWER ${CMAKE_SYSTEM_NAME} FX_TXIKI_PLATFORM)
target_compile_definitions(fx_txiki PRIVATE _GNU_SOURCE TJS__PLATFORM="${FX_TXIKI_PLATFORM}")
target_include_directories(fx_txiki SYSTEM PRIVATE ${FX_GLUE_DIR}/overlay ${FX_TXIKI_DIR}/src ${FX_TXIKI_DIR}/deps/ada)
target_include_directories(fx_txiki PUBLIC ${FX_GLUE_DIR})
target_compile_options(fx_txiki PRIVATE -w)
target_link_libraries(fx_txiki PUBLIC fx_quickjs_ng uv_a)
