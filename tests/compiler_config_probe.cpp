#include <vector>

#define STRINGIFY_VALUE(x) #x
#define STRINGIFY(x) STRINGIFY_VALUE(x)
#pragma message("_M_ARM64=" STRINGIFY(_M_ARM64))
#pragma message("_MSC_VER=" STRINGIFY(_MSC_VER))
#pragma message("_MSVC_LANG=" STRINGIFY(_MSVC_LANG))
#pragma message("_ITERATOR_DEBUG_LEVEL=" STRINGIFY(_ITERATOR_DEBUG_LEVEL))
#pragma message("_MSVC_STL_HARDENING=" STRINGIFY(_MSVC_STL_HARDENING))
#pragma message("_CPPUNWIND=" STRINGIFY(_CPPUNWIND))
#pragma message("_DLL=" STRINGIFY(_DLL))
#ifdef NDEBUG
#pragma message("NDEBUG=defined")
#else
#error Expected Release compilation
#endif
static_assert(sizeof(void*) == 8, "Expected 64-bit target");
int compiler_config_probe() { return _ITERATOR_DEBUG_LEVEL; }
