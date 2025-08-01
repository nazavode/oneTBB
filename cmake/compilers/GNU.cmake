# Copyright (c) 2020-2025 Intel Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

if (MINGW)
    set(TBB_LINK_DEF_FILE_FLAG "")
    set(TBB_DEF_FILE_PREFIX "")
elseif (APPLE)
    set(TBB_LINK_DEF_FILE_FLAG -Wl,-exported_symbols_list,)
    set(TBB_DEF_FILE_PREFIX mac${TBB_ARCH})

    # For correct ucontext.h structures layout
    set(TBB_COMMON_COMPILE_FLAGS ${TBB_COMMON_COMPILE_FLAGS} -D_XOPEN_SOURCE)
else()
    set(TBB_LINK_DEF_FILE_FLAG -Wl,--version-script=)
    set(TBB_DEF_FILE_PREFIX lin${TBB_ARCH})
endif()

set(TBB_WARNING_LEVEL -Wall -Wextra $<$<BOOL:${TBB_STRICT}>:-Werror> -Wfatal-errors)
set(TBB_TEST_WARNING_FLAGS -Wshadow -Wcast-qual -Woverloaded-virtual -Wnon-virtual-dtor)

# Depfile options (e.g. -MD) are inserted automatically in some cases.
# Don't add -MMD to avoid conflicts in such cases.
if (NOT CMAKE_GENERATOR MATCHES "Ninja" AND NOT CMAKE_CXX_DEPENDS_USE_COMPILER)
    set(TBB_MMD_FLAG -MMD)
endif()


# Binutils < 2.31.1 do not support the tpause instruction. When compiling with
# a modern version of GCC (supporting it) but relying on an outdated assembler,
# will result in an error reporting "no such instruction: tpause".
# The following code invokes the GNU assembler to extract the version number
# and convert it to an integer that can be used in the C++ code to compare
# against, and conditionally disable the __TBB_WAITPKG_INTRINSICS_PRESENT
# macro if the version is incompatible. Binutils only report the version in the
# MAJOR.MINOR format, therefore the version checked is >=2.32 (instead of
# >=2.31.1). Capturing the output in CMake can be done like below. The version
# information is written to either stdout or stderr. To not make any
# assumptions, both are captured.
execute_process(
    COMMAND ${CMAKE_COMMAND} -E env "LC_ALL=C" "LANG=C" ${CMAKE_CXX_COMPILER} -xc -c /dev/null -Wa,-v -o/dev/null
    OUTPUT_VARIABLE ASSEMBLER_VERSION_LINE_OUT
    ERROR_VARIABLE ASSEMBLER_VERSION_LINE_ERR
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_STRIP_TRAILING_WHITESPACE
)
set(ASSEMBLER_VERSION_LINE ${ASSEMBLER_VERSION_LINE_OUT}${ASSEMBLER_VERSION_LINE_ERR})
if ("${ASSEMBLER_VERSION_LINE}" MATCHES "GNU assembler version")
    string(REGEX REPLACE ".*GNU assembler version ([0-9]+)\\.([0-9]+).*" "\\1" _tbb_gnu_asm_major_version "${ASSEMBLER_VERSION_LINE}")
    string(REGEX REPLACE ".*GNU assembler version ([0-9]+)\\.([0-9]+).*" "\\2" _tbb_gnu_asm_minor_version "${ASSEMBLER_VERSION_LINE}")
    unset(ASSEMBLER_VERSION_LINE_OUT)
    unset(ASSEMBLER_VERSION_LINE_ERR)
    unset(ASSEMBLER_VERSION_LINE)
    message(TRACE "Extracted GNU assembler version: major=${_tbb_gnu_asm_major_version} minor=${_tbb_gnu_asm_minor_version}")

    math(EXPR _tbb_gnu_asm_version_number  "${_tbb_gnu_asm_major_version} * 1000 + ${_tbb_gnu_asm_minor_version}")
    set(TBB_COMMON_COMPILE_FLAGS ${TBB_COMMON_COMPILE_FLAGS} "-D__TBB_GNU_ASM_VERSION=${_tbb_gnu_asm_version_number}")
    message(STATUS "GNU Assembler version: ${_tbb_gnu_asm_major_version}.${_tbb_gnu_asm_minor_version}  (${_tbb_gnu_asm_version_number})")
endif()

# Enable Intel(R) Transactional Synchronization Extensions (-mrtm) and WAITPKG instructions support (-mwaitpkg) on relevant processors
if (CMAKE_SYSTEM_PROCESSOR MATCHES "(AMD64|amd64|i.86|x86)" AND NOT EMSCRIPTEN)
    set(TBB_COMMON_COMPILE_FLAGS ${TBB_COMMON_COMPILE_FLAGS} -mrtm $<$<AND:$<NOT:$<CXX_COMPILER_ID:Intel>>,$<NOT:$<VERSION_LESS:${CMAKE_CXX_COMPILER_VERSION},11.0>>>:-mwaitpkg>)
endif()

set(TBB_COMMON_LINK_LIBS ${CMAKE_DL_LIBS})

# Ignore -Werror set through add_compile_options() or added to CMAKE_CXX_FLAGS if TBB_STRICT is disabled.
if (NOT TBB_STRICT AND COMMAND tbb_remove_compile_flag)
    tbb_remove_compile_flag(-Werror)
endif()

if (NOT ${CMAKE_CXX_COMPILER_ID} STREQUAL Intel)
    # gcc 6.0 and later have -flifetime-dse option that controls elimination of stores done outside the object lifetime
    set(TBB_DSE_FLAG $<$<NOT:$<VERSION_LESS:${CMAKE_CXX_COMPILER_VERSION},6.0>>:-flifetime-dse=1>)
    set(TBB_COMMON_COMPILE_FLAGS ${TBB_COMMON_COMPILE_FLAGS} $<$<NOT:$<VERSION_LESS:${CMAKE_CXX_COMPILER_VERSION},8.0>>:-fstack-clash-protection>)

    # Suppress GCC 12.x-14.x warning here that to_wait_node(n)->my_is_in_list might have size 0
    set(TBB_COMMON_LINK_FLAGS ${TBB_COMMON_LINK_FLAGS} $<$<AND:$<NOT:$<VERSION_LESS:${CMAKE_CXX_COMPILER_VERSION},12.0>>,$<VERSION_LESS:${CMAKE_CXX_COMPILER_VERSION},15.0>>:-Wno-stringop-overflow>)
endif()

# Workaround for heavy tests and too many symbols in debug (rellocation truncated to fit: R_MIPS_CALL16)
if ("${CMAKE_SYSTEM_PROCESSOR}" MATCHES "mips")
    set(TBB_TEST_COMPILE_FLAGS ${TBB_TEST_COMPILE_FLAGS} -DTBB_TEST_LOW_WORKLOAD $<$<CONFIG:DEBUG>:-fPIE -mxgot>)
    set(TBB_TEST_LINK_FLAGS ${TBB_TEST_LINK_FLAGS} $<$<CONFIG:DEBUG>:-pie>)
endif()

set(TBB_IPO_COMPILE_FLAGS $<$<NOT:$<CONFIG:Debug>>:-flto>)
set(TBB_IPO_LINK_FLAGS $<$<NOT:$<CONFIG:Debug>>:-flto>)


if (MINGW AND CMAKE_SYSTEM_PROCESSOR MATCHES "i.86")
    list (APPEND TBB_COMMON_COMPILE_FLAGS -msse2)
endif ()

# Gnu flags to prevent compiler from optimizing out security checks
set(TBB_COMMON_COMPILE_FLAGS ${TBB_COMMON_COMPILE_FLAGS} -fno-strict-overflow -fno-delete-null-pointer-checks -fwrapv)
set(TBB_COMMON_COMPILE_FLAGS ${TBB_COMMON_COMPILE_FLAGS} -Wformat -Wformat-security -Werror=format-security
    -fstack-protector-strong )
if (CMAKE_SYSTEM_PROCESSOR MATCHES "(AMD64|amd64|i.86|x86)" AND NOT EMSCRIPTEN)
    set(TBB_LIB_COMPILE_FLAGS ${TBB_LIB_COMPILE_FLAGS} $<$<NOT:$<VERSION_LESS:${CMAKE_CXX_COMPILER_VERSION},8.0>>:-fcf-protection=full>)
endif ()
set(TBB_LIB_COMPILE_FLAGS ${TBB_LIB_COMPILE_FLAGS} $<$<NOT:$<VERSION_LESS:${CMAKE_CXX_COMPILER_VERSION},8.0>>:-fstack-clash-protection>)

# -z switch is not supported on MacOS and MinGW
if (NOT APPLE AND NOT MINGW)
    set(TBB_LIB_LINK_FLAGS ${TBB_LIB_LINK_FLAGS} -Wl,-z,relro,-z,now,-z,noexecstack)
endif()
if (NOT CMAKE_CXX_FLAGS MATCHES "_FORTIFY_SOURCE")
  set(TBB_COMMON_COMPILE_FLAGS ${TBB_COMMON_COMPILE_FLAGS} $<$<NOT:$<CONFIG:Debug>>:-D_FORTIFY_SOURCE=2> )
endif ()

if (TBB_FILE_TRIM AND CMAKE_CXX_COMPILER_VERSION VERSION_GREATER_EQUAL 8 AND NOT CMAKE_CXX_COMPILER_ID MATCHES "Intel")
    set(TBB_COMMON_COMPILE_FLAGS ${TBB_COMMON_COMPILE_FLAGS} -ffile-prefix-map=${NATIVE_TBB_PROJECT_ROOT_DIR}/= -ffile-prefix-map=${NATIVE_TBB_RELATIVE_BIN_PATH}/=)
endif ()

# TBB malloc settings
set(TBBMALLOC_LIB_COMPILE_FLAGS -fno-rtti -fno-exceptions)
set(TBB_OPENMP_FLAG -fopenmp)
