cmake_minimum_required(VERSION 3.20)
project(XeniaHostShaders LANGUAGES C CXX)
if(NOT XENIA_SOURCE_DIR)
  message(FATAL_ERROR "Set XENIA_SOURCE_DIR to the patched Edge source tree")
endif()
set(SPIRV-Headers_SOURCE_DIR "${XENIA_SOURCE_DIR}/third_party/SPIRV-Headers"
    CACHE INTERNAL "")
set(SPIRV_SKIP_TESTS ON CACHE INTERNAL "")
set(SPIRV_SKIP_EXECUTABLES ON CACHE INTERNAL "")
set(SKIP_SPIRV_TOOLS_INSTALL ON CACHE INTERNAL "")
set(SPIRV_WERROR OFF CACHE INTERNAL "")
set(SPIRV_BUILD_FUZZER OFF CACHE INTERNAL "")
add_subdirectory(${XENIA_SOURCE_DIR}/third_party/SPIRV-Tools spirv-tools EXCLUDE_FROM_ALL)

# SPIRV-Tools unconditionally forces /W2 /WX on MSVC via its own
# target_compile_options, which conflicts with the directory-level /W0 and
# produces D9025 "overriding /W0 with /W2" for every translation unit. Strip
# the /W* and /WX flags it added so only the directory-level /W0 survives.
if(MSVC)
  foreach(_spvt_target
      SPIRV-Tools-static SPIRV-Tools-shared SPIRV-Tools-opt
      SPIRV-Tools-link SPIRV-Tools-reduce SPIRV-Tools-diff)
    if(TARGET ${_spvt_target})
      get_target_property(_opts ${_spvt_target} COMPILE_OPTIONS)
      if(_opts)
        list(FILTER _opts EXCLUDE REGEX "^/[Ww]([0-9]|all|X)$")
        set_target_properties(${_spvt_target} PROPERTIES COMPILE_OPTIONS "${_opts}")
      endif()
    endif()
  endforeach()
endif()

# ==============================================================================
# glslang (host: full frontend + SPIR-V emission for the xenia-shader-cc
# build-time tool; all platforms, including macOS)
# ==============================================================================
# Read glslang's own version file to generate build_info.h in sync with the
# pinned submodule, matching what glslang's own CMakeLists does.
include(${XENIA_SOURCE_DIR}/third_party/glslang/parse_version.cmake)
parse_version(${XENIA_SOURCE_DIR}/third_party/glslang/CHANGES.md GLSLANG)
set(major ${GLSLANG_VERSION_MAJOR})
set(minor ${GLSLANG_VERSION_MINOR})
set(patch ${GLSLANG_VERSION_PATCH})
set(flavor ${GLSLANG_VERSION_FLAVOR})
configure_file(
  ${XENIA_SOURCE_DIR}/third_party/glslang/build_info.h.tmpl
  ${CMAKE_CURRENT_BINARY_DIR}/glslang-build-info/glslang/build_info.h
  @ONLY)

file(GLOB _glslang_mi
  "${XENIA_SOURCE_DIR}/third_party/glslang/glslang/MachineIndependent/*.cpp"
  "${XENIA_SOURCE_DIR}/third_party/glslang/glslang/MachineIndependent/preprocessor/*.cpp"
  "${XENIA_SOURCE_DIR}/third_party/glslang/glslang/GenericCodeGen/*.cpp")
file(GLOB _glslang_spirv_all "${XENIA_SOURCE_DIR}/third_party/glslang/SPIRV/*.cpp")
add_library(glslang STATIC
  ${_glslang_mi}
  ${_glslang_spirv_all}
  ${XENIA_SOURCE_DIR}/third_party/glslang/glslang/ResourceLimits/ResourceLimits.cpp
)
if(WIN32)
  target_sources(glslang PRIVATE ${XENIA_SOURCE_DIR}/third_party/glslang/glslang/OSDependent/Windows/ossource.cpp)
else()
  target_sources(glslang PRIVATE ${XENIA_SOURCE_DIR}/third_party/glslang/glslang/OSDependent/Unix/ossource.cpp)
endif()
target_include_directories(glslang PUBLIC
  ${XENIA_SOURCE_DIR}/third_party/glslang
  ${CMAKE_CURRENT_BINARY_DIR}/glslang-build-info)
target_compile_features(glslang PUBLIC cxx_std_17)
# Enable glslang's SpvTools.cpp optimizer/disassembler bridge to SPIRV-Tools.
target_compile_definitions(glslang PRIVATE ENABLE_OPT=1)
target_link_libraries(glslang PUBLIC SPIRV-Tools-opt SPIRV-Tools-static)
# glslang relies on exceptions internally.
if(MSVC)
  target_compile_options(glslang PRIVATE /EHsc)
endif()
if(NOT WIN32)
  find_package(Threads)
  if(Threads_FOUND)
    target_link_libraries(glslang PUBLIC Threads::Threads)
  endif()
endif()



add_executable(xenia-shader-cc ${XENIA_SOURCE_DIR}/tools/build/shader_cc.cc)
target_compile_features(xenia-shader-cc PRIVATE cxx_std_17)
target_include_directories(xenia-shader-cc PRIVATE ${XENIA_SOURCE_DIR}/third_party/glslang/StandAlone)
target_link_libraries(xenia-shader-cc PRIVATE glslang SPIRV-Tools-static)
