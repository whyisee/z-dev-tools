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

# 获取 Kafka 可用版本
get_kafka_versions() {
    # 不在这里输出信息，移到调用处
    curl -s https://downloads.apache.org/kafka/ | \
        grep -o 'href="[0-9]\.[0-9]\.[0-9]/"' | \
        grep -o '[0-9]\.[0-9]\.[0-9]' | \
        sort -V
}

# 选择 Kafka 版本
select_kafka_version() {
    print_info "获取 Kafka 可用版本列表..."
    
    # 使用临时文件存储版本列表
    local temp_file="/tmp/kafka_versions.tmp"
    get_kafka_versions > "$temp_file"
    
    # 读取版本到数组
    local versions=()
    while IFS= read -r version; do
        versions+=("$version")
    done < "$temp_file"
    rm -f "$temp_file"
    
    # 如果没有获取到版本，则退出
    if [ ${#versions[@]} -eq 0 ]; then
        print_error "无法获取 Kafka 版本列表"
        exit 1
    fi
    
    local latest_version=${versions[-1]}
    
    echo -e "\n可用的 Kafka 版本:"
    local i=1
    for version in "${versions[@]}"; do
        echo "$i) $version"
        ((i++))
    done
    
    echo
    read -p "请选择版本号（1-${#versions[@]}），直接回车将安装最新版 $latest_version: " choice
    
    if [ -z "$choice" ]; then
        KAFKA_VERSION=$latest_version
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#versions[@]}" ]; then
        KAFKA_VERSION=${versions[$((choice-1))]}
    else
        print_error "无效的选择，将使用最新版 $latest_version"
        KAFKA_VERSION=$latest_version
    fi
    
    print_info "选择的 Kafka 版本: $KAFKA_VERSION"
}

# 定义变量
SCALA_VERSION="2.13"
KAFKA_HOME="/opt/kafka"
KAFKA_DATA="/data/kafka"
KAFKA_LOGS="/data/kafka-logs"
KAFKA_CONFIG="${KAFKA_HOME}/config/server.properties"

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
        
        # 执行基础工具安装脚本
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
    
    # 检查 java 命令是否存在
    if ! command -v java &>/dev/null; then
        print_warning "未检测到 Java 环境，开始安装 Java..."
        
        # 检查 Java 安装脚本是否存在
        local java_script="$(dirname $0)/install_java.sh"
        if [ ! -f "$java_script" ]; then
            print_error "找不到 Java 安装脚本: $java_script"
            exit 1
        fi
        
        # 执行 Java 安装脚本
        bash "$java_script"
        if [ $? -ne 0 ]; then
            print_error "Java 安装失败"
            exit 1
        fi
        
        # 重新加载环境变量
        source /etc/profile
    fi
    
    # 验证 Java 版本
    local java_version=$(java -version 2>&1 | grep -i version | cut -d'"' -f2)
    print_info "检测到 Java 版本: $java_version"
    
    # 检查 JAVA_HOME 是否设置
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

# 创建 Kafka 用户
create_kafka_user() {
    print_info "创建 kafka 用户..."
    if ! id "kafka" &>/dev/null; then
        useradd -r -s /sbin/nologin kafka
    fi
}

# 下载和安装 Kafka
install_kafka() {
    print_info "开始下载 Kafka..."
    local kafka_tar="kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz"
    local download_url="https://downloads.apache.org/kafka/${KAFKA_VERSION}/${kafka_tar}"
    
    cd /tmp
    if [ ! -f "${kafka_tar}" ]; then
        wget "${download_url}"
        if [ $? -ne 0 ]; then
            print_error "Kafka 下载失败"
            exit 1
        fi
    fi

    print_info "解压并安装 Kafka..."
    tar -xzf "${kafka_tar}"
    rm -rf ${KAFKA_HOME}
    mv "kafka_${SCALA_VERSION}-${KAFKA_VERSION}" ${KAFKA_HOME}
    
    # 创建数据和日志目录
    mkdir -p ${KAFKA_DATA} ${KAFKA_LOGS}
    
    # 设置权限
    chown -R kafka:kafka ${KAFKA_HOME} ${KAFKA_DATA} ${KAFKA_LOGS}
    chmod -R 755 ${KAFKA_HOME} ${KAFKA_DATA} ${KAFKA_LOGS}
}

# 配置单机版 Kafka
configure_standalone() {
    print_info "配置 Kafka 单机模式..."
    
    # 配置 ZooKeeper
    print_info "配置内置 ZooKeeper..."
    cat > ${KAFKA_HOME}/config/zookeeper.properties << EOF
# ZooKeeper 基本配置
dataDir=/data/zookeeper
clientPort=2181
maxClientCnxns=0
admin.enableServer=false

# 自动清理配置
autopurge.snapRetainCount=3
autopurge.purgeInterval=1
EOF

    # 创建 ZooKeeper 数据目录
    mkdir -p /data/zookeeper
    chown -R kafka:kafka /data/zookeeper
    
    # 修改 Kafka 配置文件
    cat > ${KAFKA_CONFIG} << EOF
# Broker 基本配置
broker.id=0
listeners=PLAINTEXT://localhost:9092
advertised.listeners=PLAINTEXT://localhost:9092
num.network.threads=3
num.io.threads=8

# 日志配置
log.dirs=${KAFKA_LOGS}
num.partitions=1
num.recovery.threads.per.data.dir=1
log.retention.hours=168
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000

# ZooKeeper 配置
zookeeper.connect=localhost:2181
zookeeper.connection.timeout.ms=18000

# 其他配置
delete.topic.enable=true
auto.create.topics.enable=true
EOF

    chown kafka:kafka ${KAFKA_CONFIG}
    print_info "单机模式配置完成"
}

# 配置集群版 Kafka
configure_cluster() {
    print_info "配置 Kafka 集群模式..."
    
    # 获取集群节点信息
    echo -e "\n请输入集群节点信息（建议3个或以上节点）"
    declare -A cluster_nodes
    local i=1
    local current_node=""
    
    while true; do
        read -p "请输入节点 $i 的IP地址（直接回车结束输入）: " node_ip
        if [ -z "$node_ip" ]; then
            break
        fi
        
        # 检查是否为当前节点
        if ip addr | grep -q "$node_ip"; then
            current_node=$node_ip
            BROKER_ID=$((i-1))
        fi
        
        cluster_nodes[$i]=$node_ip
        ((i++))
    done
    
    if [ ${#cluster_nodes[@]} -lt 1 ]; then
        print_error "至少需要输入一个节点"
        exit 1
    fi
    
    if [ -z "$current_node" ]; then
        read -p "请输入当前节点的ID（0-$((${#cluster_nodes[@]}-1))）: " BROKER_ID
        if ! [[ "$BROKER_ID" =~ ^[0-9]+$ ]] || [ "$BROKER_ID" -lt 0 ] || [ "$BROKER_ID" -ge "${#cluster_nodes[@]}" ]; then
            print_error "无效的节点ID"
            exit 1
        fi
    fi
    
    # 构建 ZooKeeper 连接字符串
    local zk_connect=""
    for node in "${cluster_nodes[@]}"; do
        if [ -n "$zk_connect" ]; then
            zk_connect="${zk_connect},"
        fi
        zk_connect="${zk_connect}${node}:2181"
    done
    
    # 修改配置文件
    cat > ${KAFKA_CONFIG} << EOF
# Broker 基本配置
broker.id=${BROKER_ID}
listeners=PLAINTEXT://${current_node}:9092
advertised.listeners=PLAINTEXT://${current_node}:9092
num.network.threads=3
num.io.threads=8

# 日志配置
log.dirs=${KAFKA_LOGS}
num.partitions=3
num.recovery.threads.per.data.dir=1
log.retention.hours=168
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000

# ZooKeeper 配置
zookeeper.connect=${zk_connect}
zookeeper.connection.timeout.ms=18000

# 集群配置
default.replication.factor=3
min.insync.replicas=2
unclean.leader.election.enable=false
auto.create.topics.enable=false
delete.topic.enable=true
EOF

    chown kafka:kafka ${KAFKA_CONFIG}
    print_info "集群模式配置完成"
    
    # 询问是否部署到其他节点
    read -p "是否自动部署到其他节点？(y/N) " deploy_choice
    case "$deploy_choice" in
        [yY]|[yY][eE][sS])
            print_info "开始部署到其他节点..."
            for id in "${!cluster_nodes[@]}"; do
                local node_ip="${cluster_nodes[$id]}"
                if [ "$node_ip" != "$current_node" ]; then
                    deploy_to_remote "$node_ip" "$((id-1))"
                fi
            done
            ;;
        *)
            print_info "跳过远程部署，请手动在其他节点上执行安装"
            ;;
    esac
}

# 远程部署函数
deploy_to_remote() {
    local remote_ip=$1
    local broker_id=$2
    print_info "开始部署到远程节点: $remote_ip (broker.id=$broker_id)"
    
    # 检查 SSH 连接
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes root@$remote_ip echo "SSH 连接测试" &>/dev/null; then
        print_error "无法连接到节点 $remote_ip，请确保："
        print_error "1. 目标节点 SSH 服务正常"
        print_error "2. 已配置免密登录"
        return 1
    fi
    
    # 创建远程目录
    ssh root@$remote_ip "mkdir -p /tmp/kafka_install"
    
    # 复制所需文件到远程节点
    local current_dir=$(dirname $0)
    scp "$current_dir"/{install_kafka.sh,install_java.sh,install_base_tools.sh} \
        root@$remote_ip:/tmp/kafka_install/
    
    # 复制已下载的 Kafka 包到远程节点
    scp /tmp/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz root@$remote_ip:/tmp/
    
    # 在远程节点执行安装
    ssh root@$remote_ip "cd /tmp/kafka_install && bash install_kafka.sh \
        --broker-id=$broker_id \
        --auto-install \
        --kafka-version=${KAFKA_VERSION} \
        --cluster-config='${CLUSTER_CONFIG}'"
}

# 创建系统服务
create_systemd_service() {
    print_info "创建 Kafka 系统服务..."
    
    cat > /etc/systemd/system/kafka.service << EOF
[Unit]
Description=Apache Kafka Server
Documentation=http://kafka.apache.org/documentation.html
Requires=zookeeper.service
After=zookeeper.service

[Service]
Type=simple
User=kafka
Environment="JAVA_HOME=/usr/lib/jvm/java"
ExecStart=${KAFKA_HOME}/bin/kafka-server-start.sh ${KAFKA_CONFIG}
ExecStop=${KAFKA_HOME}/bin/kafka-server-stop.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

# 检查现有 Kafka 环境
check_existing_kafka() {
    print_info "检查现有 Kafka 环境..."
    
    local kafka_installed=false
    local kafka_version=""
    local kafka_home=""
    local kafka_running=false
    
    # 检查常见安装路径
    if [ -d "/opt/kafka" ]; then
        kafka_installed=true
        kafka_home="/opt/kafka"
        if [ -f "$kafka_home/bin/kafka-server-start.sh" ]; then
            kafka_version=$(find "$kafka_home" -name "kafka_*.jar" | grep -o "[0-9]\.[0-9]\.[0-9]" | head -n 1)
        fi
    fi
    
    # 检查服务状态
    if [ "$kafka_installed" = true ]; then
        if pgrep -f "kafka.Kafka" >/dev/null; then
            kafka_running=true
        fi
        
        print_warning "检测到已安装的 Kafka:"
        echo "安装路径: $kafka_home"
        if [ -n "$kafka_version" ]; then
            echo "版本: $kafka_version"
        fi
        echo "运行状态: $([ "$kafka_running" = true ] && echo "运行中" || echo "未运行")"
        
        # 如果服务正在运行，提供更多信息
        if [ "$kafka_running" = true ]; then
            echo "配置文件: $kafka_home/config/server.properties"
            if [ -f "$kafka_home/config/server.properties" ]; then
                echo "Broker ID: $(grep "^broker.id=" "$kafka_home/config/server.properties" | cut -d'=' -f2)"
                echo "监听地址: $(grep "^listeners=" "$kafka_home/config/server.properties" | cut -d'=' -f2)"
                echo "ZooKeeper 连接: $(grep "^zookeeper.connect=" "$kafka_home/config/server.properties" | cut -d'=' -f2)"
            fi
        fi
        
        # 询问用户是否继续安装
        read -p "是否继续安装新的 Kafka？这将覆盖现有安装 (y/N) " choice
        case "$choice" in
            [yY]|[yY][eE][sS])
                if [ "$kafka_running" = true ]; then
                    print_info "停止现有 Kafka 服务..."
                    su - kafka -c "cd $kafka_home && bin/kafka-server-stop.sh"
                    sleep 5
                    # 确保进程已经停止
                    if pgrep -f "kafka.Kafka" >/dev/null; then
                        print_warning "Kafka 服务未完全停止，尝试强制终止..."
                        pkill -f "kafka.Kafka"
                        sleep 2
                    fi
                fi
                print_info "继续安装新的 Kafka..."
                ;;
            *)
                print_info "取消安装"
                exit 0
                ;;
        esac
    else
        print_info "未检测到已安装的 Kafka，继续安装..."
    fi
    
    # 检查 ZooKeeper 是否已安装并运行
    if ! pgrep -f "org.apache.zookeeper.server.quorum.QuorumPeerMain" >/dev/null; then
        print_warning "未检测到运行中的 ZooKeeper 服务"
        read -p "是否先安装并启动 ZooKeeper？(Y/n) " zk_choice
        case "$zk_choice" in
            [nN]|[nN][oO])
                print_warning "继续安装 Kafka，但需要手动确保 ZooKeeper 服务可用"
                ;;
            *)
                print_info "开始安装 ZooKeeper..."
                local zk_script="$(dirname $0)/install_zookeeper.sh"
                if [ ! -f "$zk_script" ]; then
                    print_error "找不到 ZooKeeper 安装脚本: $zk_script"
                    exit 1
                fi
                bash "$zk_script"
                if [ $? -ne 0 ]; then
                    print_error "ZooKeeper 安装失败"
                    exit 1
                fi
                ;;
        esac
    fi
}

# 修改启动函数
start_kafka() {
    print_info "启动 Kafka 服务..."
    
    # 确保目录权限正确
    chown -R kafka:kafka ${KAFKA_HOME} ${KAFKA_DATA} ${KAFKA_LOGS}
    
    if [ "$deploy_mode" = "1" ]; then
        # 单机模式：先启动内置 ZooKeeper
        print_info "启动内置 ZooKeeper..."
        ${KAFKA_HOME}/bin/zookeeper-server-start.sh -daemon ${KAFKA_HOME}/config/zookeeper.properties
        sleep 5
        
        # 检查 ZooKeeper 是否启动成功
        if ! pgrep -f "org.apache.zookeeper.server.quorum.QuorumPeerMain" >/dev/null; then
            print_error "ZooKeeper 启动失败"
            exit 1
        fi
        print_info "ZooKeeper 启动成功"
    fi
    
    # 设置环境变量
    export JAVA_HOME=$JAVA_HOME
    export KAFKA_HOME=${KAFKA_HOME}
    export LOG_DIR=${KAFKA_LOGS}
    
    print_info "启动 Kafka Broker..."
    ${KAFKA_HOME}/bin/kafka-server-start.sh -daemon ${KAFKA_CONFIG}
    
    # 检查启动状态
    sleep 5
    if pgrep -f "kafka.Kafka" >/dev/null; then
        print_info "Kafka 服务启动成功"
        # 显示一些基本信息
        echo "进程ID: $(pgrep -f "kafka.Kafka")"
        echo "监听端口: $(netstat -tlnp | grep "$(pgrep -f "kafka.Kafka")" | awk '{print $4}')"
    else
        print_error "Kafka 服务启动失败"
        # 检查日志文件
        if [ -f "${KAFKA_LOGS}/server.log" ]; then
            print_error "错误日志:"
            tail -n 5 "${KAFKA_LOGS}/server.log"
        fi
        exit 1
    fi
}

# 主函数
main() {
    # 检查 root 权限
    if [ "$EUID" -ne 0 ]; then 
        print_error "请使用 root 权限运行此脚本"
        exit 1
    fi
    
    check_os
    check_base_tools
    check_java_env
    check_existing_kafka
    select_kafka_version
    create_kafka_user
    install_kafka
    
    # 选择部署模式
    echo -e "\n请选择部署模式:"
    echo "1) 单机模式"
    echo "2) 集群模式"
    read -p "请选择（1-2）: " deploy_mode
    
    case "$deploy_mode" in
        1)
            configure_standalone
            ;;
        2)
            configure_cluster
            ;;
        *)
            print_error "无效的选择"
            exit 1
            ;;
    esac
    
    create_systemd_service
    
    print_info "Kafka 安装完成！"
    if [ "$deploy_mode" = "1" ]; then
        print_info "使用以下命令管理 Kafka（单机模式）："
        print_info "启动 ZooKeeper：${KAFKA_HOME}/bin/zookeeper-server-start.sh -daemon ${KAFKA_HOME}/config/zookeeper.properties"
        print_info "启动 Kafka：${KAFKA_HOME}/bin/kafka-server-start.sh -daemon ${KAFKA_CONFIG}"
        print_info "停止 Kafka：${KAFKA_HOME}/bin/kafka-server-stop.sh"
        print_info "停止 ZooKeeper：${KAFKA_HOME}/bin/zookeeper-server-stop.sh"
    else
        print_info "使用以下命令管理 Kafka（集群模式）："
        print_info "启动：${KAFKA_HOME}/bin/kafka-server-start.sh -daemon ${KAFKA_CONFIG}"
        print_info "停止：${KAFKA_HOME}/bin/kafka-server-stop.sh"
    fi
    print_info "查看日志：tail -f ${KAFKA_LOGS}/server.log"
    
    # 询问是否立即启动服务
    read -p "是否立即启动 Kafka 服务？(y/N) " start_choice
    case "$start_choice" in
        [yY]|[yY][eE][sS])
            start_kafka
            ;;
        *)
            print_info "跳过服务启动"
            ;;
    esac
    
    print_info "\n注意：请确保防火墙已开放以下端口："
    print_info "9092 (Kafka 监听端口)"
}

# 执行主函数
main 