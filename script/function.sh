#!/bin/sh

sudo_wrapper(){
	echo $DEF_PASSWD | sudo -S -k $@
}

