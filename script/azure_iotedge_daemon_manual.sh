docker run --rm --user root -e USER=root -v /home/dengzt/repo/iotedge.git:/project -it iotdge-compile-env:v1 /bin/bash

dpkg --add-architecture armel
apt update
apt-get upgrade -y
apt-get install -y --no-install-recommends binutils build-essential ca-certificates cmake curl debhelper dh-systemd file git make gcc g++ gcc-arm-linux-gnueabi g++-arm-linux-gnueabi  libcurl4-openssl-dev:armel libssl-dev:armel uuid-dev:armel


mkdir -p ~/.cargo
echo '[target.armv7-unknown-linux-gnueabi]' > ~/.cargo/config
echo 'linker = "arm-linux-gnueabi-gcc"' >> ~/.cargo/config
curl -sSLf https://sh.rustup.rs | sh -s -- -y
. ~/.cargo/env


mkdir -p /project/edgelet/target/hsm
cd /project/edgelet/target/hsm


export ARMV7_UNKNOWN_LINUX_GNUEABI_OPENSSL_LIB_DIR=/usr/lib/arm-linux-gnueabi
export ARMV7_UNKNOWN_LINUX_GNUEABI_OPENSSL_INCLUDE_DIR=/usr/include
export ARMV7_UNKNOWN_LINUX_GNUEABIHF_OPENSSL_LIB_DIR=/usr/lib/arm-linux-gnueabi
export ARMV7_UNKNOWN_LINUX_GNUEABIHF_OPENSSL_INCLUDE_DIR=/usr/include
export CROSS_COMPILE=arm-linux-gnueabi-

cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED=On -Drun_unittests=Off -Duse_default_uuid=On -Duse_emulator=Off -Duse_http=Off -DCPACK_GENERATOR=DEB -DCPACK_PACKAGE_VERSION=1.1.3 -DCPACK_DEBIAN_PACKAGE_RELEASE=1 -DOPENSSL_DEPENDS_SPEC=libssl1.1 -DCPACK_DEBIAN_PACKAGE_ARCHITECTURE=armel -DCPACK_RPM_PACKAGE_ARCHITECTURE=armv7hl -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_VERSION=1 -DCMAKE_C_COMPILER=arm-linux-gnueabi-gcc -DCMAKE_CXX_COMPILER=arm-linux-gnueabi-g++ /project/edgelet/hsm-sys/azure-iot-hsm-c/ && make -j package


cd /project/edgelet
rustup target add armv7-unknown-linux-gnueabi
make deb 'VERSION=1.1.3' 'REVISION=1' 'CARGOFLAGS=--target armv7-unknown-linux-gnueabi' 'TARGET=target/armv7-unknown-linux-gnueabi/release' 'DPKGFLAGS=-b -us -uc -i --host-arch armel'


