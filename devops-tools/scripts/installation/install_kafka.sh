#!/bin/bash

# Kafka 安装脚本
# 设置变量
KAFKA_VERSION="3.6.1"
SCALA_VERSION="2.13"
KAFKA_HOME="/opt/kafka"
DATA_DIR="/data/kafka"
LOG_DIR="/data/kafka-logs"
ZOOKEEPER_DATA="/data/zookeeper"

# 颜色输出函数
print_info() {
    echo -e "\033[32m[INFO] $1\033[0m"
}

print_error() {
    echo -e "\033[31m[ERROR] $1\033[0m"
}

# 检查是否以 root 运行
if [ "$EUID" -ne 0 ]; then 
    print_error "请使用 root 权限运行此脚本"
    exit 1
fi

# 检查 Java 环境
check_java() {
    if ! command -v java &> /dev/null; then
        print_error "未检测到 Java 环境，正在安装 OpenJDK..."
        apt-get update && apt-get install -y openjdk-11-jdk || {
            print_error "Java 安装失败"
            exit 1
        }
    fi
    print_info "Java 环境检查通过"
}

# 创建必要目录
create_directories() {
    print_info "创建必要目录..."
    mkdir -p $KAFKA_HOME $DATA_DIR $LOG_DIR $ZOOKEEPER_DATA
}

# 下载并安装 Kafka
install_kafka() {
    print_info "开始下载 Kafka..."
    local KAFKA_URL="https://downloads.apache.org/kafka/${KAFKA_VERSION}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz"
    local TEMP_FILE="/tmp/kafka.tgz"
    
    wget -O $TEMP_FILE $KAFKA_URL || {
        print_error "Kafka 下载失败"
        exit 1
    }
    
    print_info "解压 Kafka..."
    tar -xzf $TEMP_FILE -C /opt
    mv /opt/kafka_${SCALA_VERSION}-${KAFKA_VERSION}/* $KAFKA_HOME/
    rm -f $TEMP_FILE
}

# 配置 Kafka
configure_kafka() {
    print_info "配置 Kafka..."
    
    # 配置 ZooKeeper
    cat > $KAFKA_HOME/config/zookeeper.properties << EOF
dataDir=$ZOOKEEPER_DATA
clientPort=2181
maxClientCnxns=0
admin.enableServer=false
tickTime=2000
initLimit=10
syncLimit=5
EOF

    # 配置 Kafka
    cat > $KAFKA_HOME/config/server.properties << EOF
broker.id=0
listeners=PLAINTEXT://localhost:9092
num.network.threads=3
num.io.threads=8
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600
log.dirs=$LOG_DIR
num.partitions=1
num.recovery.threads.per.data.dir=1
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
log.retention.hours=168
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000
zookeeper.connect=localhost:2181
zookeeper.connection.timeout.ms=18000
EOF
}

# 创建系统服务
create_services() {
    print_info "创建系统服务..."
    
    # ZooKeeper 服务
    cat > /etc/systemd/system/zookeeper.service << EOF
[Unit]
Description=Apache ZooKeeper
After=network.target

[Service]
Type=simple
Environment=KAFKA_HOME=$KAFKA_HOME
ExecStart=$KAFKA_HOME/bin/zookeeper-server-start.sh $KAFKA_HOME/config/zookeeper.properties
ExecStop=$KAFKA_HOME/bin/zookeeper-server-stop.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    # Kafka 服务
    cat > /etc/systemd/system/kafka.service << EOF
[Unit]
Description=Apache Kafka
After=network.target zookeeper.service

[Service]
Type=simple
Environment=KAFKA_HOME=$KAFKA_HOME
ExecStart=$KAFKA_HOME/bin/kafka-server-start.sh $KAFKA_HOME/config/server.properties
ExecStop=$KAFKA_HOME/bin/kafka-server-stop.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    # 重新加载系统服务
    systemctl daemon-reload
}

# 启动服务
start_services() {
    print_info "启动服务..."
    systemctl start zookeeper
    sleep 5
    systemctl start kafka
    
    # 设置开机自启
    systemctl enable zookeeper
    systemctl enable kafka
}

# 检查服务状态
check_status() {
    print_info "检查服务状态..."
    systemctl status zookeeper
    systemctl status kafka
}

# 获取 Kafka 最新版本列表
get_kafka_versions() {
    print_info "获取 Kafka 版本列表..."
    local versions=$(curl -s https://downloads.apache.org/kafka/ | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\/' | sort -V | tail -10 | sed 's/\///')
    if [ -z "$versions" ]; then
        print_error "无法获取 Kafka 版本列表"
        exit 1
    }
    echo "$versions"
}

# 选择 Kafka 版本
select_kafka_version() {
    local versions=($(get_kafka_versions))
    KAFKA_VERSION=${versions[-1]} # 默认使用最新版本
    
    echo "可用的 Kafka 版本:"
    for i in "${!versions[@]}"; do
        echo "[$((i+1))] ${versions[$i]}"
    done
    
    read -p "请选择版本 [1-${#versions[@]}] (默认 ${#versions[@]}, 最新版 $KAFKA_VERSION): " choice
    
    if [[ -n "$choice" && "$choice" =~ ^[0-9]+$ && "$choice" -le "${#versions[@]}" && "$choice" -gt 0 ]]; then
        KAFKA_VERSION=${versions[$((choice-1))]}
    fi
    
    print_info "已选择 Kafka 版本: $KAFKA_VERSION"
}

# 修改主函数
main() {
    print_info "开始安装 Kafka..."
    select_kafka_version
    check_java
    create_directories
    install_kafka
    configure_kafka
    create_services
    start_services
    check_status
    print_info "Kafka 安装完成！"
    print_info "ZooKeeper 端口: 2181"
    print_info "Kafka 端口: 9092"
}

# 执行主函数
main 