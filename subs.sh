#!/bin/bash

# v0.3

####################PARAMETERS####################
# SSR订阅链接
SUBSLINK="https://subs.aaabbbccc.net/link/xxx?yyy=0"	
# YAML模板文件
CFG_TEMPLATE="template.yaml"
# 输出文件的名称
CFG_FLIE="config.yaml"					
# curl的代理，格式为"[http://]<host>:<port>"或"socks5://<host>:<port>"，不用的话清除引号内的内容，或者用#注释该行
#PROXY_CURL='192.168.1.1:1080'
# curl的重试次数
TRYS_CURL=5
# 临时文件
TEMPFILE="/tmp/clashdata"
# CLASH的规则集
rulelist=(
'https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/BanProgramAD.list' '☢ 广告拦截'
#'https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/BanEasyListChina.list' '☢ 广告拦截'
'https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/ProxyGFWlist.list' '☯ 策略选择'
#'https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/ChinaCompanyIp.list' 'DIRECT'
#'https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/ChinaDomain.list' 'DIRECT'
#'https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/LocalAreaNetwork.list' 'DIRECT'
)

####################FUNCTION####################
# base64解码
function urlsafe_b64decode() {
	local a b
	if [ -z "$1" ]
	then
		return 1
	fi

	a="$1"
	case $((${#a}%4)) in
	1) a+="===";;
	2) a+="==";;
	3) a+="=";;
	*) :;;
	esac

	if ! b=$(echo "$a" | sed 'y/-_/+\//' | base64 -d)
	then
		echo "error : base64 failed to decode data."  >& 2
		return 2
	fi

	echo "$b"
	return 0
}

# 解码节点
function extractSSRnode() {
	local b server port protocol cipher obfs password remarks obfsparam protoparam group node
	
	if ! grep -P '^\s*ssr://' <<< "$1" &> /dev/null
	then
		echo "error: suffix 'ssr://' is not found." >& 2
		return 1
	fi

	if ! b=$(urlsafe_b64decode "${1#*"ssr://"}")
	then
		echo "error: failed to decode node data." >& 2
		return 2
	fi
	
	# 获取必备字段
	if  ! server=$(awk 'BEGIN{FS=":"} {print $1}' <<< "$b") || \
	! port=$(awk 'BEGIN{FS=":"} {print $2}' <<< "$b") || \
	! protocol=$(awk 'BEGIN{FS=":"} {print $3}' <<< "$b") || \
	! cipher=$(awk 'BEGIN{FS=":"} {print $4}' <<< "$b") || \
	! obfs=$(awk 'BEGIN{FS=":"} {print $5}' <<< "$b")
	then
		echo "error: failed to extract parameters." >& 2
		return 3
	fi

	password=$(urlsafe_b64decode $(grep -oP '(?<=:)[^:/?]+(?=/)' <<< "$b")) 
	remarks=$(urlsafe_b64decode $(grep -oP '(?<=remarks=)[^:/?=&]+' <<< "$b")) 
	obfsparam=$(urlsafe_b64decode $(grep -oP '(?<=obfsparam=)[^:/?=&]+' <<< "$b"))
	protoparam=$(urlsafe_b64decode $(grep -oP '(?<=protoparam=)[^:/?=&]+' <<< "$b"))
	#group=$(urlsafe_b64decode $(grep -oP '(?<=group=)[^:/?=&]+' <<< "$b"))

	echo "{name: ${remarks:-server-$(date +%s)}, server: ${server:-\"\"}, port: ${port:-\"\"}, type: ssr, cipher: ${cipher:-\"\"}, password: ${password:-\"\"}, protocol: ${protocol:-\"\"}, obfs: ${obfs:-\"\"}, protocol-param: ${protoparam:-\"\"}, obfs-param: ${obfsparam:-\"\"}}"
	return 0

}

# 从订阅链接提取数据并转换为CLASH节点格式
function extractSSRsubslink() {
	if [ -z "$SUBSLINK" ]
	then
		echo "error: subscription link shouldn't be null." >& 2
		return 1
	fi

	local subsdata begin nd end li num
	if ! subsdata=$(curl -# ${PROXY_CURL:+-x $PROXY_CURL} --retry-all-errors --retry "$TRYS_CURL" --fail "$SUBSLINK")
	then
		echo "error: failed to fetch data from SSR subscription link." >& 2
		return 2
	fi

	if ! subsdata=$(urlsafe_b64decode "$subsdata")
	then
		echo "error: failed to decode subscription data." >& 2
		return 3
	fi

	echo "info: start to decode all nodes." >& 2
	begin=$(date +%s)
	nd=$(while read li
	do
		extractSSRnode "$li" &
	done <<< "$subsdata"
	echo "{name: 更新时间：$(date "+%Y-%m-%d %H:%M:%S"), server: www.mimemi.org, port: 2, type: ssr, cipher: xchacha20, password: breakwall, protocol: auth_chain_a, obfs: tls1.2_ticket_auth, protocol-param: \"\", obfs-param: \"\"}")
	wait
	end=$(date +%s)
	echo "info: decoding complete. consumed time: $(expr $end - $begin)s" >& 2
	num=$(wc -l <<< "$nd")
	echo "info: total nodes: $num" >& 2
	
	if [[ "$num" < 2 ]]
	then
		echo "error: insufficient valid nodes." >& 2
		return 4
	fi

	echo "$nd"
	return 0
}

# 输入：$1=模板, $2=数据, $3=插入位置标记
# 输出：插入数据后的模板
function insertData()
{
	local t
	
	if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]
	then
		echo "error: invaild input data." >& 2
		return 1
	fi
	
	if ! cat > "$TEMPFILE" <<< "$2" 
	then
		echo "error: failed to save data to temp file." >& 2
		rm -f "$TEMPFILE"
		return 2
	fi
	
	if ! t=$(echo "$1" | sed '/'"$3"'/e\'"cat $TEMPFILE")
	then
		echo "error: failed to insert data." >& 2
		rm -f "$TEMPFILE"
		return 3
	fi
	
	echo "$t"
	rm -f "$TEMPFILE"
	return 0
}

# 输入：$1=模板，$2=节点
# 输出：配置文件内容
function insertNodes() {
	local tp nodeAll nodeNormal nodeInfo nodeInland nodenameInland nodenameInfo
	if [ -z "$1" ] || [ -z "$2" ]
	then
		echo "error: invalid input data" >& 2
		return 1
	fi

	# 获取并过滤节点
	tp="$1"
	nodeAll=$(sed -n '/^{/p' <<< "$2")

	# 修正chacha20错误
	if ! nodeAll=$(sed 's/cipher: chacha20/cipher: xchacha20/g' <<< "$nodeAll")
	then
		echo "error: failed to correct chacha20 problem." >& 2
		return 2
	fi

	# 分类节点
	if ! nodeNormal=$(grep -vP '(回国)|(时间)|(剩余流量)' <<< "$nodeAll")
	then
		echo "error: insufficient valid nodes." >& 2
		return 3
	fi
	nodeInfo=$(grep -P '(时间)|(剩余流量)' <<< "$nodeAll")
	nodeInland=$(grep -P '回国' <<< "$nodeAll")

	# 插入节点，失败退出
	if ! tp=$(insertData "$tp" "$(sed 's/^/  - /; ' <<< "$nodeAll")" "^\s*# nodes data up here")
	then
		echo "error: can't insert nodes to template." >& 2
		return 4
	fi

	# 插入节点名，失败退出
	if ! tp=$(insertData "$tp" "$(grep -oP '(?<=name: )[^,]+?(?=,)' <<< "$nodeNormal" | sed 's/^/      - /; ')" "^\s*# nodes name up here")
	then
		echo "error: can't insert nodes' names to template." >& 2
		return 5
	fi

	# 插入回国节点名，失败退出
	if [[ -z "$nodeInland" ]]
	then
		echo "info: no inland nodes" >& 2
		nodenameInland='DIRECT'
	else
		echo "info: add inland nodes" >& 2
		nodenameInland=$(grep -oP '(?<=name: )[^,]+?(?=,)' <<< "$nodeInland")
	fi
	if ! tp=$(insertData "$tp" "$(sed 's/^/      - /; ' <<< "$nodenameInland")" "^\s*# inland nodes name up here")
	then
		echo "error: can't insert inland nodes' names to template." >& 2
		return 6
	fi

	# 插入信息展示，失败退出
	if [[ -z "$nodeInfo" ]]
	then
		echo "info: no info nodes" >& 2
		nodenameInfo='DIRECT'
	else
		echo "info: add info nodes" >& 2
		nodenameInfo=$(grep -oP '(?<=name: )[^,]+?(?=,)' <<< "$nodeInfo")
	fi
	if ! tp=$(insertData "$tp" "$(sed 's/^/      - /; ' <<< "$nodenameInfo")" "^\s*# info nodes name up here")
	then
		echo "error: can't insert info nodes' names to template." >& 2
		return 7
	fi

	echo "$tp"
	return 0
}

# 输入：$1=配置文件内容
# 输出：插入规则后的配置文件内容
# 返回值：成功插入的规则数目
function insertRules() {
	[ -z "$1" ] && return 0
	local num i ruledataRaw ruledataMod tp tp2 retval
	retval=0
	tp="$1"
	num="${#rulelist[@]}"
	if (( num%2 )) 
	then
		echo "error: the array's length should be even." >& 2
		return 0
	fi

	for (( i=0; i<num; i+=2 ))
	do
		if ruledataRaw=$(curl -# ${PROXY_CURL:+-x $PROXY_CURL} --retry-all-errors --retry "$TRYS_CURL" --fail ${rulelist[i]})
		then
			echo "info: rule[$((i/2))](${rulelist[i+1]}) downloaded successfully." >& 2
			#echo "$ruledataRaw" > ad.txt
			if ruledataMod=$(sed '/^$/d; s/^\s*//g; /^[^#]/{/no-resolve$/s/no-resolve/'"${rulelist[i+1]}"',&/; /no-resolve$/!s/$/,'"${rulelist[i+1]}"'/}; /^#/!s/^/  - /; /^#/s/^/  /' <<< "$ruledataRaw") && [ -n "$ruledataMod" ]
			then
				echo "info: start to insert rule[$((i/2))](${rulelist[i+1]})." >& 2
				if tp2=$(insertData "$tp" "$ruledataMod" "^\s*# rules up here") && [ -n "$tp2" ]
				then
					echo "info: rule[$((i/2))](${rulelist[i+1]}) added to config successfully." >& 2
					tp="$tp2"
					tp2=''
					(( retval++ ))
					continue
				fi
			fi
		fi
		echo "warning: can't insert rule[$((i/2))](${rulelist[i+1]})." >& 2
	done
	(( $retval )) && echo "$tp"
	return "$retval"
}

####################PROGRAM START####################
# 进入脚本所在目录
cd $(dirname "$0")

# 订阅数据解析
if ! nodedata=$(extractSSRsubslink)
then
	echo "error: failed to get nodes." >& 2
	exit 1
fi

# 加载配置模板文件
if ! [[ -f "$CFG_TEMPLATE" ]] || ! tempdata=$(cat "$CFG_TEMPLATE")
then
	echo "error: failed to load template of configure file." >& 2
	exit 2
fi

# 向模板中加入节点
if ! ndtp=$(insertNodes "$tempdata" "$nodedata")
then
	echo "error: failed to insert nodes to template." >& 2
	exit 3
fi

# 向模板中加入规则
if ndtp2=$(insertRules "$ndtp")
then
	echo "warning: no rule added." >& 2
	ndtp2="$ndtp"
else
	echo "info: added $? rules successfully." >& 2
fi

# 保存配置文件
if ! cat > "$CFG_FLIE" <<< "$ndtp2"
then
	echo "error: failed to save configuration file." >& 2
else
	echo "info: saved to "$CFG_FLIE" successfully." >& 2
fi


echo "All tasks completed." >& 2
exit 0
