package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"text/template"
	"time"
)

const (
	defaultPort = 5001
)

// 配置
var (
	mosdnsAdminURL   = getEnv("MOSDNS_ADMIN_URL", "http://127.0.0.1:9099")
	mosdnsMetricsURL = mosdnsAdminURL + "/metrics"

	listPaths = map[string]string{
		"blocklist": "/etc/mosdns/rule/blocklist.txt",
		"whitelist": "/etc/mosdns/rule/whitelist.txt",
		"blockips":  "/etc/mosdns/rule/blockips.txt",
	}
)

// 响应结构体
type ListResponse struct {
	Content string `json:"content"`
	Error   string `json:"error,omitempty"`
}

type ActionResponse struct {
	Success bool   `json:"success"`
	Message string `json:"message,omitempty"`
	Error   string `json:"error,omitempty"`
}

type MetricsData struct {
	Caches map[string]map[string]interface{} `json:"caches"`
	System map[string]interface{}            `json:"system"`
}

// 全局变量存储HTML模板
var htmlTemplate *template.Template

func init() {
	// 读取index.html文件作为模板
	templateBytes, err := os.ReadFile("/opt/mosdnsui/index.html")
	if err != nil {
		log.Fatal("Failed to read index.html:", err)
	}
	templateStr := string(templateBytes)

	htmlTemplate, err = template.New("mosdns-ui").Parse(templateStr)
	if err != nil {
		log.Fatal("Failed to parse template:", err)
	}
}

func main() {
	port := getPort()

	// 设置路由 - 完全复刻app.py的路由
	http.HandleFunc("/", handleIndex)
	http.HandleFunc("/api/mosdns_status", handleMosDNSStatus)
	http.HandleFunc("/plugins/", handlePluginsProxy)
	http.HandleFunc("/api/list/", handleList)
	http.HandleFunc("/api/restart_mosdns", handleRestartMosDNS)

	// 静态文件服务
	http.Handle("/static/", http.StripPrefix("/static/", http.FileServer(http.Dir("/opt/mosdnsui/static"))))

	log.Printf("🚀 启动MosDNS UI Go服务器，端口: %d", port)
	log.Printf("MosDNS管理地址: %s", mosdnsAdminURL)

	server := &http.Server{
		Addr:         fmt.Sprintf(":%d", port),
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	log.Fatal(server.ListenAndServe())
}

func getPort() int {
	if portStr := os.Getenv("WEB_PORT"); portStr != "" {
		if port, err := strconv.Atoi(portStr); err == nil {
			return port
		}
	}
	return defaultPort
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

// 复刻 app.py 的 index() 函数
func handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	htmlTemplate.Execute(w, nil)
}

// 复刻 app.py 的 get_mosdns_status() 函数
func handleMosDNSStatus(w http.ResponseWriter, r *http.Request) {
	metricsText, err := fetchMosDNSMetrics()
	if err != nil {
		errorResponse := map[string]string{"error": err.Error()}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadGateway)
		json.NewEncoder(w).Encode(errorResponse)
		return
	}

	data := parseMetrics(metricsText)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(data)
}

// 复刻 app.py 的 fetch_mosdns_metrics() 函数
func fetchMosDNSMetrics() (string, error) {
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(mosdnsMetricsURL)
	if err != nil {
		return "", fmt.Errorf("无法连接到 MosDNS metrics 接口: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("MosDNS metrics 返回状态: %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("读取响应失败: %v", err)
	}

	return string(body), nil
}

// 复刻 app.py 的 parse_metrics() 函数
func parseMetrics(metricsText string) *MetricsData {
	data := &MetricsData{
		Caches: make(map[string]map[string]interface{}),
		System: map[string]interface{}{"go_version": "N/A"},
	}

	// 编译正则表达式 - 复刻app.py的patterns
	cachePattern := regexp.MustCompile(`mosdns_cache_(\w+)\{tag="([^"]+)"\}\s+([\d.eE+-]+)`)
	startTimePattern := regexp.MustCompile(`^process_start_time_seconds\s+([\d.eE+-]+)`)
	cpuTimePattern := regexp.MustCompile(`^process_cpu_seconds_total\s+([\d.eE+-]+)`)
	residentMemoryPattern := regexp.MustCompile(`^process_resident_memory_bytes\s+([\d.eE+-]+)`)
	heapIdleMemoryPattern := regexp.MustCompile(`^go_memstats_heap_idle_bytes\s+([\d.eE+-]+)`)
	threadsPattern := regexp.MustCompile(`^go_threads\s+(\d+)`)
	openFdsPattern := regexp.MustCompile(`^process_open_fds\s+(\d+)`)
	goVersionPattern := regexp.MustCompile(`go_info\{version="([^"]+)"\}`)

	lines := strings.Split(metricsText, "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// 解析缓存指标 - 复刻app.py的cache匹配逻辑
		if matches := cachePattern.FindStringSubmatch(line); matches != nil {
			metric := matches[1]
			tag := matches[2]
			value, _ := strconv.ParseFloat(matches[3], 64)

			if data.Caches[tag] == nil {
				data.Caches[tag] = make(map[string]interface{})
			}
			data.Caches[tag][metric] = value
		} else if matches := startTimePattern.FindStringSubmatch(line); matches != nil {
			if value, err := strconv.ParseFloat(matches[1], 64); err == nil {
				data.System["start_time"] = value
			}
		} else if matches := cpuTimePattern.FindStringSubmatch(line); matches != nil {
			if value, err := strconv.ParseFloat(matches[1], 64); err == nil {
				data.System["cpu_time"] = value
			}
		} else if matches := residentMemoryPattern.FindStringSubmatch(line); matches != nil {
			if value, err := strconv.ParseFloat(matches[1], 64); err == nil {
				data.System["resident_memory"] = value
			}
		} else if matches := heapIdleMemoryPattern.FindStringSubmatch(line); matches != nil {
			if value, err := strconv.ParseFloat(matches[1], 64); err == nil {
				data.System["heap_idle_memory"] = value
			}
		} else if matches := threadsPattern.FindStringSubmatch(line); matches != nil {
			if value, err := strconv.Atoi(matches[1]); err == nil {
				data.System["threads"] = value
			}
		} else if matches := openFdsPattern.FindStringSubmatch(line); matches != nil {
			if value, err := strconv.Atoi(matches[1]); err == nil {
				data.System["open_fds"] = value
			}
		} else if matches := goVersionPattern.FindStringSubmatch(line); matches != nil {
			data.System["go_version"] = matches[1]
		}
	}

	// 计算命中率并格式化数据 - 复刻app.py的格式化逻辑
	for _, metrics := range data.Caches {
		queryTotal := getFloatValue(metrics, "query_total")
		hitTotal := getFloatValue(metrics, "hit_total")
		lazyHitTotal := getFloatValue(metrics, "lazy_hit_total")

		if queryTotal > 0 {
			metrics["hit_rate"] = fmt.Sprintf("%.2f%%", hitTotal/queryTotal*100)
			metrics["lazy_hit_rate"] = fmt.Sprintf("%.2f%%", lazyHitTotal/queryTotal*100)
		} else {
			metrics["hit_rate"] = "0.00%"
			metrics["lazy_hit_rate"] = "0.00%"
		}
	}

	// 格式化系统信息 - 复刻app.py的格式化逻辑
	if startTime, ok := data.System["start_time"].(float64); ok {
		data.System["start_time"] = time.Unix(int64(startTime), 0).Format("2006-01-02 15:04:05")
	}
	if cpuTime, ok := data.System["cpu_time"].(float64); ok {
		data.System["cpu_time"] = fmt.Sprintf("%.2f 秒", cpuTime)
	}
	if residentMemory, ok := data.System["resident_memory"].(float64); ok {
		data.System["resident_memory"] = fmt.Sprintf("%.2f MB", residentMemory/1024/1024)
	}
	if heapIdleMemory, ok := data.System["heap_idle_memory"].(float64); ok {
		data.System["heap_idle_memory"] = fmt.Sprintf("%.2f MB", heapIdleMemory/1024/1024)
	}

	return data
}

func getFloatValue(metrics map[string]interface{}, key string) float64 {
	if value, ok := metrics[key]; ok {
		if floatValue, ok := value.(float64); ok {
			return floatValue
		}
	}
	return 0
}

// 复刻 app.py 的 proxy_plugins_request() 函数
func handlePluginsProxy(w http.ResponseWriter, r *http.Request) {
	subpath := strings.TrimPrefix(r.URL.Path, "/plugins/")
	targetURL := fmt.Sprintf("%s/plugins/%s", mosdnsAdminURL, subpath)

	log.Printf("DEBUG: Proxying request to -> %s", targetURL)

	// 创建请求
	var req *http.Request
	var err error

	if r.Method == "POST" {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "Failed to read request body", http.StatusBadRequest)
			return
		}
		req, err = http.NewRequest("POST", targetURL, strings.NewReader(string(body)))
	} else {
		req, err = http.NewRequest("GET", targetURL, nil)
	}

	if err != nil {
		http.Error(w, "Failed to create request", http.StatusInternalServerError)
		return
	}

	// 设置超时
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		errorMessage := fmt.Sprintf("代理请求到 MosDNS 失败 (%s): %v", targetURL, err)
		log.Printf("ERROR: %s", errorMessage)
		http.Error(w, fmt.Sprintf("请求 MosDNS 失败: %v", err), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	// 复制响应
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, "Failed to read response", http.StatusInternalServerError)
		return
	}

	// 设置响应头
	contentType := resp.Header.Get("Content-Type")
	if contentType == "" {
		contentType = "text/plain; charset=utf-8"
	}
	w.Header().Set("Content-Type", contentType)
	w.WriteHeader(resp.StatusCode)
	w.Write(body)
}

// 复刻 app.py 的 get_list() 和 save_list() 函数
func handleList(w http.ResponseWriter, r *http.Request) {
	pathParts := strings.Split(r.URL.Path, "/")
	if len(pathParts) < 4 {
		http.Error(w, "Invalid list type", http.StatusBadRequest)
		return
	}

	listType := pathParts[3]

	switch r.Method {
	case "GET":
		handleGetList(w, listType)
	case "POST":
		handleSaveList(w, r, listType)
	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

func handleGetList(w http.ResponseWriter, listType string) {
	path := getListPath(listType)
	if path == "" {
		http.Error(w, "名单类型错误", http.StatusBadRequest)
		return
	}

	content, err := os.ReadFile(path)
	if err != nil {
		response := ListResponse{Error: err.Error()}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(response)
		return
	}

	response := ListResponse{Content: string(content)}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

func handleSaveList(w http.ResponseWriter, r *http.Request, listType string) {
	path := getListPath(listType)
	if path == "" {
		http.Error(w, "名单类型错误", http.StatusBadRequest)
		return
	}

	// 解析请求体
	var requestData struct {
		Content string `json:"content"`
	}

	if err := json.NewDecoder(r.Body).Decode(&requestData); err != nil {
		http.Error(w, "Invalid JSON", http.StatusBadRequest)
		return
	}

	// 保存文件
	err := os.WriteFile(path, []byte(requestData.Content), 0644)
	if err != nil {
		response := ActionResponse{Success: false, Error: err.Error()}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(response)
		return
	}

	// 重启MosDNS - 复刻app.py的os.system('supervisorctl restart mosdns')
	go restartMosDNS()

	response := ActionResponse{Success: true}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

// 复刻 app.py 的 restart_mosdns() 函数
func handleRestartMosDNS(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	err := restartMosDNS()
	if err != nil {
		response := ActionResponse{Success: false, Error: err.Error()}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(response)
		return
	}

	response := ActionResponse{Success: true, Message: "重启命令已成功发送"}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

// 复刻 app.py 的 get_list_path() 函数
func getListPath(listType string) string {
	return listPaths[listType]
}

func restartMosDNS() error {
	cmd := exec.Command("supervisorctl", "restart", "mosdns")
	return cmd.Run()
}
