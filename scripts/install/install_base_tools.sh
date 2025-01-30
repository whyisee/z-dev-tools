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

# 基础工具列表
get_base_tools() {
    # 通用工具列表
    local common_tools="wget curl vim net-tools tar unzip"
    
    # 根据系统类型添加特定工具
    if [ "$OS_TYPE" = "rhel" ]; then
        echo "$common_tools yum-utils epel-release which"
    elif [ "$OS_TYPE" = "debian" ]; then
        echo "$common_tools apt-transport-https ca-certificates software-properties-common"
    fi
}

# 更新系统包
update_system() {
    print_info "更新系统包..."
    
    if [ "$OS_TYPE" = "rhel" ]; then
        if [ "$OS_VERSION" = "stream" ] || [ "$OS_VERSION" -ge 8 ]; then
            dnf -y update
        else
            yum -y update
        fi
    elif [ "$OS_TYPE" = "debian" ]; then
        apt-get update
        apt-get -y upgrade
    fi
}

# 安装基础工具
install_base_tools() {
    print_info "安装基础工具..."
    
    local tools=$(get_base_tools)
    print_info "将要安装的工具: $tools"
    
    if [ "$OS_TYPE" = "rhel" ]; then
        if [ "$OS_VERSION" = "stream" ] || [ "$OS_VERSION" -ge 8 ]; then
            # 安装 EPEL 仓库
            dnf -y install epel-release
            dnf -y install $tools
        else
            # 安装 EPEL 仓库
            yum -y install epel-release
            yum -y install $tools
        fi
    elif [ "$OS_TYPE" = "debian" ]; then
        apt-get -y install $tools
    fi
    
    if [ $? -ne 0 ]; then
        print_error "工具安装失败"
        exit 1
    fi
}

# 验证安装
verify_installation() {
    print_info "验证工具安装..."
    
    local failed_tools=""
    
    # 需要验证命令存在的工具
    local cmd_tools="wget curl vim tar unzip"
    for tool in $cmd_tools; do
        if ! command -v $tool &>/dev/null; then
            failed_tools="$failed_tools $tool"
        fi
    done
    
    # 验证包是否安装（针对不创建命令的包）
    if [ "$OS_TYPE" = "rhel" ]; then
        local pkg_tools="net-tools yum-utils epel-release"
        for tool in $pkg_tools; do
            if [ "$OS_VERSION" = "stream" ] || [ "$OS_VERSION" -ge 8 ]; then
                if ! dnf list installed "$tool" &>/dev/null; then
                    failed_tools="$failed_tools $tool"
                fi
            else
                if ! rpm -q "$tool" &>/dev/null; then
                    failed_tools="$failed_tools $tool"
                fi
            fi
        done
    elif [ "$OS_TYPE" = "debian" ]; then
        local pkg_tools="net-tools apt-transport-https ca-certificates software-properties-common"
        for tool in $pkg_tools; do
            if ! dpkg -l "$tool" &>/dev/null; then
                failed_tools="$failed_tools $tool"
            fi
        done
    fi
    
    if [ -n "$failed_tools" ]; then
        print_error "以下工具安装失败:$failed_tools"
        exit 1
    fi
    
    print_info "所有工具安装成功"
}

# 配置国内镜像源
configure_repo() {
    print_info "配置国内镜像源..."
    
    if [ "$OS_TYPE" = "rhel" ]; then
        # 备份原有源
        if [ ! -f /etc/yum.repos.d/CentOS-Base.repo.backup ]; then
            mv /etc/yum.repos.d/CentOS-Base.repo /etc/yum.repos.d/CentOS-Base.repo.backup
        fi
        
        # 下载阿里云源
        if [ "$OS_VERSION" = "stream" ] || [ "$OS_VERSION" -ge 8 ]; then
            curl -o /etc/yum.repos.d/CentOS-Base.repo https://mirrors.aliyun.com/repo/Centos-8.repo
        else
            curl -o /etc/yum.repos.d/CentOS-Base.repo https://mirrors.aliyun.com/repo/Centos-7.repo
        fi
        
        # 清除缓存并重新生成
        if [ "$OS_VERSION" = "stream" ] || [ "$OS_VERSION" -ge 8 ]; then
            dnf clean all
            dnf makecache
        else
            yum clean all
            yum makecache
        fi
        
    elif [ "$OS_TYPE" = "debian" ]; then
        # 备份原有源
        if [ ! -f /etc/apt/sources.list.backup ]; then
            cp /etc/apt/sources.list /etc/apt/sources.list.backup
        fi
        
        # 使用阿里云源
        cat > /etc/apt/sources.list << EOF
deb http://mirrors.aliyun.com/debian/ $(lsb_release -cs) main contrib non-free
deb http://mirrors.aliyun.com/debian/ $(lsb_release -cs)-updates main contrib non-free
deb http://mirrors.aliyun.com/debian-security $(lsb_release -cs)-security main contrib non-free
EOF
        
        apt-get update
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
    configure_repo
    update_system
    install_base_tools
    verify_installation
    
    print_info "基础工具安装完成！"
}

# 执行主函数
main 