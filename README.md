# 🍋 Lemon8 批量图片下载器

从 Lemon8 帖子链接批量提取并下载高清图片。Windows / macOS 双平台，零额外依赖。

---

## 分发清单（发给别人时需包含的文件）

```
lemon8-downloader/
├── download.bat          ← Windows 双击运行
├── download.command      ← macOS 双击运行
├── download.sh           ← macOS/Linux 核心脚本
├── download.ps1          ← Windows 核心脚本（PowerShell）
├── urls.example.txt      ← 链接模板
└── README.md             ← 本文档
```

---

## 平台选择

| 平台 | 启动方式 | 核心脚本 | 依赖 |
|------|---------|---------|------|
| **Windows** | 双击 `download.bat` | `download.ps1` | 无（系统自带 PowerShell） |
| **macOS** | 双击 `download.command` | `download.sh` | 无（系统自带 curl + python3） |

---

## macOS 使用指南

### 第一步：编辑链接

将 `urls.example.txt` **复制**为 `urls.txt`，把 Lemon8 帖子链接粘贴进去：

```
# 注释行以 # 开头
https://www.lemon8-app.com/@username/123456789?region=th
https://www.lemon8-app.com/@username/987654321?region=th
```

### 第二步：配置代理（可选）

编辑 `download.command`，修改顶部的两个设置：

```bash
USE_PROXY=1               # 改成 1 开启代理
PROXY_PORT=7897           # 改成你的代理端口
```

| 代理软件 | 默认 HTTP 端口 |
|---------|--------------|
| Clash / Clash Verge | 7890 |
| V2Ray / V2RayX | 10809 |
| Shadowsocks | 1080 |
| Sing-Box | 2080 |
| Surge (Mac) | 6152 |

如果不使用代理，保持 `USE_PROXY=0` 即可。

### 第三步：首次运行（给文件授权）

从网盘 / 微信 / 压缩包传到 Mac 后，文件会失去执行权限。打开 **终端 (Terminal)**，进入文件夹，运行：

```bash
cd ~/Downloads/lemon8-downloader    # 换成你实际的文件夹路径
chmod +x download.command download.sh
```

> 这一步只需做一次。之后双击 `download.command` 就能直接运行了。
>
> 如果双击后还提示"无法验证开发者"：**右键（或按住 Control 点按）** → **"打开"**，在弹出的确认框中点 **"打开"** 即可。

### 第四步：双击运行

在 Finder 中找到 `download.command`，**双击**打开。

### 命令行用法（高级）

```bash
# 使用代理
bash download.sh -f urls.txt -o images -p http://127.0.0.1:7897

# 下载单个帖子
bash download.sh "https://www.lemon8-app.com/@user/123?region=th" -p http://127.0.0.1:7897
```

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `-f, --file` | 链接文件或单个 URL | `urls.txt` |
| `-o, --output` | 输出目录 | `images` |
| `-p, --proxy` | HTTP 代理地址 | 无 |
| `-h, --help` | 显示帮助 | |

---

## Windows 使用指南

### 第一步：编辑链接

将 `urls.example.txt` **重命名**为 `urls.txt`，把 Lemon8 帖子链接粘贴进去。

### 第二步：设置代理端口

右键 `download.bat` → **编辑**，修改第 9 行的端口号为你代理软件的实际端口：

```batch
set PROXY_PORT=7897    ← 改成你的端口
```

### 第三步：启动代理 + 双击运行

1. 确保代理软件已开启（系统代理或 TUN 模式）
2. 双击 `download.bat`

---

## 日常使用

1. 把新链接追加到 `urls.txt`，一行一个
2. Windows 双击 `download.bat` / macOS 双击 `download.command`
3. 已下载的图片自动跳过，不会重复下载

---

## 输出结构

```
images/
└── <username>_<articleId>/
    ├── meta.json              # 元数据（标题、作者、原链接）
    ├── 01_640x853.webp        # 图片
    ├── 02_640x853.webp
    └── ...
```

每个 `meta.json` 内容：

```json
{
  "url": "原始帖子链接",
  "username": "博主用户名",
  "articleId": "帖子ID",
  "title": "帖子标题",
  "articleClass": "Gallery / Video",
  "imageCount": 5,
  "downloadedAt": "2026-07-09T14:30:00.000Z",
  "images": [
    { "index": 0, "width": 640, "height": 853, "filename": "01_640x853.webp" }
  ]
}
```

---

## 原理

```
Lemon8 帖子 URL
    ↓  抓取页面 HTML
解析 <script data-ttark="__remixContext"> 中的 JSON
    ↓  提取 imageList / largeImage
通过代理下载 → 保存为 .webp
```

- **Gallery 帖子**：下载所有图片
- **Video 帖子**：下载封面图
- 无需浏览器、无需登录

---

## 常见问题

### Q: macOS 双击提示 "没有权限" / "无法打开"

这是 macOS 安全机制导致的，需要两步：

**第一步：给文件加执行权限（终端运行一次即可）**
```bash
cd ~/Downloads/lemon8-downloader    # 换成你的实际路径
chmod +x download.command download.sh
```

**第二步：绕过 Gatekeeper**
- 方法 A（推荐）：直接在终端跑 `bash download.sh`，完全不需要双击
- 方法 B：右键（或按住 Control 点按）`download.command` → **"打开"** → 确认框中点 **"打开"**

> 原因：从网盘/微信/压缩包传到 Mac 后，可执行权限会丢失。右键→打开可以绕过 Gatekeeper 的开发者验证，但前提是文件已有执行权限（第一步）。

### Q: macOS 提示 "python3 is required"

打开 **终端 (Terminal)**，运行：
```bash
xcode-select --install
```
按照提示安装命令行工具（约 1 分钟）。

### Q: 双击 `download.command` 没反应 / 一闪而过

右键 `download.command` → **打开方式** → **终端 (Terminal)**，取消勾选 "总是用此方式打开"（可选）。

### Q: Windows 双击 bat 提示 "urls.txt has no links"

首次使用需要把 `urls.example.txt` 重命名为 `urls.txt`，并填入链接。

### Q: 提示连接失败 / 超时

1. 确认代理软件正在运行（开全局模式或 TUN 模式）
2. 核对代理端口号是否正确
3. 尝试切换代理节点
4. 如果不使用代理，尝试在命令行加 `-p` 参数指定

### Q: 需要安装什么？

**不需要。** Windows 自带 PowerShell，macOS 自带 curl 和 python3。
