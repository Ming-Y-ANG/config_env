#!/bin/bash
docker run --rm \
    -v '/home/ym/dev:/test'\
    -it ubuntu:18.04 \
    /bin/bash 
	#-e 'HTTP_PROXY=http://192.168.101.244:7890' \
    #-e 'HTTPS_PROXY=http://192.168.101.244:7890'\
