#!/bin/bash

# 颜色输出函数
print_info() {
    echo -e "\033[32m[INFO] $1\033[0m"
}

print_error() {
    echo -e "\033[31m[ERROR] $1\033[0m"
}

print_warning() {
    echo -e "\033[33m[WARNING] $1\033[0m"
}

# 检查操作系统类型
check_os() {
    if [ -f /etc/redhat-release ]; then
        OS_TYPE="rhel"
        # 检查是否是 CentOS Stream
        if grep -q "CentOS Stream" /etc/redhat-release; then
            OS_VERSION="stream"
        else
            OS_VERSION=$(cat /etc/redhat-release | grep -oE '[0-9]+\.[0-9]+' | cut -d. -f1)
        fi
    elif [ -f /etc/debian_version ]; then
        OS_TYPE="debian"
        OS_VERSION=$(cat /etc/debian_version | cut -d. -f1)
    else
        print_error "不支持的操作系统"
        exit 1
    fi
}

# 检查基础工具
check_base_tools() {
    print_info "检查基础工具..."
    
    # 检查必需的命令
    local required_tools="wget curl tar"
    local missing_tools=""
    
    for tool in $required_tools; do
        if ! command -v $tool &>/dev/null; then
            missing_tools="$missing_tools $tool"
        fi
    done
    
    if [ -n "$missing_tools" ]; then
        print_warning "缺少必要的工具:$missing_tools"
        print_info "开始安装基础工具..."
        
        # 检查基础工具安装脚本是否存在
        local base_tools_script="$(dirname $0)/install_base_tools.sh"
        if [ ! -f "$base_tools_script" ]; then
            print_error "找不到基础工具安装脚本: $base_tools_script"
            exit 1
        fi
        
        bash "$base_tools_script"
        if [ $? -ne 0 ]; then
            print_error "基础工具安装失败"
            exit 1
        fi
        
        print_info "基础工具安装完成"
    else
        print_info "基础工具检查通过"
    fi
}

# 检查 Java 环境
check_java_env() {
    print_info "检查 Java 环境..."
    
    if ! command -v java &>/dev/null; then
        print_warning "未检测到 Java 环境，开始安装 Java..."
        
        local java_script="$(dirname $0)/install_java.sh"
        if [ ! -f "$java_script" ]; then
            print_error "找不到 Java 安装脚本: $java_script"
            exit 1
        fi
        
        bash "$java_script"
        if [ $? -ne 0 ]; then
            print_error "Java 安装失败"
            exit 1
        fi
        
        source /etc/profile
    fi
    
    local java_version=$(java -version 2>&1 | grep -i version | cut -d'"' -f2)
    print_info "检测到 Java 版本: $java_version"
    
    if [ -z "$JAVA_HOME" ]; then
        if [ -f "/etc/profile.d/java.sh" ]; then
            source "/etc/profile.d/java.sh"
        else
            print_error "JAVA_HOME 环境变量未设置"
            exit 1
        fi
    fi
    
    print_info "Java 环境检查通过"
}

# 获取 ZooKeeper 可用版本
get_zookeeper_versions() {
    # 尝试从 Apache 镜像站点获取版本列表
    local online_versions=$(curl -s https://archive.apache.org/dist/zookeeper/ | \
        grep -o 'zookeeper-[0-9]\.[0-9]\.[0-9]/' | \
        grep -o '[0-9]\.[0-9]\.[0-9]' | \
        grep -v "alpha\|beta\|rc" | \
        sort -rV | head -n 10 | \
        sort -V)
    
    if [ -z "$online_versions" ]; then
        # 如果无法获取在线版本，则提供固定版本列表
        return 1
    else
        echo "$online_versions"
        return 0
    fi
}

# 选择 ZooKeeper 版本
select_zookeeper_version() {
    print_info "获取 ZooKeeper 最新稳定版本列表..."
    
    # 使用临时文件存储版本列表
    local temp_file="/tmp/zookeeper_versions.tmp"
    if ! get_zookeeper_versions > "$temp_file"; then
        print_warning "无法获取在线版本列表，使用固定版本列表"
        cat > "$temp_file" << EOF
3.7.1
3.8.0
3.8.1
3.9.0
3.9.1
EOF
    fi
    
    # 读取版本到数组
    local versions=()
    while IFS= read -r version; do
        versions+=("$version")
    done < "$temp_file"
    rm -f "$temp_file"
    
    echo -e "\n可用的 ZooKeeper 版本:"
    local i=1
    for version in "${versions[@]}"; do
        echo "$i) $version"
        ((i++))
    done
    
    echo
    read -p "请选择版本号（1-${#versions[@]}），直接回车将安装最新版 ${versions[-1]}: " choice
    
    if [ -z "$choice" ]; then
        ZK_VERSION=${versions[-1]}
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#versions[@]}" ]; then
        ZK_VERSION=${versions[$((choice-1))]}
    else
        print_error "无效的选择，将使用最新版 ${versions[-1]}"
        ZK_VERSION=${versions[-1]}
    fi
    
    print_info "选择的 ZooKeeper 版本: $ZK_VERSION"
}

# 创建 ZooKeeper 用户
create_zookeeper_user() {
    print_info "创建 zookeeper 用户..."
    if ! id "zookeeper" &>/dev/null; then
        useradd -r -s /sbin/nologin zookeeper
    fi
}

# 安装 ZooKeeper
install_zookeeper() {
    print_info "开始下载 ZooKeeper..."
    local zk_tar="apache-zookeeper-${ZK_VERSION}-bin.tar.gz"
    
    # 修改下载链接使用镜像站点
    local download_url="https://archive.apache.org/dist/zookeeper/zookeeper-${ZK_VERSION}/${zk_tar}"
    
    cd /tmp
    if [ ! -f "${zk_tar}" ]; then
        wget "${download_url}"
        if [ $? -ne 0 ]; then
            print_error "ZooKeeper 下载失败，尝试使用备用下载地址..."
            # 备用下载地址
            download_url="https://downloads.apache.org/zookeeper/zookeeper-${ZK_VERSION}/${zk_tar}"
            wget "${download_url}"
            if [ $? -ne 0 ]; then
                print_error "ZooKeeper 下载失败"
                exit 1
            fi
        fi
    fi
    
    print_info "解压并安装 ZooKeeper..."
    tar -xzf "${zk_tar}"
    rm -rf /opt/zookeeper
    mv "apache-zookeeper-${ZK_VERSION}-bin" /opt/zookeeper
    
    # 创建数据和日志目录
    mkdir -p /data/zookeeper/data /data/zookeeper/logs
    
    # 设置权限
    chown -R zookeeper:zookeeper /opt/zookeeper /data/zookeeper
    chmod -R 755 /opt/zookeeper /data/zookeeper
}

# 新增单节点配置函数
configure_standalone() {
    print_info "配置 ZooKeeper 单节点模式..."
    
    # 创建 myid 文件
    echo "1" > /data/zookeeper/data/myid
    chown zookeeper:zookeeper /data/zookeeper/data/myid
    
    # 修改配置文件
    cat > /opt/zookeeper/conf/zoo.cfg << EOF
# 基本配置
tickTime=2000
initLimit=10
syncLimit=5
dataDir=/data/zookeeper/data
dataLogDir=/data/zookeeper/logs
clientPort=2181

# 自动清理快照和事务日志
autopurge.snapRetainCount=3
autopurge.purgeInterval=1

# 最大客户端连接数
maxClientCnxns=60
EOF
    
    chown zookeeper:zookeeper /opt/zookeeper/conf/zoo.cfg
    print_info "单节点配置完成"
}

# 新增集群配置函数
configure_cluster() {
    print_info "配置 ZooKeeper 集群..."
    
    # 获取集群节点信息
    echo -e "\n请输入集群节点信息（最少3个节点）"
    local nodes=()
    local myid=""
    local i=1
    
    while true; do
        read -p "请输入节点 $i 的IP地址（直接回车结束输入）: " node_ip
        if [ -z "$node_ip" ]; then
            break
        fi
        
        # 检查是否为当前节点
        if ip addr | grep -q "$node_ip"; then
            myid=$i
        fi
        
        nodes+=("$node_ip")
        ((i++))
    done
    
    # 检查节点数量
    if [ ${#nodes[@]} -lt 3 ]; then
        print_error "节点数量不能少于3个"
        exit 1
    fi
    
    if [ -z "$myid" ]; then
        read -p "请输入当前节点的ID（1-${#nodes[@]}）: " myid
        if ! [[ "$myid" =~ ^[0-9]+$ ]] || [ "$myid" -lt 1 ] || [ "$myid" -gt "${#nodes[@]}" ]; then
            print_error "无效的节点ID"
            exit 1
        fi
    fi
    
    # 创建 myid 文件
    echo "$myid" > /data/zookeeper/data/myid
    chown zookeeper:zookeeper /data/zookeeper/data/myid
    
    # 修改配置文件
    cat > /opt/zookeeper/conf/zoo.cfg << EOF
# 基本配置
tickTime=2000
initLimit=10
syncLimit=5
dataDir=/data/zookeeper/data
dataLogDir=/data/zookeeper/logs
clientPort=2181

# 自动清理快照和事务日志
autopurge.snapRetainCount=3
autopurge.purgeInterval=1

# 最大客户端连接数
maxClientCnxns=60

# 集群配置
EOF
    
    # 添加集群节点配置
    local node_id=1
    for node in "${nodes[@]}"; do
        echo "server.${node_id}=${node}:2888:3888" >> /opt/zookeeper/conf/zoo.cfg
        ((node_id++))
    done
    
    chown zookeeper:zookeeper /opt/zookeeper/conf/zoo.cfg
    print_info "集群配置完成"
}

# 创建系统服务
create_systemd_service() {
    # 检查是否在容器环境中
    if [ ! -d "/sys/fs/cgroup/systemd" ] || [ ! -d "/run/systemd/system" ]; then
        print_info "容器环境中跳过创建系统服务"
        return 0
    fi
    
    print_info "创建 ZooKeeper 系统服务..."
    cat > /etc/systemd/system/zookeeper.service << EOF
[Unit]
Description=Apache ZooKeeper Server
Documentation=http://zookeeper.apache.org
After=network.target

[Service]
Type=forking
User=zookeeper
Environment="JAVA_HOME=$JAVA_HOME"
Environment="ZOO_LOG_DIR=/data/zookeeper/logs"
ExecStart=/opt/zookeeper/bin/zkServer.sh start
ExecStop=/opt/zookeeper/bin/zkServer.sh stop
ExecReload=/opt/zookeeper/bin/zkServer.sh restart
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

# 新增远程部署函数
deploy_to_remote() {
    local remote_ip=$1
    print_info "开始部署到远程节点: $remote_ip"
    
    # 检查 SSH 连接
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes root@$remote_ip echo "SSH 连接测试" &>/dev/null; then
        print_error "无法连接到节点 $remote_ip，请确保："
        print_error "1. 目标节点 SSH 服务正常"
        print_error "2. 已配置免密登录"
        return 1
    fi
    
    # 创建远程目录
    ssh root@$remote_ip "mkdir -p /tmp/zk_install"
    
    # 复制所需文件到远程节点
    local current_dir=$(dirname $0)
    scp "$current_dir"/{install_zookeeper.sh,install_java.sh,install_base_tools.sh} \
        root@$remote_ip:/tmp/zk_install/
    
    # 复制已下载的 ZooKeeper 包到远程节点
    scp /tmp/apache-zookeeper-${ZK_VERSION}-bin.tar.gz root@$remote_ip:/tmp/
    
    # 在远程节点执行安装
    ssh root@$remote_ip "cd /tmp/zk_install && bash install_zookeeper.sh --node-id=$2 --auto-install \
        --zk-version=${ZK_VERSION} --cluster-config='${CLUSTER_CONFIG}'"
    
    if [ $? -eq 0 ]; then
        print_info "节点 $remote_ip 部署完成"
    else
        print_error "节点 $remote_ip 部署失败"
        return 1
    fi
}

# 修改启动函数
start_zookeeper() {
    print_info "启动 ZooKeeper 服务..."
    
    # 确保日志目录权限正确
    chown -R zookeeper:zookeeper /data/zookeeper/logs
    
    # 使用 zookeeper 用户启动服务
    su - zookeeper -s /bin/bash -c "export JAVA_HOME=$JAVA_HOME && \
        export ZOO_LOG_DIR=/data/zookeeper/logs && \
        cd /opt/zookeeper && \
        bin/zkServer.sh start"
    
    # 检查启动状态
    sleep 3
    if pgrep -f "org.apache.zookeeper.server.quorum.QuorumPeerMain" >/dev/null; then
        print_info "ZooKeeper 服务启动成功"
        su - zookeeper -s /bin/bash -c "cd /opt/zookeeper && bin/zkServer.sh status"
    else
        print_error "ZooKeeper 服务启动失败"
        # 检查日志文件
        if [ -f "/data/zookeeper/logs/zookeeper.out" ]; then
            print_error "错误日志:"
            tail -n 5 /data/zookeeper/logs/zookeeper.out
        fi
        exit 1
    fi
}

# 检查现有 ZooKeeper 环境
check_existing_zookeeper() {
    print_info "检查现有 ZooKeeper 环境..."
    
    local zk_installed=false
    local zk_version=""
    local zk_home=""
    local zk_running=false
    
    # 检查常见安装路径
    if [ -d "/opt/zookeeper" ]; then
        zk_installed=true
        zk_home="/opt/zookeeper"
        if [ -f "$zk_home/bin/zkServer.sh" ]; then
            zk_version=$($zk_home/bin/zkServer.sh version 2>&1 | grep -o "version: [0-9]\.[0-9]\.[0-9]" | cut -d' ' -f2)
        fi
    fi
    
    # 检查服务状态
    if [ "$zk_installed" = true ]; then
        # 检查是否在容器环境中
        if [ ! -d "/sys/fs/cgroup/systemd" ] || [ ! -d "/run/systemd/system" ]; then
            if $zk_home/bin/zkServer.sh status &>/dev/null; then
                zk_running=true
            fi
        else
            if systemctl is-active zookeeper &>/dev/null; then
                zk_running=true
            fi
        fi
        
        print_warning "检测到已安装的 ZooKeeper:"
        echo "安装路径: $zk_home"
        if [ -n "$zk_version" ]; then
            echo "版本: $zk_version"
        fi
        echo "运行状态: $([ "$zk_running" = true ] && echo "运行中" || echo "未运行")"
        
        # 如果服务正在运行，提供更多信息
        if [ "$zk_running" = true ]; then
            echo "配置文件: $zk_home/conf/zoo.cfg"
            if [ -f "/data/zookeeper/data/myid" ]; then
                echo "节点ID: $(cat /data/zookeeper/data/myid)"
            fi
        fi
        
        # 询问用户是否继续安装
        read -p "是否继续安装新的 ZooKeeper？这将覆盖现有安装 (y/N) " choice
        case "$choice" in
            [yY]|[yY][eE][sS])
                if [ "$zk_running" = true ]; then
                    print_info "停止现有 ZooKeeper 服务..."
                    if [ ! -d "/sys/fs/cgroup/systemd" ] || [ ! -d "/run/systemd/system" ]; then
                        su - zookeeper -c "$zk_home/bin/zkServer.sh stop"
                    else
                        systemctl stop zookeeper
                    fi
                fi
                print_info "继续安装新的 ZooKeeper..."
                ;;
            *)
                print_info "取消安装"
                exit 0
                ;;
        esac
    else
        print_info "未检测到已安装的 ZooKeeper，继续安装..."
    fi
}

# 修改主函数
main() {
    # 检查 root 权限
    if [ "$EUID" -ne 0 ]; then 
        print_error "请使用 root 权限运行此脚本"
        exit 1
    fi
    
    # 解析命令行参数
    local AUTO_INSTALL=false
    local NODE_ID=""
    CLUSTER_CONFIG=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --node-id=*)
                NODE_ID="${1#*=}"
                shift
                ;;
            --auto-install)
                AUTO_INSTALL=true
                shift
                ;;
            --zk-version=*)
                ZK_VERSION="${1#*=}"
                shift
                ;;
            --cluster-config=*)
                CLUSTER_CONFIG="${1#*=}"
                shift
                ;;
            *)
                shift
                ;;
        esac
    done
    
    check_os
    check_base_tools
    check_java_env
    
    if [ "$AUTO_INSTALL" = true ]; then
        # 自动安装模式（用于远程节点）
        if [ -z "$NODE_ID" ] || [ -z "$CLUSTER_CONFIG" ]; then
            print_error "自动安装模式需要指定节点ID和集群配置"
            exit 1
        fi
        create_zookeeper_user
        install_zookeeper
        eval "declare -A nodes=${CLUSTER_CONFIG}"
        configure_cluster_auto "$NODE_ID" nodes
        create_systemd_service
    else
        check_existing_zookeeper
        # 交互模式
        select_zookeeper_version
        create_zookeeper_user
        install_zookeeper
        
        # 选择部署模式
        echo -e "\n请选择部署模式:"
        echo "1) 单节点模式"
        echo "2) 集群模式"
        read -p "请选择（1-2）: " deploy_mode
        
        case "$deploy_mode" in
            1)
                configure_standalone
                create_systemd_service
                print_info "单节点模式配置完成"
                ;;
            2)
                # 获取集群配置
                echo -e "\n请输入集群节点信息（最少3个节点）"
                declare -A cluster_nodes
                local i=1
                
                while true; do
                    read -p "请输入节点 $i 的IP地址（直接回车结束输入）: " node_ip
                    if [ -z "$node_ip" ]; then
                        break
                    fi
                    cluster_nodes[$i]=$node_ip
                    ((i++))
                done
                
                if [ ${#cluster_nodes[@]} -lt 3 ]; then
                    print_error "节点数量不能少于3个"
                    exit 1
                fi
                
                # 配置本地节点
                configure_cluster_auto 1 cluster_nodes
                create_systemd_service
                
                # 导出集群配置
                CLUSTER_CONFIG=$(declare -p cluster_nodes)
                
                # 询问是否部署到其他节点
                read -p "是否自动部署到其他节点？(y/N) " deploy_choice
                case "$deploy_choice" in
                    [yY]|[yY][eE][sS])
                        print_info "开始部署到其他节点..."
                        for id in "${!cluster_nodes[@]}"; do
                            if [ $id -ne 1 ]; then
                                deploy_to_remote "${cluster_nodes[$id]}" "$id"
                            fi
                        done
                        ;;
                    *)
                        print_info "跳过远程部署，请手动在其他节点上执行安装"
                        ;;
                esac
                ;;
            *)
                print_error "无效的选择"
                exit 1
                ;;
        esac
    fi
    
    print_info "ZooKeeper 安装完成！"
    print_info "使用以下命令管理 ZooKeeper："
    print_info "启动：su - zookeeper -c 'cd /opt/zookeeper && bin/zkServer.sh start'"
    print_info "停止：su - zookeeper -c 'cd /opt/zookeeper && bin/zkServer.sh stop'"
    print_info "状态：su - zookeeper -c 'cd /opt/zookeeper && bin/zkServer.sh status'"
    
    # 询问是否立即启动服务
    read -p "是否立即启动 ZooKeeper 服务？(y/N) " start_choice
    case "$start_choice" in
        [yY]|[yY][eE][sS])
            start_zookeeper
            ;;
        *)
            print_info "跳过服务启动"
            ;;
    esac
    
    if [ "$deploy_mode" = "2" ]; then
        print_info "\n注意：请确保所有节点的防火墙都已开放以下端口："
        print_info "2181 (客户端连接端口)"
        print_info "2888 (集群内部通信端口)"
        print_info "3888 (集群选举端口)"
    else
        print_info "\n注意：请确保防火墙已开放以下端口："
        print_info "2181 (客户端连接端口)"
    fi
}

# 执行主函数
main "$@" 