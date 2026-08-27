# CIX VPU DKMS
This repo provides dkms source code of CIX VPU, which can be easily installed on morden linux system.

## DKMS packaging
It's easy to build dkms deb package from this repo:
```
# Get source code from this repo
git clone https://github.com/cixtech/cix_opensource__vpu_driver.git -b cix_mainline_dev

# Build deb package via gbp command
gbp buildpackage --git-ignore-branch --git-builder='debuild --no-lintian -uc -us'
```
Then you get two deb package like `cix-vpu-driver-dkms_1.0.1-1_all.deb` and `cix-vpu-firmware_1.0.1-1_all.deb` at the parent directory.

## Install DKMS package
You can install the built two deb packages in a debian-based os:
```
sudo apt install ./cix-vpu-driver-dkms_1.0.1-1_all.deb ./cix-vpu-firmware_1.0.1-1_all.deb
```
