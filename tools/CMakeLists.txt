# =============================================================================
# CMakeLists.txt — build script for the Vivado-output extractor
# =============================================================================
#
# BUILD
#   From the project root:
#       cd tools
#       cmake -S . -B build
#       cmake --build build -j
#
#   The executable lands at tools/build/extract_results
#   (or tools/build/Release/extract_results.exe on a multi-config Windows
#   generator like Visual Studio).
#
# RUN
#       # from the project root, after building:
#       ./tools/build/extract_results              # defaults to ./build
#       ./tools/build/extract_results build acc_   # only acc_* runs
#
# CLEAN
#       cmake --build build --target clean
#       # or just remove the directory:
#       rm -rf tools/build
# =============================================================================

cmake_minimum_required(VERSION 3.16)

project(systolic_tools
        LANGUAGES CXX
        DESCRIPTION "Vivado synthesis-output extractor for the systolic accelerator")

# -----------------------------------------------------------------------------
# Compiler settings
# -----------------------------------------------------------------------------
set(CMAKE_CXX_STANDARD          17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS        OFF)

# Default to Release if no build type was specified (only meaningful for
# single-config generators like Unix Makefiles or Ninja).
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# -----------------------------------------------------------------------------
# Warnings
# -----------------------------------------------------------------------------
if(MSVC)
    add_compile_options(/W4 /permissive-)
    # Silence MSVC's complaints about portable C functions (getenv, fopen, etc.).
    # We're using the standard, cross-platform versions on purpose.
    add_compile_definitions(_CRT_SECURE_NO_WARNINGS)
else()
    add_compile_options(-Wall -Wextra -Wpedantic)
endif()

# -----------------------------------------------------------------------------
# Target
# -----------------------------------------------------------------------------
add_executable(extract_results extract_results.cpp)

# Older toolchains keep std::filesystem in a separate library.
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU"
   AND CMAKE_CXX_COMPILER_VERSION VERSION_LESS 9)
    target_link_libraries(extract_results PRIVATE stdc++fs)
endif()
if(CMAKE_CXX_COMPILER_ID STREQUAL "Clang"
   AND CMAKE_CXX_COMPILER_VERSION VERSION_LESS 9)
    target_link_libraries(extract_results PRIVATE c++fs)
endif()

# -----------------------------------------------------------------------------
# Reporting
# -----------------------------------------------------------------------------
message(STATUS "Compiler  : ${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION}")
message(STATUS "Build type: ${CMAKE_BUILD_TYPE}")
message(STATUS "Output    : ${CMAKE_BINARY_DIR}/extract_results")
