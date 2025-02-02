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

# 配置 CentOS 7 仓库
configure_centos7_repo() {
    print_info "配置 CentOS 7 仓库..."
    
    # 备份原有仓库文件
    mkdir -p /etc/yum.repos.d/backup
    mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ 2>/dev/null || true
    
    # 配置基础仓库
    cat > /etc/yum.repos.d/CentOS-Base.repo << 'EOF'
[base]
name=CentOS-7 - Base
baseurl=https://mirrors.aliyun.com/centos/7/os/$basearch/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7

[updates]
name=CentOS-7 - Updates
baseurl=https://mirrors.aliyun.com/centos/7/updates/$basearch/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7

[extras]
name=CentOS-7 - Extras
baseurl=https://mirrors.aliyun.com/centos/7/extras/$basearch/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7

[epel]
name=Extra Packages for Enterprise Linux 7 - $basearch
baseurl=https://mirrors.aliyun.com/epel/7/$basearch
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/epel/RPM-GPG-KEY-EPEL-7
EOF
    
    # 清理并更新缓存
    yum clean all
    yum makecache
}

# 安装和配置 GCC
install_gcc() {
    print_info "安装和配置 GCC..."
    
    # 先检查 gcc 是否已安装
    if command -v gcc &>/dev/null; then
        print_info "检测到已安装的 GCC："
        gcc --version | head -n1
    else
        # 如果没有安装，则进行安装
        if [ "$OS_TYPE" = "rhel" ]; then
            if [ "$OS_VERSION" = "7" ]; then
                # 直接安装必要的编译工具包
                yum -y install gcc gcc-c++ make autoconf automake libtool pkgconfig
                
                # 如果安装失败，尝试更新 yum 缓存后重试
                if [ $? -ne 0 ]; then
                    print_warning "GCC 安装失败，尝试更新缓存后重新安装..."
                    yum clean all
                    yum makecache
                    yum -y install gcc gcc-c++ make autoconf automake libtool pkgconfig
                fi
                
            elif [ "$OS_VERSION" -ge 8 ]; then
                # CentOS 8+ 直接安装 gcc
                dnf -y install gcc gcc-c++
            fi
        elif [ "$OS_TYPE" = "debian" ]; then
            # Debian/Ubuntu 系统
            apt-get update
            apt-get -y install gcc g++ build-essential
        fi
        
        # 验证安装结果
        if ! command -v gcc &>/dev/null; then
            print_error "GCC 安装失败"
            exit 1
        fi
    fi
    
    # 检查并创建 cc 链接
    if ! command -v cc &>/dev/null; then
        print_info "创建 cc 链接..."
        # 获取 gcc 实际路径
        GCC_PATH=$(which gcc)
        if [ -n "$GCC_PATH" ]; then
            ln -sf "$GCC_PATH" /usr/bin/cc
            if [ $? -ne 0 ]; then
                print_error "创建 cc 链接失败，请检查权限"
                exit 1
            fi
        else
            print_error "无法获取 gcc 路径"
            exit 1
        fi
    else
        print_info "cc 命令已存在"
    fi
    
    # 最终验证
    if command -v cc &>/dev/null; then
        print_info "GCC 环境配置完成"
        cc --version | head -n1
    else
        print_error "GCC 环境配置失败"
        exit 1
    fi
}

# 检查基础工具
check_base_tools() {
    print_info "检查基础工具..."
    
    # 根据操作系统类型安装编译工具
    if [ "$OS_TYPE" = "rhel" ]; then
        print_info "安装基础工具..."
        
        # 检查是否为 CentOS 7
        if [ "$OS_VERSION" = "7" ]; then
            configure_centos7_repo
        fi
        
        # 安装基本工具
        yum -y install wget curl tar make tcl
        
    elif [ "$OS_TYPE" = "debian" ]; then
        print_info "安装基础工具..."
        apt-get update
        apt-get -y install wget curl tar make tcl
    fi
    
    # 验证基础工具是否安装成功
    local tools_to_check="wget curl tar make"
    for tool in $tools_to_check; do
        if ! command -v $tool &>/dev/null; then
            print_error "工具 $tool 安装失败"
            exit 1
        fi
    done
    
    print_info "基础工具检查完成"
}

# 检查现有 Redis 环境
check_existing_redis() {
    print_info "检查现有 Redis 环境..."
    
    local redis_installed=false
    local redis_version=""
    local redis_running=false
    
    if command -v redis-server &>/dev/null; then
        redis_installed=true
        redis_version=$(redis-server --version | grep -o "v=[0-9]\.[0-9]\.[0-9]" | cut -d'=' -f2)
    fi
    
    if [ "$redis_installed" = true ]; then
        if pgrep -f "redis-server" >/dev/null; then
            redis_running=true
        fi
        
        print_warning "检测到已安装的 Redis:"
        echo "版本: $redis_version"
        echo "运行状态: $([ "$redis_running" = true ] && echo "运行中" || echo "未运行")"
        
        read -p "是否继续安装新的 Redis？这将覆盖现有安装 (y/N) " choice
        case "$choice" in
            [yY]|[yY][eE][sS])
                if [ "$redis_running" = true ]; then
                    print_info "停止现有 Redis 服务..."
                    if command -v systemctl &>/dev/null; then
                        systemctl stop redis
                    else
                        redis-cli shutdown
                    fi
                fi
                ;;
            *)
                print_info "取消安装"
                exit 0
                ;;
        esac
    fi
}

# 获取 Redis 版本
select_redis_version() {
    print_info "获取 Redis 最新稳定版本..."
    
    # 获取最新稳定版本
    local latest_version=$(curl -s https://download.redis.io/redis-stable/00-RELEASENOTES | grep -o "Redis [0-9]\.[0-9]\.[0-9]" | head -n 1 | cut -d' ' -f2)
    
    if [ -z "$latest_version" ]; then
        latest_version="7.2.3"  # 默认版本
    fi
    
    REDIS_VERSION=$latest_version
    print_info "将安装 Redis 版本: $REDIS_VERSION"
}

# 安装 Redis
install_redis() {
    print_info "开始下载 Redis..."
    local redis_tar="redis-${REDIS_VERSION}.tar.gz"
    local download_url="https://download.redis.io/releases/${redis_tar}"
    
    cd /tmp
    # 清理旧文件
    rm -rf "redis-${REDIS_VERSION}" "${redis_tar}"
    
    wget "${download_url}"
    if [ $? -ne 0 ]; then
        print_error "Redis 下载失败"
        exit 1
    fi
    
    print_info "解压并编译 Redis..."
    tar xzf "${redis_tar}"
    cd "redis-${REDIS_VERSION}"
    
    # 清理并重新编译，使用保守的编译选项
    make distclean
    make MALLOC=libc CFLAGS="-O2 -march=x86-64 -mtune=generic" V=1
    
    if [ $? -ne 0 ]; then
        print_error "Redis 编译失败，尝试使用更保守的编译选项..."
        make distclean
        make MALLOC=libc CFLAGS="-O1 -march=x86-64" V=1
        
        if [ $? -ne 0 ]; then
            print_error "Redis 编译失败"
            # 显示详细错误信息
            if [ -f "make.log" ]; then
                print_error "编译日志:"
                tail -n 20 make.log
            fi
            exit 1
        fi
    fi
    
    make install
    
    # 创建必要的目录
    mkdir -p /etc/redis /var/lib/redis /var/log/redis
    
    # 复制配置文件
    cp redis.conf /etc/redis/
    
    # 创建 Redis 用户
    if ! id "redis" &>/dev/null; then
        useradd -r -s /sbin/nologin redis
    fi
    
    # 设置权限
    chown -R redis:redis /etc/redis /var/lib/redis /var/log/redis
}

# 配置单机版 Redis
configure_standalone() {
    print_info "配置 Redis 单机模式..."
    
    # 修改配置文件
    cat > /etc/redis/redis.conf << EOF
# 基本配置
bind 127.0.0.1
port 6379
daemonize yes
pidfile /var/run/redis.pid
dir /var/lib/redis
logfile /var/log/redis/redis.log

# 持久化配置
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec

# 内存配置
maxmemory 256mb
maxmemory-policy allkeys-lru

# 安全配置
protected-mode yes
EOF

    print_info "单机模式配置完成"
}

# 配置集群版 Redis
configure_cluster() {
    print_info "配置 Redis 集群模式..."
    
    # 获取集群节点信息
    echo -e "\n请输入集群节点信息（至少6个节点，3主3从）"
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
            NODE_ID=$i
        fi
        
        cluster_nodes[$i]=$node_ip
        ((i++))
    done
    
    if [ ${#cluster_nodes[@]} -lt 6 ]; then
        print_error "集群模式至少需要6个节点"
        exit 1
    fi
    
    # 修改配置文件
    cat > /etc/redis/redis.conf << EOF
# 基本配置
bind ${current_node}
port 6379
daemonize yes
pidfile /var/run/redis.pid
dir /var/lib/redis
logfile /var/log/redis/redis.log

# 集群配置
cluster-enabled yes
cluster-config-file /etc/redis/nodes.conf
cluster-node-timeout 5000

# 持久化配置
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec

# 内存配置
maxmemory 256mb
maxmemory-policy allkeys-lru

# 安全配置
protected-mode no
EOF

    print_info "集群模式配置完成"
    
    # 导出集群配置
    CLUSTER_CONFIG=$(declare -p cluster_nodes)
}

# 启动 Redis
start_redis() {
    print_info "启动 Redis 服务..."
    
    redis-server /etc/redis/redis.conf
    sleep 2
    
    if pgrep -f "redis-server" >/dev/null; then
        print_info "Redis 服务启动成功"
        redis-cli ping
    else
        print_error "Redis 服务启动失败"
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
    install_gcc
    check_existing_redis
    select_redis_version
    install_redis
    
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
    
    print_info "Redis 安装完成！"
    print_info "使用以下命令管理 Redis："
    print_info "启动：redis-server /etc/redis/redis.conf"
    print_info "停止：redis-cli shutdown"
    print_info "状态：redis-cli ping"
    print_info "连接：redis-cli"
    
    if [ "$deploy_mode" = "2" ]; then
        print_info "\n集群模式额外命令："
        print_info "创建集群：redis-cli --cluster create <node1>:6379 ... <node6>:6379 --cluster-replicas 1"
        print_info "检查集群：redis-cli --cluster check <node>:6379"
    fi
    
    # 询问是否立即启动服务
    read -p "是否立即启动 Redis 服务？(y/N) " start_choice
    case "$start_choice" in
        [yY]|[yY][eE][sS])
            start_redis
            ;;
        *)
            print_info "跳过服务启动"
            ;;
    esac
    
    print_info "\n注意：请确保防火墙已开放以下端口："
    print_info "6379 (Redis 服务端口)"
    if [ "$deploy_mode" = "2" ]; then
        print_info "16379 (Redis 集群总线端口)"
    fi
}

# 执行主函数
main 