# Out-of-tree reference harness. Builds the pinned libjxl checkout as a
# subproject with its binary dir outside that tree, so pin-check's clean-tree
# check stays green, and links its internal static libraries. No libjxl source
# is patched.
cmake_minimum_required(VERSION 3.16)
project(jxl_reference_harness CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT LIBJXL_DIR)
  message(FATAL_ERROR "LIBJXL_DIR must point at the pinned libjxl checkout")
endif()

# The reference SIMD target is the arm64 NEON baseline: without this, dynamic
# dispatch picks NEON_BF16 on CPUs that have it, and the reference would
# depend on the machine that generated it.
set(JPEGXL_ENABLE_HWY_NEON_BF16 OFF CACHE BOOL "" FORCE)

add_subdirectory("${LIBJXL_DIR}" libjxl EXCLUDE_FROM_ALL)

# Each subcommand and each dump category is its own file that registers itself,
# so lanes adding categories never edit a shared source.
file(GLOB HARNESS_SOURCES CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/src/*.cc")

add_executable(jxl-harness ${HARNESS_SOURCES})
target_include_directories(jxl-harness PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/src"
  "${LIBJXL_DIR}")
target_link_libraries(jxl-harness PRIVATE jxl-internal jxl_cms jxl_threads hwy)

target_compile_definitions(jxl-harness PRIVATE LIBJXL_COMMIT="${LIBJXL_COMMIT}")
