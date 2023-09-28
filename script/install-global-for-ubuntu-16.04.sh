#!/bin/sh

. ./function.sh

sudo_wrapper add-apt-repository ppa:alexmurray/global -y
sudo_wrapper apt update
sudo_wrapper apt install global=6.5.7-1~bpo16.04+1
