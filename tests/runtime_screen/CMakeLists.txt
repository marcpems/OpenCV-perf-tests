cmake_minimum_required(VERSION 3.20)
project(opencv_runtime_screen LANGUAGES CXX)

if(NOT WIN32 OR NOT MSVC)
  message(FATAL_ERROR "This screening harness requires native Windows MSVC.")
endif()
foreach(required OPENCV_SOURCE OPENCV_CONFIG OPENCV_IMPORT_LIBRARY)
  if(NOT DEFINED ${required})
    message(FATAL_ERROR "Missing ${required}")
  endif()
endforeach()

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_MSVC_RUNTIME_LIBRARY MultiThreadedDLL)
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/opencv_tests_config.hpp" "")
file(GLOB ts_sources "${OPENCV_SOURCE}/modules/ts/src/*.cpp")
add_library(runtime_ts STATIC ${ts_sources})
target_compile_definitions(runtime_ts PUBLIC __OPENCV_BUILD=1 __OPENCV_TESTS=1)
target_compile_options(runtime_ts PUBLIC /O2 /bigobj)
target_include_directories(runtime_ts PUBLIC
  "${OPENCV_CONFIG}"
  "${CMAKE_CURRENT_BINARY_DIR}"
  "${OPENCV_SOURCE}/include"
  "${OPENCV_SOURCE}/modules/ts/include")
foreach(module core imgproc imgcodecs videoio highgui features2d calib3d dnn flann)
  target_include_directories(runtime_ts PUBLIC "${OPENCV_SOURCE}/modules/${module}/include")
endforeach()
target_link_libraries(runtime_ts PUBLIC "${OPENCV_IMPORT_LIBRARY}")

function(screen_module module)
  set(sources "")
  foreach(source ${ARGN})
    list(APPEND sources "${OPENCV_SOURCE}/modules/${module}/perf/${source}.cpp")
  endforeach()
  add_executable(screen_${module} main.cpp ${sources})
  target_compile_definitions(screen_${module} PRIVATE RUNTIME_MODULE="${module}")
  target_link_libraries(screen_${module} PRIVATE runtime_ts)
endfunction()

screen_module(core perf_arithm perf_dft perf_norm perf_math)
screen_module(imgproc perf_resize perf_blur perf_cvt_color perf_canny perf_morph)
screen_module(calib3d perf_pnp)
screen_module(features2d perf_batchDistance)
screen_module(dnn perf_convolution perf_common)
