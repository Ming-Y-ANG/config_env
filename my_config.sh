#!/bin/bash
set -exo pipefail

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
	command -v $1 >/dev/null 2>&1; 
}

version_lt() {
	test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" != "$1";
}

version_gt() {
	test "$(echo "$@" | tr " " "\n" | sort -V | head -n 1)" != "$1"; 
}

version_le() {
	test "$(echo "$@" | tr " " "\n" | sort -V | head -n 1)" == "$1"; 
}

version_ge() {
	test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" == "$1"; 
}

npm_update() {
	local REQ_VER='9.5.1'
	local CUR_VER=$(npm -v)

	if version_lt $CUR_VER $REQ_VER; then 
       echo "===== $CUR_VER is less than $REQ_VER ====="
	   sudo_wrapper npm install -g npm@$REQ_VER
	fi
}

install_nodejs(){
	local VERSION=v16.18.0
	local update=0
	if !(program_exists node) then
		update=1
		echo "nodejs not exist, upgrade it now!"
	elif version_lt $(node -v) $VERSION; then
		update=1
		echo "nodejs too old, upgrade it now!"
	fi

	if [ $update -eq '1' ]; then
		PACK=node-$VERSION-linux-x64.tar.gz
		URL="https://nodejs.org/dist/$VERSION/$PACK"
		PREFIX=/usr/local
		wget "${URL}" 
		tar xzfv $PACK\
			--exclude CHANGELOG.md \
			--exclude LICENSE \
			--exclude README.md \
			--strip-components 1 \
			-C "${PREFIX}"
		rm -rf $PACK
	fi
}

install_utilities(){

	local distro_support=$1
	local update=0

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
	sudo_wrapper apt install build-essential software-properties-common unzip -y --no-install-recommends
	sudo_wrapper apt install wget curl git tig expect bear autoconf proxychains universal-ctags -y --no-install-recommends

	case "$DISTRO_SUPPORT" in
		#Install tmux vim
		Ubuntu-16.04|Ubuntu-18.04)
		if !(program_exists tmux) then 
			   update=1
			   sudo_wrapper add-apt-repository ppa:bundt/backports -y
			   case "$DISTRO_SUPPORT" in
				   Ubuntu-16.04)
			          TMUX_PACK='tmux=3.1c-ppa-xenial1'
			       ;;
			       *)
			          TMUX_PACK='tmux=3.1c-1ppa~bionic1'
			       ;;
	               esac
		fi

		if !(program_exists vim) then
			   update=1
			   sudo_wrapper add-apt-repository ppa:jonathonf/vim -y
			   case "$DISTRO_SUPPORT" in
				   Ubuntu-16.04)
					  VIM_PACK='vim=2:8.2.3458-0york0~16.04'
			       ;;
			       *)
					  VIM_PACK='vim=2:9.0.0749-0york0~18.04'
			       ;;
	               esac
		fi

		    if [ $update -eq '1' ]; then
				sudo_wrapper apt update
				sudo_wrapper apt install $TMUX_PACK $VIM_PACK -y
			fi
	    ;;
		*)
			sudo_wrapper apt install tmux vim -y --no-install-recommends
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
	echo "alias g='grep -nr --color=auto'" >> bashrc
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
	username=${username:-yangming}

	#read -p "user email for git" -t 5 useremail
	useremail=${useremail:-yangming@inhand.com.cn}

	git config --global user.name $username
	git config --global user.email $useremail
	git config --global core.editor vim
	git config --global merge.tool vimdiff
	git config --global alias.co checkout
	git config --global alias.br branch
	git config --global alias.ci commit
	git config --global alias.st status
	git config --global alias.rb rebase
	git config --global alias.cp cherry-pick
	git config --global alias.lm "log --no-merges --color --date=format:'%Y-%m-%d %H:%M' --author='$username' --pretty=format:'%Cgreen%cd %C(bold blue)%<(10)%an%Creset %Cred%h%Creset -%C(yellow)%d%Cblue %s%Creset' --abbrev-commit"
	git config --global alias.lms "log --no-merges --color --stat --date=format:'%Y-%m-%d %H:%M' --author='$username' --pretty=format:'%Cgreen%cd %C(bold blue)%<(10)%an%Creset %Cred%h%Creset -%C(yellow)%d%Cblue %s%Creset' --abbrev-commit"
	git config --global alias.ls "log --no-merges --color --date=format:'%Y-%m-%d %H:%M' --pretty=format:'%Cgreen%cd %C(bold blue)%<(10)%an%Creset %Cred%h%Creset -%C(yellow)%d%Cblue %s%Creset' --abbrev-commit"
	git config --global alias.lss "log --no-merges --color --stat --date=format:'%Y-%m-%d %H:%M' --pretty=format:'%Cgreen%cd %C(bold blue)%<(10)%an%Creset %Cred%h%Creset -%C(yellow)%d%Cblue %s%Creset' --abbrev-commit"
	git config --global push.default simple
	git config --global credential.helper store
}

configure_vim(){

	local distro_support=$1

	[ -z "$distro_support" ] && {
		echo "use 'configure_vim DISTRO_SUPPORT'"
		return
	}

	#configure vim
	echo "Configure VIM ..."
	install_nodejs
	npm_update
	if !(program_exists bash-language-server) then
		echo "install bash lsp"
		sudo_wrapper npm i -g bash-language-server
	fi

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
    Ubuntu-22.04|Ubuntu-21.04|Ubuntu-20.04|Ubuntu-20.10|Ubuntu-18.04|Ubuntu-16.04)
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

