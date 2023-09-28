#!/bin/sh

. ./function.sh

#Install clang+llvm
sudo_wrapper apt update
sudo_wrapper apt-get install zlib1g zlib1g-dev libclang-8-dev
sudo_wrapper apt install clang-8
sudo_wrapper apt install cmake

sudo_wrapper update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-8 50
sudo_wrapper update-alternatives --install /usr/bin/clang clang /usr/bin/clang-8 50

#Install ccls
git clone --depth=1 --recursive https://github.com/MaskRay/ccls

cd ccls
cmake -H. -BRelease -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER=clang++-8 -DCMAKE_PREFIX_PATH=/usr
cd Release && make V=s
cp ccls ~/tools/ccls-ubuntu-18.04

#Fix some issues
cd ~/.config/coc/extensions/node_modules/coc-ccls && ln -s node_modules/ws/lib lib
npm i -g bash-language-server

#clean
rm -rf ccls
