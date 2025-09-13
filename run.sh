#!/bin/sh

# 检查是否已经构建了镜像
if ! docker image inspect mosdnsui:alpine > /dev/null 2>&1; then
  echo "镜像不存在，请先运行 ./build.sh 构建镜像"
  exit 1
fi

# 创建规则目录（如果不存在）
mkdir -p ./rule

# 运行容器
echo "启动 MosDNS UI 容器..."
docker run -d \
  --name mosdnsui \
  -p 5001:5001 \
  -e MOSDNS_ADMIN_URL="${MOSDNS_ADMIN_URL:-http://host.docker.internal:9099}" \
  -v "$(pwd)/rule:/etc/mosdns/rule" \
  --restart unless-stopped \
  mosdnsui:alpine

echo "容器已启动！"
echo "访问 http://localhost:5001 查看 MosDNS UI"