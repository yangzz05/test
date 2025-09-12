# app.py - Optimized for the provided index.html
import os
import sys
import requests
from flask import Flask, render_template, jsonify, Response, request
import re
import datetime

app = Flask(__name__)

# --- Configuration ---
# 这是唯一需要您确认的地方！
# 请确保这里的地址是您 MosDNS 服务的真实管理地址和端口。
MOSDNS_ADMIN_URL = os.environ.get('MOSDNS_ADMIN_URL', 'http://127.0.0.1:9099')
MOSDNS_METRICS_URL = f"{MOSDNS_ADMIN_URL}/metrics"

def fetch_mosdns_metrics():
    """从 MosDNS /metrics 接口获取原始文本数据"""
    try:
        response = requests.get(MOSDNS_METRICS_URL, timeout=5)
        response.raise_for_status()
        return response.text, None
    except requests.exceptions.RequestException as e:
        error_message = f"无法连接到 MosDNS metrics 接口: {e}"
        print(f"ERROR: {error_message}", file=sys.stderr)
        return None, error_message

def parse_metrics(metrics_text):
    """解析 metrics 文本并格式化为前端需要的 JSON 结构"""
    data = {"caches": {}, "system": {"go_version": "N/A"}}
    
    # 使用更高效的单次遍历来解析所有指标
    patterns = {
        'cache': re.compile(r'mosdns_cache_(\w+)\{tag="([^"]+)"\}\s+([\d.eE+-]+)'),
        'start_time': re.compile(r'^process_start_time_seconds\s+([\d.eE+-]+)'),
        'cpu_time': re.compile(r'^process_cpu_seconds_total\s+([\d.eE+-]+)'),
        'resident_memory': re.compile(r'^process_resident_memory_bytes\s+([\d.eE+-]+)'),
        'heap_idle_memory': re.compile(r'^go_memstats_heap_idle_bytes\s+([\d.eE+-]+)'),
        'threads': re.compile(r'^go_threads\s+(\d+)'),
        'open_fds': re.compile(r'^process_open_fds\s+(\d+)'),
        'go_version': re.compile(r'go_info\{version="([^"]+)"\}')
    }

    for line in metrics_text.split('\n'):
        if (match := patterns['cache'].match(line)):
            metric, tag, value = match.groups()
            if tag not in data["caches"]:
                data["caches"][tag] = {}
            data["caches"][tag][metric] = float(value)
        elif (match := patterns['start_time'].match(line)):
            data["system"]["start_time"] = float(match.group(1))
        elif (match := patterns['cpu_time'].match(line)):
            data["system"]["cpu_time"] = float(match.group(1))
        elif (match := patterns['resident_memory'].match(line)):
            data["system"]["resident_memory"] = float(match.group(1))
        elif (match := patterns['heap_idle_memory'].match(line)):
            data["system"]["heap_idle_memory"] = float(match.group(1))
        elif (match := patterns['threads'].match(line)):
            data["system"]["threads"] = int(match.group(1))
        elif (match := patterns['open_fds'].match(line)):
            data["system"]["open_fds"] = int(match.group(1))
        elif (match := patterns['go_version'].search(line)):
            data["system"]["go_version"] = match.group(1)

    # 计算命中率并格式化数据
    for tag, metrics in data["caches"].items():
        query_total = metrics.get("query_total", 0)
        hit_total = metrics.get("hit_total", 0)
        lazy_hit_total = metrics.get("lazy_hit_total", 0)
        metrics["hit_rate"] = f"{(hit_total / query_total * 100):.2f}%" if query_total > 0 else "0.00%"
        metrics["lazy_hit_rate"] = f"{(lazy_hit_total / query_total * 100):.2f}%" if query_total > 0 else "0.00%"
    
    if "start_time" in data["system"]:
        data["system"]["start_time"] = datetime.datetime.fromtimestamp(data["system"]["start_time"]).strftime('%Y-%m-%d %H:%M:%S')
    if "cpu_time" in data["system"]:
        data["system"]["cpu_time"] = f'{data["system"]["cpu_time"]:.2f} 秒'
    if "resident_memory" in data["system"]:
        data["system"]["resident_memory"] = f'{(data["system"]["resident_memory"] / 1024**2):.2f} MB'
    if "heap_idle_memory" in data["system"]:
        data["system"]["heap_idle_memory"] = f'{(data["system"]["heap_idle_memory"] / 1024**2):.2f} MB'
        
    return data

# --- Flask 路由 ---

@app.route('/')
def index():
    """提供主页面"""
    return render_template('index.html')

@app.route('/api/mosdns_status')
def get_mosdns_status():
    """为前端提供格式化后的 JSON 监控数据"""
    metrics_text, error = fetch_mosdns_metrics()
    if error:
        return jsonify({"error": error}), 502 # 502 Bad Gateway is more appropriate
    data = parse_metrics(metrics_text)
    return jsonify(data)

@app.route('/plugins/<path:subpath>', methods=['GET', 'POST'])
def proxy_plugins_request(subpath):
    """
    代理所有对 /plugins/ 路径的请求，以处理前端的控制按钮操作。
    例如，前端请求 /plugins/my_fakeiplist/save -> 后端请求 http://<mosdns>/plugins/my_fakeiplist/save
    """
    target_url = f"{MOSDNS_ADMIN_URL}/plugins/{subpath}"
    print(f"DEBUG: Proxying request to -> {target_url}", file=sys.stderr)
    
    try:
        # 前端所有按钮都是 GET 请求，但为了健壮性，我们依然可以处理 POST
        if request.method == 'POST':
            resp = requests.post(target_url, timeout=10)
        else:
            resp = requests.get(target_url, timeout=10)
        
        resp.raise_for_status()

        # 将 MosDNS 的响应原样返回给浏览器
        content_type = resp.headers.get('Content-Type', 'text/plain; charset=utf-8')
        return Response(resp.text, status=resp.status_code, content_type=content_type)

    except requests.exceptions.RequestException as e:
        error_message = f"代理请求到 MosDNS 失败 ({target_url}): {e}"
        print(f"ERROR: {error_message}", file=sys.stderr)
        return Response(f"请求 MosDNS 失败: {e}", status=502, mimetype='text/plain')

if __name__ == '__main__':
    # 从环境变量获取端口，默认为 5001
    port = int(os.environ.get('FLASK_PORT', 5001)) 
    # 在生产环境中，建议将 debug 设置为 False
    app.run(host='0.0.0.0', port=port, debug=False)
