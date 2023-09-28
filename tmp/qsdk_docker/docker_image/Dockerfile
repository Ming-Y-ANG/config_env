FROM ubuntu:16.04
MAINTAINER dengzt@inhand.com.cn 
RUN apt-get update && apt-get upgrade -y && apt-get install -y \
build-essential ccache ecj fastjar file g++ gawk \
gettext git java-propose-classpath libelf-dev libncurses5-dev \
libncursesw5-dev libssl-dev python python2.7-dev python3 unzip wget \
python3-setuptools python3-dev rsync subversion \
swig time xsltproc zlib1g-dev ocaml sharutils && rm -rf /var/lib/apt/lists/*
RUN groupadd -g 1000 openwrt && useradd -m -d /home/openwrt -s /bin/bash -g openwrt -G sudo -u 1000 openwrt
USER openwrt
WORKDIR /home/openwrt
