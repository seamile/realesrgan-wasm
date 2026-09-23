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

    set(MODEL_FILES "${CMAKE_CURRENT_SOURCE_DIR}/models/realesr-general-x4v3.param@realesr-general-x4v3.param;${CMAKE_CURRENT_SOURCE_DIR}/models/realesr-general-x4v3.bin@realesr-general-x4v3.bin;${CMAKE_CURRENT_SOURCE_DIR}/models/realesr-animevideov3-x4.param@realesr-animevideov3-x4.param;${CMAKE_CURRENT_SOURCE_DIR}/models/realesr-animevideov3-x4.bin@realesr-animevideov3-x4.bin;${CMAKE_CURRENT_SOURCE_DIR}/models/realesrgan-x4plus.param@realesrgan-x4plus.param;${CMAKE_CURRENT_SOURCE_DIR}/models/realesrgan-x4plus.bin@realesrgan-x4plus.bin;${CMAKE_CURRENT_SOURCE_DIR}/models/realesrgan-x4plus-anime.param@realesrgan-x4plus-anime.param;${CMAKE_CURRENT_SOURCE_DIR}/models/realesrgan-x4plus-anime.bin@realesrgan-x4plus-anime.bin")
    set(MODEL_FLAGS "")
    foreach(MODEL_FILE ${MODEL_FILES})
        set(MODEL_FLAGS "${MODEL_FLAGS} --preload-file ${MODEL_FILE}")
    endforeach()
    set(EXPORT_FLAGS "-s EXPORTED_FUNCTIONS=['_process_image','_list_models','_get_model_count','_get_model_name','_get_model_scale','_get_model_input_blob','_get_model_output_blob','_malloc','_free'] -s EXPORTED_RUNTIME_METHODS=['ccall','cwrap','HEAPU8','UTF8ToString'] ${MODEL_FLAGS} --use-preload-cache")
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
