#!/bin/sh

#change software source
sudo sed -i -e 's|cn.archive.ubuntu.com|mirrors.tuna.tsinghua.edu.cn|g' -e 's|archive.canonical.com|mirrors.tuna.tsinghua.edu.cn|g' -e 's|security.ubuntu.com|mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list

#update software database
sudo apt update && sudo apt upgrade

#install build-essential
sudo apt install build-essential tig tmux bear

#install vim
#refer to ./install-vim-from-source.sh

#config samba share
sudo mkdir /tftpboot
chmod 777 /tftpboot
sudo chown -R dengzt:dengzt /tftpboot
sudo cp smb.conf /etc/samba/smb.conf
sudo smbpasswd -a dengzt
