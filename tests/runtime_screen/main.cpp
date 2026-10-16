#include <opencv2/ts.hpp>
#include <opencv2/ts/ts_perf.hpp>
#include <windows.h>
#include <chrono>
#include <cstdlib>
#include <iostream>

int main(int argc, char** argv)
{
    const char* affinity_text = std::getenv("RUNTIME_AFFINITY");
    if (affinity_text) {
        char* end = nullptr;
        const auto mask = std::strtoull(affinity_text, &end, 0);
        if (!mask || !end || *end || !SetProcessAffinityMask(GetCurrentProcess(), static_cast<DWORD_PTR>(mask))) {
            std::cerr << "Unable to set requested process affinity\n";
            return 2;
        }
        DWORD_PTR actual = 0, system = 0;
        if (!GetProcessAffinityMask(GetCurrentProcess(), &actual, &system) || actual != mask) {
            std::cerr << "Process affinity verification failed\n";
            return 2;
        }
        std::cout << "RUNTIME_AFFINITY=" << actual << "\n";
    }
    const HMODULE module = GetModuleHandleW(L"opencv_world4100.dll");
    wchar_t path[32768] = {};
    const DWORD length = module ? GetModuleFileNameW(module, path, 32768) : 0;
    USHORT process_machine = 0, native_machine = 0;
    if (!length || length >= 32768 ||
        !IsWow64Process2(GetCurrentProcess(), &process_machine, &native_machine)) {
        std::cerr << "Unable to audit loaded OpenCV DLL or process architecture\n";
        return 2;
    }
    if (process_machine != IMAGE_FILE_MACHINE_UNKNOWN ||
        native_machine != IMAGE_FILE_MACHINE_ARM64) {
        std::cerr << "Expected native ARM64 test process\n";
        return 2;
    }
    std::wcout << L"RUNTIME_DLL=" << path << L"\n";
    std::cout << "RUNTIME_NATIVE_ARM64=1\n";
    ::perf::Regression::Init(RUNTIME_MODULE);
    ::perf::TestBase::Init(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    ::testing::UnitTest::GetInstance()->listeners().Append(new cvtest::SystemInfoCollector);
    ::testing::Test::RecordProperty("cv_module_name", RUNTIME_MODULE);
    ::perf::TestBase::RecordRunParameters();
    cv::setNumThreads(cvtest::testThreads);
    std::cout << "RUNTIME_THREADS=" << cv::getNumThreads() << "\n";
    if (affinity_text) {
        cv::parallel_for_(cv::Range(0, cv::getNumThreads()), [](const cv::Range& range) {
            const auto until = std::chrono::steady_clock::now() + std::chrono::seconds(1);
            volatile unsigned value = static_cast<unsigned>(range.start + 1);
            while (std::chrono::steady_clock::now() < until)
                value = value * 1664525u + 1013904223u;
        }, cv::getNumThreads());
        std::cout << "RUNTIME_CPU_WARMUP=1\n";
    }
    const char* main_affinity_text = std::getenv("RUNTIME_MAIN_AFFINITY");
    if (main_affinity_text) {
        char* end = nullptr;
        const auto mask = std::strtoull(main_affinity_text, &end, 0);
        GROUP_AFFINITY actual = {};
        if (!mask || (mask & (mask - 1)) || !end || *end ||
            !SetThreadAffinityMask(GetCurrentThread(), static_cast<DWORD_PTR>(mask)) ||
            !GetThreadGroupAffinity(GetCurrentThread(), &actual) ||
            actual.Group != 0 || actual.Mask != mask) {
            std::cerr << "Main-thread affinity verification failed\n";
            return 2;
        }
        std::cout << "RUNTIME_MAIN_AFFINITY=" << mask << "\n";
    }
    return RUN_ALL_TESTS();
}
