#!/bin/bash
# 启动面试资料本地阅读器

cd "$(dirname "$0")"

# 检查端口
PORT=8899
while lsof -i :$PORT > /dev/null 2>&1; do
    PORT=$((PORT + 1))
done

echo "🚀 启动面试资料阅读器"
echo "📁 目录: $(pwd)"
echo "🌐 端口: $PORT"
echo ""
echo "📖 在浏览器打开: http://localhost:$PORT/阅读器.html"
echo ""
echo "⏹️  按 Ctrl+C 停止服务"
echo ""

# 3 秒后自动打开浏览器
(sleep 2 && open "http://localhost:$PORT/阅读器.html") &

# 启动 Python HTTP 服务
python3 -m http.server $PORT
