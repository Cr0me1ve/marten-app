cmake_minimum_required(VERSION 3.22.1)
project(marten_art_profiler LANGUAGES CXX)
add_library(marten_art_profiler SHARED marten_art_profiler.cpp)
target_compile_features(marten_art_profiler PRIVATE cxx_std_17)
# JVMTI's ABI is part of the JDK; JNI itself comes from the Android NDK.
configure_file("${MARTEN_JVM_INCLUDE}/jvmti.h" "${CMAKE_CURRENT_BINARY_DIR}/include/jvmti.h" COPYONLY)
target_include_directories(marten_art_profiler PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/include")
target_compile_options(marten_art_profiler PRIVATE -Wall -Wextra -Werror -fvisibility=hidden)
target_link_options(marten_art_profiler PRIVATE -Wl,-z,max-page-size=16384)
