cmake_minimum_required(VERSION 3.10)

project(real-esrgan-ncnn-webassembly)

option(LOCAL_DEBUG "debug" OFF)

set(CMAKE_BUILD_TYPE release)

if(NOT WASM_FEATURE)
    message(FATAL_ERROR "You must pass cmake option -DWASM_FEATURE and possible values are basic, simd, threads and simd-threads")
endif()

# Route A: CPU only. Vulkan/WebGPU via ncnn is not used in this build.
set(NCNN_VULKAN OFF CACHE BOOL "" FORCE)
set(NCNN_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(NCNN_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(NCNN_BUILD_BENCHMARK OFF CACHE BOOL "" FORCE)
set(NCNN_BUILD_TESTS OFF CACHE BOOL "" FORCE)

add_subdirectory(ncnn)

if (NOT LOCAL_DEBUG)
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -s FORCE_FILESYSTEM=1 -s ALLOW_MEMORY_GROWTH=1 -s EXIT_RUNTIME=1 -s INITIAL_MEMORY=536870912")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -s FORCE_FILESYSTEM=1 -s ALLOW_MEMORY_GROWTH=1 -s EXIT_RUNTIME=1 -s INITIAL_MEMORY=536870912")
    set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -s FORCE_FILESYSTEM=1 -s ALLOW_MEMORY_GROWTH=1 -s EXIT_RUNTIME=1 -s INITIAL_MEMORY=536870912")

    # CPU models are downloaded on demand and written into the Emscripten MEMFS by
    # the page, so the build must export the FS runtime API and must NOT preload a
    # combined .data package (that would make every visitor fetch all four models).
    set(EXPORT_FLAGS "-s EXPORTED_FUNCTIONS=['_process_image','_list_models','_get_model_count','_get_model_name','_get_model_scale','_get_model_input_blob','_get_model_output_blob','_malloc','_free'] -s EXPORTED_RUNTIME_METHODS=['ccall','cwrap','HEAPU8','UTF8ToString','FS']")
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} ${EXPORT_FLAGS}")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${EXPORT_FLAGS}")
    set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} ${EXPORT_FLAGS}")

    set(CMAKE_CXX_FLAGS_RELEASE "-O3")
endif()

if(${WASM_FEATURE} MATCHES "threads")
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fopenmp -pthread -s USE_PTHREADS=1 -s PTHREAD_POOL_SIZE=navigator.hardwareConcurrency")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fopenmp -pthread -s USE_PTHREADS=1 -s PTHREAD_POOL_SIZE=navigator.hardwareConcurrency")
    set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -fopenmp -pthread -s USE_PTHREADS=1 -s PTHREAD_POOL_SIZE=navigator.hardwareConcurrency")
endif()

add_executable(real-esrgan-ncnn-webassembly-${WASM_FEATURE} main.cpp realesrgan.cpp shape_layer.cpp)
set_property(TARGET real-esrgan-ncnn-webassembly-${WASM_FEATURE} PROPERTY CXX_STANDARD 11)
target_link_libraries(real-esrgan-ncnn-webassembly-${WASM_FEATURE} ncnn)
