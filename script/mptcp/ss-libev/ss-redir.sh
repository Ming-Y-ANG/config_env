#!/bin/sh

MyIP="38.55.199.15"
MyPort="65101"
MyMethod="chacha20-ietf-poly1305"
MyPasswd="p7sskZNvUn8hiT0D3FVIZeEKF4nmebF0WAThBTsIiN4="
HTTP_PORT="65500"
UDP_REDIR="0"

start_ssredir() {
	if [ "$UDP_REDIR" = "1" ]; then   
		ss-redir -s $MyIP -p $MyPort -m $MyMethod --key $MyPasswd -b 127.0.0.1 -l 60080 --no-delay --mptcp -u -T -v > /var/log/ss-redir.log 2&>1 &
	else
		ss-redir -s $MyIP -p $MyPort -m $MyMethod --key $MyPasswd -b 127.0.0.1 -l 60080 --no-delay --mptcp -T -v > /var/log/ss-redir.log 2&>1 &
	fi
}

stop_ssredir() {
    kill -9 $(pidof ss-redir) &>/dev/null
}

start_iptables() {
    ##################### SSREDIR #####################
    iptables -t mangle -N SSREDIR

    # connection-mark -> packet-mark
    iptables -t mangle -A SSREDIR -j CONNMARK --restore-mark
    iptables -t mangle -A SSREDIR -m mark --mark 0x2333 -j RETURN

    # please modify MyIP, MyPort, etc.
    # ignore traffic sent to ss-server
    iptables -t mangle -A SSREDIR -p tcp -d $MyIP --dport $MyPort -j RETURN
	if [ "$UDP_REDIR" = "1" ]; then   
		iptables -t mangle -A SSREDIR -p udp -d $MyIP --dport $MyPort -j RETURN
	fi

    # ignore traffic sent to reserved addresses
    iptables -t mangle -A SSREDIR -d 0.0.0.0/8          -j RETURN
    iptables -t mangle -A SSREDIR -d 10.0.0.0/8         -j RETURN
    iptables -t mangle -A SSREDIR -d 100.64.0.0/10      -j RETURN
    iptables -t mangle -A SSREDIR -d 127.0.0.0/8        -j RETURN
    iptables -t mangle -A SSREDIR -d 169.254.0.0/16     -j RETURN
    iptables -t mangle -A SSREDIR -d 172.16.0.0/12      -j RETURN
    iptables -t mangle -A SSREDIR -d 192.0.0.0/24       -j RETURN
    iptables -t mangle -A SSREDIR -d 192.0.2.0/24       -j RETURN
    iptables -t mangle -A SSREDIR -d 192.88.99.0/24     -j RETURN
    iptables -t mangle -A SSREDIR -d 192.168.0.0/16     -j RETURN
    iptables -t mangle -A SSREDIR -d 198.18.0.0/15      -j RETURN
    iptables -t mangle -A SSREDIR -d 198.51.100.0/24    -j RETURN
    iptables -t mangle -A SSREDIR -d 203.0.113.0/24     -j RETURN
    iptables -t mangle -A SSREDIR -d 224.0.0.0/4        -j RETURN
    iptables -t mangle -A SSREDIR -d 240.0.0.0/4        -j RETURN
    iptables -t mangle -A SSREDIR -d 255.255.255.255/32 -j RETURN

    # mark the first packet of the connection
    iptables -t mangle -A SSREDIR -p tcp --syn                      -j MARK --set-mark 0x2333
	if [ "$UDP_REDIR" = "1" ]; then   
		iptables -t mangle -A SSREDIR -p udp -m conntrack --ctstate NEW -j MARK --set-mark 0x2333
	fi

    # packet-mark -> connection-mark
    iptables -t mangle -A SSREDIR -j CONNMARK --save-mark

    ##################### OUTPUT #####################
    # proxy the outgoing traffic from this machine
    iptables -t mangle -A OUTPUT -p tcp -m addrtype --src-type LOCAL ! --dst-type LOCAL -j SSREDIR
	if [ "$UDP_REDIR" = "1" ]; then   
		iptables -t mangle -A OUTPUT -p udp -m addrtype --src-type LOCAL ! --dst-type LOCAL -j SSREDIR
	fi

    ##################### PREROUTING #####################
    # proxy traffic passing through this machine (other->other)
    iptables -t mangle -A PREROUTING -p tcp -m addrtype ! --src-type LOCAL ! --dst-type LOCAL -j SSREDIR
	if [ "$UDP_REDIR" = "1" ]; then   
		iptables -t mangle -A PREROUTING -p udp -m addrtype ! --src-type LOCAL ! --dst-type LOCAL -j SSREDIR
	fi

    # hand over the marked package to TPROXY for processing
    iptables -t mangle -A PREROUTING -p tcp -m mark --mark 0x2333 -j TPROXY --on-ip 127.0.0.1 --on-port 60080
	if [ "$UDP_REDIR" = "1" ]; then   
		iptables -t mangle -A PREROUTING -p udp -m mark --mark 0x2333 -j TPROXY --on-ip 127.0.0.1 --on-port 60080
	fi
}

stop_iptables() {
    ##################### PREROUTING #####################
    iptables -t mangle -D PREROUTING -p tcp -m mark --mark 0x2333 -j TPROXY --on-ip 127.0.0.1 --on-port 60080 &>/dev/null
	if [ "$UDP_REDIR" = "1" ]; then   
		iptables -t mangle -D PREROUTING -p udp -m mark --mark 0x2333 -j TPROXY --on-ip 127.0.0.1 --on-port 60080 &>/dev/null
	fi

    iptables -t mangle -D PREROUTING -p tcp -m addrtype ! --src-type LOCAL ! --dst-type LOCAL -j SSREDIR &>/dev/null
	if [ "$UDP_REDIR" = "1" ]; then   
		iptables -t mangle -D PREROUTING -p udp -m addrtype ! --src-type LOCAL ! --dst-type LOCAL -j SSREDIR &>/dev/null
	fi

    ##################### OUTPUT #####################
    iptables -t mangle -D OUTPUT -p tcp -m addrtype --src-type LOCAL ! --dst-type LOCAL -j SSREDIR &>/dev/null
	if [ "$UDP_REDIR" = "1" ]; then   
		iptables -t mangle -D OUTPUT -p udp -m addrtype --src-type LOCAL ! --dst-type LOCAL -j SSREDIR &>/dev/null
	fi

    ##################### SSREDIR #####################
    iptables -t mangle -F SSREDIR &>/dev/null
    iptables -t mangle -X SSREDIR &>/dev/null
}

start_iproute2() {
    ip route add local default dev lo table 100
    ip rule  add fwmark 0x2333        table 100
}

stop_iproute2() {
    ip rule  del   table 100 &>/dev/null
    ip route flush table 100 &>/dev/null
}

start_resolvconf() {
    # or nameserver 8.8.8.8, etc.
    #echo "nameserver 1.1.1.1" >/etc/resolv.conf
	return 0
}

stop_resolvconf() {
    #echo "nameserver 114.114.114.114" >/etc/resolv.conf
	return 0
}

start() {
    echo "start ..."
    start_ssredir
    start_iptables
    start_iproute2
    start_resolvconf
    echo "start end"
}

stop() {
    echo "stop ..."
    stop_resolvconf
    stop_iproute2
    stop_iptables
    stop_ssredir
    echo "stop end"
}

restart() {
    stop
    sleep 1
    start
}

login_vps() {
	auth=`curl --max-time 10 -k -H 'accept: application/json' -H 'Content-Type: application/x-www-form-urlencoded' -X POST -d 'username=openmptcprouter&password=DD07C496E62C111D4A9C41FE9746D89D77963182DA61A9E9DD5DF8E892A30EFD' https://$MyIP:$HTTP_PORT/token`
	[ -z "$auth" ] && {
		echo "login vps failed"
		exit 0
	}
	token="$(echo "$auth" | jsonfilter -q -e '@.access_token')"
	[ -z "$token" ] && {
		echo "get token failed"
		exit 0
	}

	echo "token is $token"
	sleep 1

	port=$MyPort
	method=$MyMethod
	fast_open="false"
	no_delay="false"
	mptcp="true"
	key=$MyPasswd
	ebpf="false"
	obfs="false"
	obfs_plugin="v2ray"
	obfs_type="http"
	settings='{"port": '$port', "method":"'$method'", "fast_open":'$fast_open', "reuse_port":true, "no_delay":'$no_delay', "mptcp":'$mptcp', "key":"'$key'", "ebpf":'$ebpf', "obfs":'$obfs', "obfs_plugin":"'$obfs_plugin'", "obfs_type":"'$obfs_type'" }'
	echo "setting: $settings"
	route="shadowsocks"
	result=`curl --max-time 10 -k -H "Authorization: Bearer $token" -H "Content-Type: application/json" -X POST -d "$settings" https://$MyIP:$HTTP_PORT/$route`
	echo "result: $result"
}

main() {
    if [ $# -eq 0 ]; then
        echo "usage: $0 start|stop|restart ..."
        exit 0
    fi

	case $1 in
		start)
			#login_vps
			start
			;;
		stop)
			stop
			;;
		restart)
			restart
			;;
		*)
			echo "$1 not suooprt"
			;;
	esac
}
main "$@"
