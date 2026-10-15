#include <cstdio>
#include <vector>

struct MatrixView {
    unsigned char* data;
    unsigned long long stride;
    double& at(unsigned row, unsigned col) const {
        return reinterpret_cast<double*>(data + row * stride)[col];
    }
};
struct Values {
    const double* data;
    const double& at(unsigned index) const { return data[index]; }
};

#define DECLARE(pattern, count) extern "C" void fill_##pattern##_##count(MatrixView&, const Values&)
DECLARE(view, 512);
DECLARE(cached, 512);
DECLARE(table, 512);
DECLARE(view, 2048);
DECLARE(cached, 2048);
DECLARE(table, 2048);
DECLARE(view, 4096);
DECLARE(cached, 4096);
DECLARE(table, 4096);

int main()
{
    struct Case { unsigned count; void (*fill)(MatrixView&, const Values&); };
    const Case cases[] = {
        {512, fill_view_512}, {512, fill_cached_512}, {512, fill_table_512},
        {2048, fill_view_2048}, {2048, fill_cached_2048}, {2048, fill_table_2048},
        {4096, fill_view_4096}, {4096, fill_cached_4096}, {4096, fill_table_4096}
    };
    for (int seed = 0; seed < 4; ++seed) {
        double values[64];
        for (unsigned i = 0; i < 64; ++i) values[i] = i * 17 + seed * 11;
        for (const Case& test : cases) {
            std::vector<double> expected((test.count / 32) * 40, -999);
            std::vector<double> actual = expected;
            for (unsigned i = 0; i < test.count; ++i)
                expected[(i / 32) * 40 + (i * 17) % 32] = values[(i * 7) % 64];
            MatrixView matrix{reinterpret_cast<unsigned char*>(actual.data()), 40 * sizeof(double)};
            Values input{values};
            test.fill(matrix, input);
            if (actual != expected) return 1;
        }
    }
    std::puts("All 9 compiler patterns match reference output, including row padding, for 4 input sets");
    return 0;
}
