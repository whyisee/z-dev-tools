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
    print_info "获取 Kafka 可用版本列表..."
    
    # 修改版本获取逻辑，确保只获取版本号
    local versions=$(curl -s https://downloads.apache.org/kafka/ | \
                    grep -o 'href="[0-9]\.[0-9]\.[0-9]/"' | \
                    grep -o '[0-9]\.[0-9]\.[0-9]' | \
                    sort -V)
    
    if [ -z "$versions" ]; then
        print_error "无法获取 Kafka 版本列表"
        exit 1
    fi
    
    # 直接返回版本号，不包含其他输出
    echo "$versions"
}

# 选择 Kafka 版本
select_kafka_version() {
    # 将版本信息存储到数组中，使用换行符作为分隔符
    mapfile -t versions < <(get_kafka_versions)
    local latest_version=${versions[-1]}
    
    print_info "可用的 Kafka 版本:"
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

# 检查是否以 root 运行
if [ "$EUID" -ne 0 ]; then 
    print_error "请使用 root 权限运行此脚本"
    exit 1
fi

# 检查 Java 环境
if ! command -v java &> /dev/null; then
    print_error "未检测到 Java 环境，请先安装 JDK"
    exit 1
fi

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

# 配置 Kafka
configure_kafka() {
    print_info "配置 Kafka..."
    
    # 备份原配置文件
    cp ${KAFKA_CONFIG} ${KAFKA_CONFIG}.backup
    
    # 修改配置文件
    cat > ${KAFKA_CONFIG} << EOF
# Broker 基本配置
broker.id=0
listeners=PLAINTEXT://:9092
advertised.listeners=PLAINTEXT://localhost:9092
num.network.threads=3
num.io.threads=8

# 日志配置
log.dirs=${KAFKA_LOGS}
num.partitions=3
num.recovery.threads.per.data.dir=1
log.retention.hours=168
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000

# Zookeeper 配置
zookeeper.connect=localhost:2181
zookeeper.connection.timeout.ms=18000
EOF

    chown kafka:kafka ${KAFKA_CONFIG}
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

# 主函数
main() {
    # 选择 Kafka 版本
    select_kafka_version
    
    print_info "开始安装 Kafka ${KAFKA_VERSION}..."
    
    create_kafka_user
    install_kafka
    configure_kafka
    create_systemd_service
    
    print_info "Kafka 安装完成！"
    print_info "请确保 Zookeeper 已经安装并运行"
    print_info "使用以下命令启动 Kafka："
    print_info "systemctl start kafka"
    print_info "使用以下命令检查状态："
    print_info "systemctl status kafka"
}

# 执行主函数
main 