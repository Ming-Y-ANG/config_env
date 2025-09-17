#!/bin/sh

#DEBUG=1

path=$(pwd)
dir=${VG9_ROOT_DIR}

if [ "$dir" = "/root/INOS/VG-release/" -o "$dir" = "/root/INOS/VG-dev/" -o "$dir" = "/root/INOS/VG-D/" -o "$dir" = "/root/INOS/VG7-D/" -o "$dir" = "/root/INOS/VG-tls1.3/" -o "$dir" = "/root/INOS/VG-M/" ]; then
    #gcc 5.2 + eglibc 2.19 for git VG9
    export PATH=${dir}/compiler/ipq4029-arm_cortex-a7_gcc-5.2.0_glibc-2.19_eabi/bin:$PATH
	export STAGING_DIR=${repo}compiler/ipq4029-arm_cortex-a7_gcc-5.2.0_glibc-2.19_eabi
elif [ "$dir" = "/root/INOS/VG9-3.14/" ]; then
    #gcc 4.8.3 + eglibc 2.19 for git VG9
    export PATH=${dir}/compiler/ipq4029-arm_cortex-a7_gcc-4.8-linaro_uClibc-1.0.14_eabi/bin:$PATH
else
    echo "\033[40;31mERROR: VG9 root dir is empty!\033[0m"
    exit
fi

if [ -z "$(echo $path | grep $dir)" ]; then
	echo "\033[40;31mERROR: Current path($(pwd)) does not contains root dir($dir)!\033[0m"
	exit
fi

e=$(basename $0)
VG9_SYSTEM_DIR=${dir}/system

case $e in
    bt)
        echo "=====VG9_ROOT_DIR:${dir}====="
        #read -p "Are you sure to compile TEST version, input any key to continue" tmp
        ${DEBUG:+echo} cd ${VG9_SYSTEM_DIR} && ${DEBUG:+echo} ./build.sh test VG9
        ;;
    bb)
        echo "=====VG9_ROOT_DIR:${dir}====="
        read -p "Are you sure to compile BETA version, input enter to continue" tmp
        ${DEBUG:+echo} cd ${VG9_SYSTEM_DIR} && ${DEBUG:+echo} ./build.sh beta VG9
        ;;
    br)
        echo "=====VG9_ROOT_DIR:${dir}====="
        read -p "Are you sure to compile RELEASE version, input enter to continue" tmp
        ${DEBUG:+echo} cd ${VG9_SYSTEM_DIR} && ${DEBUG:+echo} ./build.sh release VG9
        ;;
    mk)
        echo "=====VG9_ROOT_DIR:${dir}====="
        #read -p "make a specific package, input enter to continue" tmp
        ${DEBUG:+echo} cd ${VG9_SYSTEM_DIR} && ${DEBUG:+echo} make $@
        ;;
    *)
        echo "the command does not be supported"
        ;;
esac
