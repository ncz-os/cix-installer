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
