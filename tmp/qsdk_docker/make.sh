#!/bin/sh

BASE_DIR=$(pwd)

HOST_PROJECT_DIR="${BASE_DIR}/qsdk-for-fara-release-20220325-v1"

COMPILE_COMMAND='
	cd /home/openwrt \
	&& ./scripts/feeds update -a \
	&& ./scripts/feeds install -a -f \
	&& git checkout .config \
	&& make defconfig \
	&& make V=s 2>&1 | tee log
'

[ -f ./0001-fix-qca-hostap-prebuilt-issue.patch -a -f qsdk-for-fara-release-20220325-v1.tar.gz ] || {
	echo "\033[31mPlease copy 0001-fix-qca-hostap-prebuilt-issue.patch and qsdk-for-fara-release-20220325-v1.tar.gz to this directory ...\033[0m"
	exit
}

# 1. setup openwrt dir
[ -d ${HOST_PROJECT_DIR} ] || {
	echo "\033[32mSetup OpenWrt DIR ...\033[0m"
	(tar -zxf qsdk-for-fara-release-20220325-v1.tar.gz \
		&& cd qsdk-for-fara-release-20220325-v1 \
		&& git init && git add . \
		&& git ci -s -m "init repo" 2>&1 > /dev/null \
		&& git am ../0001-fix-qca-hostap-prebuilt-issue.patch --reject --ignore-whitespace)
}
# 2. build compile environment
[ -n "$(docker images -q ubuntu:16.04-qsdk)" ] || {
	echo "\033[32mBuild compile environment ...\033[0m"
	(cd docker_image && docker build -f Dockerfile . -t ubuntu:16.04-qsdk)
}

# 3. compile sdk
echo "\033[32mCompile SDK ...\033[0m"
docker run --rm -v "${HOST_PROJECT_DIR}:/home/openwrt" ubuntu:16.04-qsdk sh -c "${COMPILE_COMMAND}"
