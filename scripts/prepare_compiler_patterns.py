"""Generate local compiler-cost probes without changing the OpenCV checkout."""

import argparse
import hashlib
import json
from pathlib import Path
import re

DLS_ASSIGNMENTS = 1968


def synthetic(pattern, count):
    if pattern not in ("view", "cached", "table") or count <= 0:
        raise ValueError("Expected a known pattern and positive statement count")
    header = """struct MatrixView {
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
"""
    signature = f'extern "C" void fill_{pattern}_{count}(MatrixView& m, const Values& v)'
    if pattern == "table":
        entries = ",\n".join(f"    {{{i // 32}, {(i * 17) % 32}, {(i * 7) % 64}}}"
                             for i in range(count))
        body = ("    static const unsigned entries[][3] = {\n" + entries + "\n    };\n"
                f"    for (unsigned i = 0; i < {count}; ++i)\n"
                "        m.at(entries[i][0], entries[i][1]) = v.at(entries[i][2]);\n")
    else:
        body = ""
        if pattern == "cached":
            body = ("    unsigned char* data = m.data;\n"
                    "    const unsigned long long stride = m.stride;\n"
                    "    const double* values = v.data;\n")
        for i in range(count):
            row, col, value = i // 32, (i * 17) % 32, (i * 7) % 64
            if pattern == "view":
                body += f"    m.at({row}, {col}) = v.at({value});\n"
            else:
                body += f"    reinterpret_cast<double*>(data + {row} * stride)[{col}] = values[{value}];\n"
    return header + signature + " {\n" + body + "}\n"


def cached_dls(text):
    start = text.index("Mat dls::cayley_LS_M(")
    end = text.index("\nMat dls::Hessian(", start)
    original = text[start:end]
    declaration = "    Mat M = Mat::zeros(120, 120, CV_64F);"
    if original.count(declaration) != 1:
        raise ValueError("Unexpected DLS matrix declaration")
    rewritten, stores = re.subn(r"M\.at<double>\((\d+),(\d+)\)",
                               r"m_data[\1 * m_stride + \2]", original)
    rewritten, loads = re.subn(r"\b([abcu])\[(\d+)\]", r"\1_data[\2]", rewritten)
    if stores != DLS_ASSIGNMENTS or loads != DLS_ASSIGNMENTS:
        raise ValueError(f"Unexpected pinned DLS assignment counts: {stores}, {loads}")
    pointers = """
    double* m_data = M.ptr<double>();
    const size_t m_stride = M.step1();
    const double* a_data = a.data();
    const double* b_data = b.data();
    const double* c_data = c.data();
    const double* u_data = u.data();"""
    rewritten = rewritten.replace(declaration, declaration + pointers)
    return text[:start] + rewritten + text[end:], original, rewritten


def prepare(root, output):
    if output.exists():
        raise ValueError("Choose a fresh output directory")
    source = root / "modules" / "calib3d" / "src" / "dls.cpp"
    text = source.read_text()
    rewritten, original, cached = cached_dls(text)
    output.mkdir(parents=True)
    (output / "dls_cached.cpp").write_text(rewritten)
    functions = (original.replace("Mat dls::cayley_LS_M(", "Mat original_matrix(")
                 + cached.replace("Mat dls::cayley_LS_M(", "Mat cached_matrix("))
    validation = """#include <opencv2/core.hpp>
#include <vector>
#include <cstdio>
using namespace cv;
""" + functions + """
int main() {
    for (int seed = 0; seed < 16; ++seed) {
        std::vector<double> a(21), b(21), c(21), u(21);
        for (int i = 0; i < 21; ++i) {
            a[i] = seed * 31 + i;
            b[i] = seed * 17 - i * 3;
            c[i] = seed * 11 + i * 7;
            u[i] = seed * 5 - i;
        }
        Mat x = original_matrix(a, b, c, u);
        Mat y = cached_matrix(a, b, c, u);
        if (x.size() != y.size() || norm(x, y, NORM_INF) != 0) return 1;
    }
    std::puts("DLS original/cached matrix outputs match for all 16 input sets");
    return 0;
}
"""
    (output / "validate_dls.cpp").write_text(validation)
    for count in (512, 2048, 4096):
        for pattern in ("view", "cached", "table"):
            (output / f"{pattern}_{count}.cpp").write_text(synthetic(pattern, count))
    manifest = {
        "original_dls_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "changed_function": "cv::dls::cayley_LS_M",
        "assignment_count": DLS_ASSIGNMENTS,
        "files_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in sorted(output.glob("*.cpp"))},
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2))
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    print(json.dumps(prepare(args.root, args.output), indent=2))


if __name__ == "__main__":
    main()
