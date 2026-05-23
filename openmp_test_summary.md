# OpenMP Test Summary

## 1. 测试目的

验证 ABACUS 矩阵对角化模块的 OpenMP 多线程路径是否在不改变算法逻辑的前提下保持正确性，并为底层 CPU vector kernel 的并行加速提供性能记录。

重点验证对象是 `source/source_base/kernels/math_kernel_op.h` 和 `source/source_base/kernels/math_kernel_op_vec.cpp` 所对应的逐元素向量/标量算子路径，以及 `source/source_hsolver/diago_cg.cpp`、`source/source_hsolver/diago_david.cpp` 中频繁调用这些 kernel 的测试入口。

## 2. 测试对象和文件路径

- `source/source_hsolver/test/CMakeLists.txt`
- `source/source_hsolver/test/diago_cg_test.cpp`
- `source/source_hsolver/test/diago_cg_float_test.cpp`
- `source/source_hsolver/test/diago_david_test.cpp`
- `source/source_hsolver/test/diago_david_float_test.cpp`
- `source/source_hsolver/test/diago_bpcg_test.cpp`
- `source/source_hsolver/test/diago_cg_parallel_test.sh`
- `source/source_hsolver/test/diago_david_parallel_test.sh`
- `tools/benchmark_openmp_diago.sh`

## 3. 测试环境和线程设置

- Conda 环境：`abacus`
- Build 目录：`build/`
- 运行目录：`build/source/source_hsolver/test/`
- OpenMP 线程：`OMP_NUM_THREADS=1,2,4,8`（本次验证）
- BLAS 线程控制：`MKL_NUM_THREADS=1`，`OPENBLAS_NUM_THREADS=1`

建议运行方式：

```bash
conda activate abacus
bash tools/benchmark_openmp_diago.sh
```

可通过环境变量覆盖目标和输出目录，例如：

```bash
conda activate abacus
TARGETS="MODULE_HSOLVER_cg MODULE_HSOLVER_dav" bash tools/benchmark_openmp_diago.sh
```

## 4. 正确性结果表

说明：以下结果来自本次实际运行的 `tools/benchmark_openmp_diago.sh` 输出。

| Target | 1 线程 | 2 线程 | 4 线程 | 8 线程 | 对比说明 |
| --- | --- | --- | --- | --- | --- |
| `MODULE_HSOLVER_cg` | PASS | PASS+MATCH | PASS+MATCH | PASS+MATCH | 四个线程配置下 gtest 全部通过，且各线程日志与基线一致 |
| `MODULE_HSOLVER_dav` | PASS | PASS+MATCH | PASS+MATCH | PASS+MATCH | 四个线程配置下 gtest 全部通过，且各线程日志与基线一致 |
| `MODULE_HSOLVER_bpcg` | PASS | PASS+MATCH | PASS+MATCH | PASS+MATCH | 四个线程配置下 gtest 全部通过，且各线程日志与基线一致 |

如果只运行单元测试而没有显式输出本征值或总能量，则将“结果一致”定义为：相同测试用例在 1/2/4/8 线程下均返回 0 且 gtest 全部通过。

## 5. 性能结果表

请将 `tools/benchmark_openmp_diago.sh` 生成的 CSV 汇总到下表。

| threads | time | speedup | efficiency | status |
| --- | --- | --- | --- | --- |
| 1 | 0.66 / 0.73 / 0.59 | 1.000000 | 1.000000 | PASS |
| 2 | 0.73 / 0.72 / 0.58 | 0.904110 / 1.013889 / 1.017241 | 0.452055 / 0.506945 / 0.508621 | PASS+MATCH |
| 4 | 0.63 / 0.69 / 0.55 | 1.047619 / 1.057971 / 1.072727 | 0.261905 / 0.264493 / 0.268182 | PASS+MATCH |
| 8 | 0.72 / 0.72 / 0.57 | 0.916667 / 1.013889 / 1.035088 | 0.114583 / 0.126736 / 0.129386 | PASS+MATCH |

CSV 文件位置示例：`openmp_benchmark_logs/MODULE_HSOLVER_cg/benchmark_openmp_MODULE_HSOLVER_cg.csv`

## 6. 总结

本次 OpenMP 测试的目标是确认底层 vector kernel 的多线程正确性和性能趋势，而不是并行化 `DiagoCG` 的 band-by-band 外层循环，也不对 `dot_real_op`、`gemv/gemm/axpy`、`diag_zhegvx`、MPI reduce 等路径进行不必要的嵌套 OpenMP 改造。

如果加速不明显，常见原因通常包括：

- 小规模算例下线程启动和同步开销较高
- 内存带宽限制导致 vector kernel 不能线性扩展
- BLAS/MPI 通信占比仍然较大
- 正交化和 band-by-band 顺序依赖保留了串行部分

## 附录

可直接运行的检查命令：

```bash
conda activate abacus
cd build
ctest -R '^MODULE_HSOLVER_(cg|dav|bpcg)$' --output-on-failure
OMP_NUM_THREADS=4 OMP_PROC_BIND=spread OMP_PLACES=cores ctest -R MODULE_HSOLVER_LCAO_parallel --output-on-failure
```

如果 `ctest` 未注册对应测试，则请先确认 `build/source/source_hsolver/test/CTestTestfile.cmake` 是否存在，并确保 `BUILD_TESTING=ON` 后重新配置。
