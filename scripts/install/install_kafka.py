#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import sys
import subprocess
import requests
import shutil
from pathlib import Path
from typing import List, Optional
import re
from datetime import datetime

class Colors:
    """终端颜色输出"""
    GREEN = '\033[32m'
    RED = '\033[31m'
    YELLOW = '\033[33m'
    RESET = '\033[0m'

def print_info(msg: str) -> None:
    print(f"{Colors.GREEN}[INFO] {msg}{Colors.RESET}")

def print_error(msg: str) -> None:
    print(f"{Colors.RED}[ERROR] {msg}{Colors.RESET}")

def print_warning(msg: str) -> None:
    print(f"{Colors.YELLOW}[WARNING] {msg}{Colors.RESET}")

class KafkaInstaller:
    def __init__(self):
        self.kafka_home = Path("/opt/kafka")
        self.kafka_data = Path("/data/kafka")
        self.kafka_logs = Path("/data/kafka-logs")
        self.scala_version = "2.13"
        self.kafka_version: Optional[str] = None
        self.config_file: Optional[Path] = None

    def check_root(self) -> None:
        """检查是否以 root 权限运行"""
        if os.geteuid() != 0:
            print_error("请使用 root 权限运行此脚本")
            sys.exit(1)

    def check_java(self) -> None:
        """检查 Java 环境"""
        try:
            subprocess.run(["java", "-version"], capture_output=True, check=True)
        except (subprocess.CalledProcessError, FileNotFoundError):
            print_error("未检测到 Java 环境，请先安装 JDK")
            sys.exit(1)

    def get_available_versions(self) -> List[str]:
        """获取可用的 Kafka 版本"""
        try:
            response = requests.get("https://downloads.apache.org/kafka/")
            versions = re.findall(r'href="(\d+\.\d+\.\d+)/"', response.text)
            return sorted(versions, key=lambda v: [int(x) for x in v.split('.')])[-10:]
        except Exception as e:
            print_error(f"获取 Kafka 版本列表失败: {e}")
            sys.exit(1)

    def select_version(self) -> None:
        """选择 Kafka 版本"""
        versions = self.get_available_versions()
        print("\n可用的 Kafka 版本:")
        for i, version in enumerate(versions, 1):
            print(f"{i}) {version}")

        while True:
            try:
                choice = input(f"\n请选择版本号（1-{len(versions)}），直接回车将安装最新版 {versions[-1]}: ").strip()
                if not choice:
                    self.kafka_version = versions[-1]
                    break
                choice = int(choice)
                if 1 <= choice <= len(versions):
                    self.kafka_version = versions[choice-1]
                    break
                print_warning("无效的选择，请重试")
            except ValueError:
                print_warning("请输入有效的数字")

        print_info(f"选择的 Kafka 版本: {self.kafka_version}")

    def create_kafka_user(self) -> None:
        """创建 Kafka 用户"""
        try:
            subprocess.run(["id", "kafka"], capture_output=True, check=True)
        except subprocess.CalledProcessError:
            subprocess.run(["useradd", "-r", "-s", "/sbin/nologin", "kafka"], check=True)

    def download_and_install(self) -> None:
        """下载并安装 Kafka"""
        kafka_tar = f"kafka_{self.scala_version}-{self.kafka_version}.tgz"
        download_url = f"https://downloads.apache.org/kafka/{self.kafka_version}/{kafka_tar}"

        print_info(f"开始下载 Kafka {self.kafka_version}...")
        try:
            response = requests.get(download_url, stream=True)
            response.raise_for_status()
            
            with open(f"/tmp/{kafka_tar}", 'wb') as f:
                for chunk in response.iter_content(chunk_size=8192):
                    f.write(chunk)

            print_info("解压并安装 Kafka...")
            if self.kafka_home.exists():
                shutil.rmtree(self.kafka_home)

            subprocess.run(["tar", "-xzf", f"/tmp/{kafka_tar}", "-C", "/tmp"], check=True)
            shutil.move(f"/tmp/kafka_{self.scala_version}-{self.kafka_version}", self.kafka_home)
            
            # 创建数据和日志目录
            self.kafka_data.mkdir(parents=True, exist_ok=True)
            self.kafka_logs.mkdir(parents=True, exist_ok=True)

            # 设置权限
            for path in [self.kafka_home, self.kafka_data, self.kafka_logs]:
                subprocess.run(["chown", "-R", "kafka:kafka", str(path)], check=True)
                subprocess.run(["chmod", "-R", "755", str(path)], check=True)

        except Exception as e:
            print_error(f"安装失败: {e}")
            sys.exit(1)

    def configure_kafka(self) -> None:
        """配置 Kafka"""
        self.config_file = self.kafka_home / "config" / "server.properties"
        
        # 备份原配置文件
        if self.config_file.exists():
            backup_file = self.config_file.with_suffix(f".backup-{datetime.now():%Y%m%d%H%M%S}")
            shutil.copy2(self.config_file, backup_file)

        config_content = f"""
# Broker 基本配置
broker.id=0
listeners=PLAINTEXT://:9092
advertised.listeners=PLAINTEXT://localhost:9092
num.network.threads=3
num.io.threads=8

# 日志配置
log.dirs={self.kafka_logs}
num.partitions=3
num.recovery.threads.per.data.dir=1
log.retention.hours=168
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000

# Zookeeper 配置
zookeeper.connect=localhost:2181
zookeeper.connection.timeout.ms=18000
"""
        self.config_file.write_text(config_content.strip())
        subprocess.run(["chown", "kafka:kafka", str(self.config_file)], check=True)

    def create_systemd_service(self) -> None:
        """创建系统服务"""
        service_content = f"""[Unit]
Description=Apache Kafka Server
Documentation=http://kafka.apache.org/documentation.html
Requires=zookeeper.service
After=zookeeper.service

[Service]
Type=simple
User=kafka
Environment="JAVA_HOME=/usr/lib/jvm/java"
ExecStart={self.kafka_home}/bin/kafka-server-start.sh {self.config_file}
ExecStop={self.kafka_home}/bin/kafka-server-stop.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
"""
        service_file = Path("/etc/systemd/system/kafka.service")
        service_file.write_text(service_content)
        subprocess.run(["systemctl", "daemon-reload"], check=True)

    def install(self) -> None:
        """执行安装流程"""
        try:
            self.check_root()
            self.check_java()
            self.select_version()
            
            print_info("开始安装 Kafka...")
            self.create_kafka_user()
            self.download_and_install()
            self.configure_kafka()
            self.create_systemd_service()

            print_info("Kafka 安装完成！")
            print_info("请确保 Zookeeper 已经安装并运行")
            print_info("使用以下命令启动 Kafka：")
            print_info("systemctl start kafka")
            print_info("使用以下命令检查状态：")
            print_info("systemctl status kafka")

        except Exception as e:
            print_error(f"安装过程中出现错误: {e}")
            sys.exit(1)

def main():
    installer = KafkaInstaller()
    installer.install()

if __name__ == "__main__":
    main() 