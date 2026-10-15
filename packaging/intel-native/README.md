# Native Intel package builds

`BUILD.sh` configures and packages public OpenVINO and Intel NPU-driver sources in a disposable Debian Forky container. The dependency archive is the signed `20261012T023456Z` snapshot. Set `PROJ` to an owned directory below `$HOME/Projects`, containing the clean installer checkout and `caches/source/{openvino,npu-driver,npu_compiler}`. The configure scripts contain the exact upstream revisions and preserve the CPU, GPU, and NPU components.

Every build requires clean pinned sources, disk-backed temporary/home/cache directories, and a successful zero-removal simulation of the exact dependency transaction. Logs and packages remain under `PROJ`. `JOBS` defaults to four and `BUILD_MEMORY` to 16 GiB. An existing dependency image may be supplied through `DOCKER_IMAGE`; its packages are checked against the pinned snapshot again.

The NPU compiler is built by the upstream driver ExternalProject from the pinned public compiler sources. Redistributable device firmware remains subject to its upstream binary redistribution license; it is not described as compiled source. Package dependency, license, and hardware runtime acceptance are separate gates after package generation. This recipe publishes nothing.


The OpenVINO package step emits the four selected runtime components (`core`,
`cpu`, `gpu`, `npu`). CPack retains its upstream mandatory Lintian post-build
check. The pre-build callback adds `changelog.Debian.gz` for the NCZ Debian
revision while preserving the upstream changelog and copyright bytes. CMake
documents this callback after staging and before archive production:
https://cmake.org/cmake/help/latest/module/CPack.html#variable:CPACK_PRE_BUILD_SCRIPTS

Package output must be fresh; earlier diagnostic Debs remain in the compiled
cache and are not copied into the candidate directory. Epoch 1 distinguishes
the native OpenVINO version from the higher vendor numeric build suffix. The
final controls, exact internal dependencies, signed snapshot install, and CPU
inference still require artifact QA; source approval does not prove these.
The initial C++ compilation and the later metadata/package recipe revisions
are recorded separately in the build evidence.

### GCC 16 generated-parser guard

The public NPU compiler uses LLVM `8f3977c01be0f24be98b67ef2c911fd82657f30c`.
Its MLIR generator relies on debug-only assertions before dereferencing required
parsed parameters; GCC 16 Release compilation reports `-Werror=maybe-uninitialized`.
The versioned `patches/0001-mlir-required-parse-guard.patch` emits runtime failure
checks for required parameters, preserving optional/default handling and strict
warning settings. The builder completes the upstream source-fetch target before
applying this patch; it never edits generated parser output.

`APPLY-NPU-LLVM-PATCH.py` derives deterministic commits for the patched LLVM tree
and its compiler gitlink, verifies both working trees clean, and records original
pins, derived commits, patch digest and materialized source digest in
`logs/npu-compiler-patched-source.json`. These derived commits differ from the
public upstream pins; the public NCZ recipe carries the complete source patch.
The helper requires `SOURCE_DATE_EPOCH` and a pre-existing owned `TMPDIR` on the
builder's checked disk-backed task bind. Run `python3 packaging/intel-native/test-npu-llvm-patch.py`
with `TMPDIR` under Projects to exercise real isolated Git positive/negative cases.
