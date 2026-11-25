# Krypton Wrapper (NG-GL4ES) as libng_gl4es.dylib for iOS.
#
# Not add_subdirectory() of Natives/external/NG-GL4ES itself: that file calls
# project(ng_gl4es), links ${CMAKE_PROJECT_NAME} (which resolves to "Witch" when
# nested) and passes the GNU-only -Wl,--strip-all. The source list and the
# glslang / SPIRV-Cross options below are taken from it; the rest is replaced.
#
# Included before Natives/CMakeLists.txt's global include_directories(), so
# Witch's include paths (external/mesa, external/lzma, ...) stay out of here.

cmake_minimum_required(VERSION 3.22.1)

set(NG_DIR "${CMAKE_CURRENT_LIST_DIR}/../../external/NG-GL4ES")

# glslang / SPIRV-Cross options, as in NG-GL4ES/CMakeLists.txt.
set(ENABLE_RTTI                ON  CACHE BOOL "Enables RTTI (will be took by glslang)" FORCE)
set(ENABLE_HLSL                OFF CACHE BOOL "Disable HLSL input for glslang" FORCE)
set(BUILD_EXTERNAL             OFF CACHE BOOL "Don't build external deps in External/" FORCE)
set(ENABLE_GLSLANG_BINARIES    OFF CACHE BOOL "Disable glslangValidator/spirv-remap" FORCE)
set(ENABLE_OPT                 OFF CACHE BOOL "Disable SPIRV-Tools opt usage in glslang" FORCE)
set(GLSLANG_TESTS              OFF CACHE BOOL "No glslang tests in the iOS build" FORCE)

set(SPIRV_CROSS_ENABLE_C_API   ON  CACHE BOOL "Enable C API" FORCE)
set(SPIRV_CROSS_ENABLE_GLSL    ON  CACHE BOOL "Enable GLSL backend" FORCE)
set(SPIRV_CROSS_ENABLE_REFLECT OFF CACHE BOOL "Disable reflect" FORCE)
set(SPIRV_CROSS_ENABLE_HLSL    OFF CACHE BOOL "Disable HLSL backend" FORCE)
set(SPIRV_CROSS_ENABLE_MSL     OFF CACHE BOOL "Disable MSL backend" FORCE)
set(SPIRV_CROSS_ENABLE_CPP     OFF CACHE BOOL "Disable C++ API target" FORCE)
set(SPIRV_CROSS_CLI            OFF CACHE BOOL "Disable CLI binary" FORCE)
set(SPIRV_CROSS_STATIC         ON  CACHE BOOL "Prefer static libs" FORCE)
set(SPIRV_CROSS_ENABLE_UTIL    OFF CACHE BOOL "Disable util" FORCE)
set(SPIRV_CROSS_ENABLE_TESTS   OFF CACHE BOOL "No SPIRV-Cross tests in the iOS build" FORCE)

# Hide every glslang / SPIRV-Cross symbol from libng_gl4es. Both are linked
# statically, and their GLSLANG_EXPORT / SPVC_PUBLIC_API macros expand to
# nothing in static builds, so the hidden visibility preset is what keeps them
# out of the dylib. libmobileglues and libspirv-cross-c-shared export the same
# names, and flat-namespace lookups would bind to whichever image loaded first.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

# Natives/CMakeLists.txt gives C targets the iOS triple and the 14.0 floor.
# C++ targets need the same, or glslang / SPIRV-Cross would be built against
# the SDK's default deployment target.
if(CMAKE_OSX_SYSROOT)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -target arm64-apple-ios -mcpu=apple-a9 -mios-version-min=14.0")
endif()

add_subdirectory(${NG_DIR}/3rdparty/glslang ${CMAKE_CURRENT_BINARY_DIR}/glslang)
add_subdirectory(${NG_DIR}/3rdparty/SPIRV-Cross ${CMAKE_CURRENT_BINARY_DIR}/SPIRV-Cross)

set(NG_C_SRC
    src/gl/string_utils.c
    src/gl/cJSON.c
    src/gl/config.c
    src/gl/arbconverter.c
    src/gl/arbgenerator.c
    src/gl/arbhelper.c
    src/gl/arbparser.c
    src/gl/array.c
    src/gl/blend.c
    src/gl/blit.c
    src/gl/buffers.c
    src/gl/build_info.c
    src/gl/debug.c
    src/gl/decompress.c
    src/gl/depth.c
    src/gl/directstate.c
    src/gl/drawing.c
    src/gl/enable.c
    src/gl/envvars.c
    src/gl/eval.c
    src/gl/face.c
    src/gl/fog.c
    src/gl/fpe.c
    src/gl/fpe_cache.c
    src/gl/fpe_shader.c
    src/gl/framebuffers.c
    src/gl/gl_lookup.c
    src/gl/gl4es.c
    src/gl/glstate.c
    src/gl/hint.c
    src/gl/init.c
    src/gl/light.c
    src/gl/line.c
    src/gl/list.c
    src/gl/listdraw.c
    src/gl/listrl.c
    src/gl/loader.c
    src/gl/logs.c
    src/gl/matrix.c
    src/gl/matvec.c
    src/gl/oldprogram.c
    src/gl/pixel.c
    src/gl/planes.c
    src/gl/pointsprite.c
    src/gl/preproc.c
    src/gl/program.c
    src/gl/queries.c
    src/gl/raster.c
    src/gl/render.c
    src/gl/shader.c
    src/gl/shaderconv.c
    src/gl/shader_hacks.c
    src/gl/stack.c
    src/gl/stencil.c
    src/gl/stubs.c
    src/gl/texenv.c
    src/gl/texgen.c
    src/gl/texture.c
    src/gl/texture_compressed.c
    src/gl/texture_params.c
    src/gl/texture_read.c
    src/gl/texture_3d.c
    src/gl/uniform.c
    src/gl/vertexattrib.c
    src/gl/wrap/gl4eswraps.c
    src/gl/wrap/gles.c
    src/gl/wrap/glstub.c
    src/gl/math/matheval.c
    src/glx/hardext.c
    src/glx/lookup.c
    src/glx/gbm.c
    src/glx/streaming.c
    src/gl/vgpu/shaderconv.c
    src/gl/samplers.c
)

# src/glx/glx.c is left out, as in NG-GL4ES's own Android build (NOX11).
set(NG_CPP_SRC
    src/gl/wrap/glesnative.cpp
    src/gl/glsl/glsl_for_es.cpp
    src/gl/getter.cpp
)

list(TRANSFORM NG_C_SRC PREPEND "${NG_DIR}/")
list(TRANSFORM NG_CPP_SRC PREPEND "${NG_DIR}/")

add_library(ng_gl4es SHARED ${NG_C_SRC} ${NG_CPP_SRC})

set_target_properties(ng_gl4es PROPERTIES
    C_STANDARD 11
    C_STANDARD_REQUIRED ON
    CXX_STANDARD 23
    CXX_STANDARD_REQUIRED ON
    # The Makefile packages every *.dylib in the build root into Frameworks/.
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
)

target_include_directories(ng_gl4es PRIVATE "${NG_DIR}/include")

target_compile_definitions(ng_gl4es PRIVATE
    NO_GBM                 # no DRM/GBM on iOS
    NOX11                  # no glx.c, as in the Android build
    DEFAULT_ES=3
    NO_INIT_CONSTRUCTOR    # the host calls initialize_gl4es() once a context is current
)

target_link_libraries(ng_gl4es PRIVATE glslang::glslang spirv-cross-c)

if(APPLE)
    # Export only the GL entry points and the three host hooks; the export
    # list is the second wall behind the hidden visibility above.
    target_link_options(ng_gl4es PRIVATE
        "-Wl,-exported_symbols_list,${CMAKE_CURRENT_LIST_DIR}/ng_gl4es.exports"
        "-Wl,-undefined,dynamic_lookup")
endif()
