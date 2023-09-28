#!/bin/sh

. ./function.sh

cd ${HOME}
#Install clang+llvm
wget https://releases.llvm.org/7.0.1/clang+llvm-7.0.1-x86_64-linux-gnu-ubuntu-16.04.tar.xz
tar -Jxv -f clang+llvm-7.0.1-x86_64-linux-gnu-ubuntu-16.04.tar.xz

#Install gcc-7/g++-7
sudo_wrapper apt-get install -y software-properties-common
sudo_wrapper add-apt-repository ppa:ubuntu-toolchain-r/test
sudo_wrapper apt update
sudo_wrapper apt install g++-7 libssl-dev -y --no-install-recommends

#upgrade cmake
sudo_wrapper apt remove $(dpkg -l | grep cmake | awk '{print $2}' | xargs)
wget https://github.com/Kitware/CMake/releases/download/v3.18.1/cmake-3.18.1.tar.gz
tar -zxv -f cmake-3.18.1.tar.gz
cd cmake-3.18.1
./configure --prefix=/usr
make
sudo_wrapper make install

#Install ccls
git clone --depth=1 --recursive https://github.com/MaskRay/ccls
cd ccls
cmake -H. -BRelease -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=${HOME}/clang+llvm-7.0.1-x86_64-linux-gnu-ubuntu-16.04 -DCMAKE_CXX_COMPILER=/usr/bin/g++-7
cd Release
make V=s
cp ccls ~/tools/ccls-ubuntu-16.04

#clean
rm -rf ${HOME}/ccls ${HOME}/cmake-3.18.1.*
