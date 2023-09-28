#!/bin/bash
set -euxo pipefail

USER=$(whoami)
DEF_PASSWD=1

sudo_wrapper(){
	if [ $USER == root ]; then
	   $@
	else
	   echo $DEF_PASSWD | sudo -S -k $@
	fi
}

program_exists() {
    local ret='0'
    command -v $1 >/dev/null 2>&1 || { local ret='1'; }

    # fail on non-zero return value
    return $ret

}

npm_update() {
	local verson='9.5.1'
	ver[0]=$version
	ver[1]=$(npm -v)

	new=$(echo ${ver[*]} | tr ' ' '\n' | sort -n)
	a=0
	for i in $new
	do
	   arr[$a]=$i
	   let a++
	done
	if [ ${arr[0]} != $version ]; then
	   sudo_wrapper npm install -g npm@$version
	fi
}

install_nodejs(){
	(program_exists node) || { 
		echo "nodejs not exit, download it now!"
		VERSION=v16.17.0
		PACK=node-$VERSION-linux-x64.tar.gz
		URL="https://nodejs.org/dist/$VERSION/$PACK"
		PREFIX=/usr/local
		rm -rf $PACK
		wget "${URL}" 
		tar xzfv $PACK\
			--exclude CHANGELOG.md \
			--exclude LICENSE \
			--exclude README.md \
			--strip-components 1 \
			-C "${PREFIX}"
	}
}


install_utilities(){

	local distro_support=$1

	[ -z "$distro_support" ] && {
		echo "use 'install_utilities DISTRO_SUPPORT'"
		return
	}

	#Install some utilities
	echo "Install some utilities ..."
	tools_dir="$HOME/tools"
	[ -d $tools_dir ] && {
	    rm -rf $tools_dir
	}
	tar -cvf - tools | tar -xvf - -C $HOME

	sudo_wrapper apt update
	sudo_wrapper apt install build-essential software-properties-common -y --no-install-recommends
	sudo_wrapper apt install wget curl git tig global expect bear autoconf -y --no-install-recommends
	

	case "$DISTRO_SUPPORT" in
		Ubuntu-16.04)
			#Install tmux global vim
			sudo_wrapper add-apt-repository ppa:bundt/backports -y
			sudo_wrapper add-apt-repository ppa:alexmurray/global -y
			sudo_wrapper add-apt-repository ppa:jonathonf/vim -y
			#sed -i -e 's/ppa.launchpad.net/launchpad.proxy.ustclug.org/g' /etc/apt/sources.list.d/*.list
			sudo_wrapper apt update
			sudo_wrapper apt install tmux=3.1c-ppa-xenial1 global=6.5.7-1~bpo16.04+1 vim=2:8.2.3458-0york0~16.04 -y
		;;
		Ubuntu-18.04)
			#Install tmux vim
			sudo_wrapper add-apt-repository ppa:bundt/backports -y
			sudo_wrapper add-apt-repository ppa:jonathonf/vim -y
			#sed -i -e 's/ppa.launchpad.net/launchpad.proxy.ustclug.org/g' /etc/apt/sources.list.d/*.list
			sudo_wrapper apt update
			sudo_wrapper apt install tmux=3.1c-1ppa~bionic1 vim=2:9.0.0749-0york0~18.04 -y
		;;
		*)
			apt install tmux global -y --no-install-recommends
		;;
	esac

	cp tmux.conf ${HOME}/.tmux.conf
}

configure_bashrc(){
	#check if it is configured
	[ -z "$(grep 'begin:user custom definition' ~/.bashrc)" ] || {
		echo "bashrc is configured, skip"
		return
	}

	#configure bashrc for bash
	echo "Add custom changes to .bashrc file ..."
	cp ~/.bashrc bashrc
	echo "#===========begin:user custom definition=========" >> bashrc
	echo "alias g='grep -nr --color=auto --exclude-dir=.ccls-cache'" >> bashrc
	echo "alias rm='rm -i'" >> bashrc
	#use 256 color
	echo "alias man=\"LESS_TERMCAP_mb=$'\e[01;31m' LESS_TERMCAP_md=$'\e[01;38;5;170m' LESS_TERMCAP_me=$'\e[0m' LESS_TERMCAP_se=$'\e[0m' LESS_TERMCAP_so=$'\e[38;5;246m' LESS_TERMCAP_ue=$'\e[0m' LESS_TERMCAP_us=$'\e[04;38;5;74m' man\"" >>bashrc
	echo "source $tools_dir/aliasfile" >> bashrc
	echo "PATH=$PATH:$tools_dir" >> bashrc
	echo "export EDITOR=vim" >> bashrc

	# cat >> bashrc <<'EOF'
	# export LESS_TERMCAP_md=$'\E[01;31m'
	# export LESS_TERMCAP_me=$'\E[0m'
	# export LESS_TERMCAP_se=$'\E[0m'
	# export LESS_TERMCAP_so=$'\E[01;44;33m'
	# export LESS_TERMCAP_ue=$'\E[0m'
	# export LESS_TERMCAP_us=$'\E[01;32m'
	# EOF
	echo "#===========end:user custom definition=========" >> bashrc
	mv bashrc ~/.bashrc
	source ~/.bashrc
}

configure_gitconfig(){
	#configure git setttings
	echo "Configure git setttings..."

	#read -p "user name for git" -t 5 username
	username=${username:-Ming-Y-ANG}

	#read -p "user email for git" -t 5 useremail
	useremail=${useremail:-714536723@qq.com}

	git config --global user.name $username
	git config --global user.email $useremail
	git config --global core.editor vim
	git config --global merge.tool vimdiff
	git config --global alias.co checkout
	git config --global alias.br branch
	git config --global alias.ci commit
	git config --global alias.st status
	git config --global alias.rb rebase
	git config --global alias.lm "log --no-merges --color --date=format:'%Y-%m-%d %H:%M' --author='$username' --pretty=format:'%Cgreen%cd %C(bold blue)%<(10)%an%Creset %Cred%h%Creset -%C(yellow)%d%Cblue %s%Creset' --abbrev-commit"
	git config --global alias.lms "log --no-merges --color --stat --date=format:'%Y-%m-%d %H:%M' --author='$username' --pretty=format:'%Cgreen%cd %C(bold blue)%<(10)%an%Creset %Cred%h%Creset -%C(yellow)%d%Cblue %s%Creset' --abbrev-commit"
	git config --global alias.ls "log --no-merges --color --date=format:'%Y-%m-%d %H:%M' --pretty=format:'%Cgreen%cd %C(bold blue)%<(10)%an%Creset %Cred%h%Creset -%C(yellow)%d%Cblue %s%Creset' --abbrev-commit"
	git config --global alias.lss "log --no-merges --color --stat --date=format:'%Y-%m-%d %H:%M' --pretty=format:'%Cgreen%cd %C(bold blue)%<(10)%an%Creset %Cred%h%Creset -%C(yellow)%d%Cblue %s%Creset' --abbrev-commit"
	git config --global push.default simple
}

configure_vim(){

	local distro_support=$1

	[ -z "$distro_support" ] && {
		echo "use 'configure_vim DISTRO_SUPPORT'"
		return
	}

	#configure vim
	echo "Configure VIM ..."
	#Install ccls and Nodejs for ubuntu 16.04
	case "${DISTRO_ID}-${DISTRO_RELEASE}" in
	    Ubuntu-20.04|Ubuntu-20.10|Ubuntu-21.04)
		sudo_wrapper apt install ccls -y
		#curl -sL install-node.vercel.app/lts | sudo_wrapper bash
		install_nodejs
		;;
	    Ubuntu-18.04)
		echo "Install ccls for $distro_support"
		# ./script/install-ccls-from-source-for-ubuntu-18.04.sh
		(cd $HOME/tools && ln -sf ccls-ubuntu-18.04 ccls)
		#curl -sL install-node.vercel.app/lts | sudo_wrapper bash
		install_nodejs
		;;
	    Ubuntu-16.04)
		echo "Install ccls for Ubuntu 16.04"
		# ./script/install-ccls-from-source-for-ubuntu-16.04.sh
		(cd $HOME/tools && ln -sf ccls-ubuntu-16.04 ccls)
		#curl -sL install-node.vercel.app/lts | sudo_wrapper bash
		install_nodejs
		;;
	    *)
		echo "Unspported DISTRO version, exit ..."
		exit
		;;
	esac

	cd ${HOME}/.config/coc/extensions/node_modules/coc-ccls && ln -sf node_modules/ws/lib
	#sudo_wrapper npm config set registry https://mirrors.huaweicloud.com/repository/npm/
	npm_update
	sudo_wrapper npm i -g bash-language-server

	#rmmove vim config directory first
	rm -rf $HOME/.vim

	vimrc_file="$HOME/.vimrc"
	vim_dir="$HOME/.vim"

	[ -f $vimrc_file ] && {
	    rm -rf $vimrc_file
	}
	ln -sf $vim_dir/init.vim $HOME/.vimrc

	[ -f $vim_dir ] && {
	    rm -rf $vim_dir
	}

	tar -cvf - vim | tar -xvf - -C $HOME && mv $HOME/vim $HOME/.vim

}


##### INSTALL BEGIN####
DISTRO_ID=$(cat /etc/lsb-release  | grep DISTRIB_ID | awk -F= '{print $NF}')
DISTRO_RELEASE=$(cat /etc/lsb-release  | grep DISTRIB_RELEASE | awk -F= '{print $NF}')

case "${DISTRO_ID}-${DISTRO_RELEASE}" in
    Ubuntu-21.04|Ubuntu-20.04|Ubuntu-20.10|Ubuntu-18.04|Ubuntu-16.04)
	    DISTRO_SUPPORT="${DISTRO_ID}-${DISTRO_RELEASE}"
	;;
    *)
	    DISTRO_SUPPORT=""
	;;
esac

if [ -z "${DISTRO_SUPPORT}" ]; then
	echo "${DISTRO_ID}-${DISTRO_RELEASE} is not be supported, exit ..."
	exit
fi

install_utilities $DISTRO_SUPPORT
configure_bashrc
configure_vim $DISTRO_SUPPORT
configure_gitconfig

##### INSTALL END####

