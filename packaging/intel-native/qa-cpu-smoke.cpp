// SPDX-License-Identifier: MIT
#include <openvino/openvino.hpp>
#include <openvino/opsets/opset13.hpp>
#include <cmath>
#include <cstdio>

int main() {
    try {
        using namespace ov::opset13;
        auto input = std::make_shared<Parameter>(ov::element::f32, ov::Shape{1});
        auto c = Constant::create(ov::element::f32, ov::Shape{1}, {4.0f});
        auto add = std::make_shared<Add>(input, c);
        auto result = std::make_shared<Result>(add);
        auto model = std::make_shared<ov::Model>(ov::ResultVector{result}, ov::ParameterVector{input});

        ov::Core core;
        auto compiled = core.compile_model(model, "CPU");
        auto infer = compiled.create_infer_request();

        ov::Tensor in_tensor(ov::element::f32, ov::Shape{1});
        in_tensor.data<float>()[0] = 3.0f;
        infer.set_input_tensor(in_tensor);
        infer.infer();

        ov::Tensor out = infer.get_output_tensor(0);
        if (out.get_element_type() != ov::element::f32) { std::fprintf(stderr, "bad type\n"); return 1; }
        if (out.get_shape() != ov::Shape{1}) { std::fprintf(stderr, "bad shape\n"); return 1; }
        float v = out.data<float>()[0];
        if (!std::isfinite(v) || std::fabs(v - 7.0f) > 1e-5f) { std::fprintf(stderr, "bad value %f\n", v); return 1; }

        std::printf("CPU_INFERENCE_PASS\n");
        return 0;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "exception: %s\n", e.what());
        return 1;
    }
}
