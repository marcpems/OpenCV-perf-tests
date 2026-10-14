#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <iostream>

int main()
{
    cv::Mat input(16, 16, CV_8UC3, cv::Scalar(128, 128, 128));
    cv::Mat gray, blurred, resized;
    cv::cvtColor(input, gray, cv::COLOR_BGR2GRAY);
    cv::GaussianBlur(gray, blurred, cv::Size(3, 3), 1.0);
    cv::resize(blurred, resized, cv::Size(8, 8));
    if (cv::countNonZero(resized != 128) != 0) {
        std::cerr << "Image-operation smoke check failed\n";
        return 1;
    }
    cv::Mat matrix = (cv::Mat_<float>(2, 2) << 1, 2, 3, 4);
    cv::Mat expected = (cv::Mat_<float>(2, 2) << 7, 10, 15, 22);
    if (cv::norm(matrix * matrix, expected, cv::NORM_INF) > 1e-6) {
        std::cerr << "Matrix-operation smoke check failed\n";
        return 1;
    }
    std::cout << "OpenCV " << CV_VERSION << ": image and matrix smoke checks passed\n";
}
