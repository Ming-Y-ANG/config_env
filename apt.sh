#!/bin/bash
sed -i -e 's/archive.ubuntu.com/mirrors.ustc.edu.cn/g'\
	-e 's/security.ubuntu.com/mirrors.ustc.edu.cn/g'\
	/etc/apt/sources.list
