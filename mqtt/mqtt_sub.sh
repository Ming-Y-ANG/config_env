#!/bin/bash
#set -x

# 获取参数数量
num_args=$#

usage() {
    echo "bad args, Usage: $0 <server> <port> {local|3rd} {cert|psk|none} {summary|obd|gnss|motion|io|cellular|userdata|1-wire|forward|all}"
    exit 1
}
# 检查是否有参数传入
if [ $num_args -lt 5 ]; then
	usage
fi

server=$1
port=$2
mode=$3
auth=$4

if [ $mode == 'local' ]; then
	echo "local broker sub..."
elif [ $mode == '3rd' ]; then
	echo "3rd broker sub..."
else
	usage
fi

if [ $auth == 'cert' ]; then
	ca="$(pwd)/certs/ca.crt"
	echo "user cert auth(ca:$ca)..."
	if [ ! -e $ca ]; then
	  echo "$ca not exist, please check it!"
	  exit 1
	fi
	cafile='--cafile $ca --insecure'
	#certfile="/path/to/client.crt"
	#keyfile="/path/to/client.key"
elif [ $auth == 'psk' ]; then
	psk="123456"
	ident="test"
	echo "use psk auth(psk:$psk, psk-identity:$ident)..."
	psk='--psk $psk --psk-identity $idnet'
elif [ $auth != 'none' ]; then
	usage
fi

# shift $@ $1 $2 ... -> $5 $6 ...
shift 4

for arg in "$@"; do
    #echo "Parameter $counter: $arg"
	case ${arg} in
		summary) 
			[ $mode == 'local' ] && topic+='-t v1/summary/info ' || topic+='-t v1/+/summary/info '
			;;
		obd) 
			[ $mode == 'local' ] && topic+='-t v1/obd/info ' || topic+='-t v1/+/obd/info '
			;;
		gnss) 
			[ $mode == 'local' ] && topic+='-t v1/gnss/info ' || topic+='-t v1/+/gnss/info '
			;;
		motion) 
			[ $mode == 'local' ] && topic+='-t v1/motion/info ' || topic+='-t v1/+/motion/info '
			;;
		io) 
			[ $mode == 'local' ] && topic+='-t v1/io/info ' || topic+='-t v1/+/io/info '
			;;
		cellular1) 
			[ $mode == 'local' ] && topic+='-t v1/cellular1/info ' || topic+='-t v1/+/cellular1/info '
			;;
		userdata) 
			[ $mode == 'local' ] && topic+='-t v1/userdata/info ' || topic+='-t v1/+/userdata/info '
			;;
		1-wire) 
			[ $mode == 'local' ] && topic+='-t v1/1-wire/info ' || topic+='-t v1/+/1-wire/info '
			;;
		forward) 
			[ $mode == 'local' ] && topic+='-t v1/forward/info ' || topic+='-t v1/+/forward/info '
			;;
		all) 
			[ $mode == 'local' ] && {
				topic+='-t v1/summary/info '
				topic+='-t v1/obd/info '
				topic+='-t v1/gnss/info '
				topic+='-t v1/motion/info '
				topic+='-t v1/io/info '
				topic+='-t v1/cellular1/info '
				topic+='-t v1/userdata/info '
				topic+='-t v1/1-wire/info '
				topic+='-t v1/forward/info '
			} || {
				topic+='-t v1/+/summary/info '
				topic+='-t v1/+/obd/info '
				topic+='-t v1/+/gnss/info '
				topic+='-t v1/+/motion/info '
				topic+='-t v1/+/io/info '
				topic+='-t v1/+/cellular1/info '
				topic+='-t v1/+/userdata/info '
				topic+='-t v1/+/1-wire/info '
				topic+='-t v1/+/forward/info '
			}
			;;
		*) 
			usage
			;;
	esac
done

#mosquitto_sub -h "$server" -p "$port" --cafile "$cafile" --cert "$certfile" --key "$keyfile" -t "$topic"
echo "sub topics: $topic"
mosquitto_sub -h "$server" -p "$port" $cafile $psk $topic | jq . 

