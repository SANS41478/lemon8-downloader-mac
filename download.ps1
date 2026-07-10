# 🍋 Lemon8 Batch Image Downloader (PowerShell)
# Zero dependencies - works on Windows 10/11 out of the box
#
# Usage:
#   .\download.ps1
#   .\download.ps1 -UrlFile urls.txt -OutputDir images -Proxy http://127.0.0.1:7897
#   .\download.ps1 "https://www.lemon8-app.com/@user/123?region=th" -Proxy http://127.0.0.1:7897

param(
    [string]$UrlFile = "urls.txt",
    [string]$OutputDir = "images",
    [string]$Proxy = "",
    [switch]$Help
)

if ($Help) {
    @"
Lemon8 Batch Image Downloader (PowerShell)

Usage:
  .\download.ps1
  .\download.ps1 -UrlFile urls.txt -OutputDir images -Proxy http://127.0.0.1:7897
  .\download.ps1 "https://www.lemon8-app.com/@user/123?region=th" -Proxy http://127.0.0.1:7897

Parameters:
  UrlFile    URLs file or single URL (default: urls.txt)
  OutputDir  Output directory (default: images)
  Proxy      HTTP proxy address, e.g. http://127.0.0.1:7897
"@
    exit 0
}

# ==================== Config ====================
$script:ProxyUri = $null
if ($Proxy) {
    $script:ProxyUri = $Proxy
}

# ==================== HTTP Functions ====================

function Get-WebContent {
    param([string]$Url, [int]$TimeoutSec = 30)

    $params = @{
        Uri = $Url
        UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
        Headers = @{
            "Accept" = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
            "Accept-Language" = "en-US,en;q=0.9,th;q=0.8,zh;q=0.7"
        }
        TimeoutSec = $TimeoutSec
        UseBasicParsing = $true
        MaximumRedirection = 0
        ErrorAction = "Stop"
    }

    if ($script:ProxyUri) {
        $params.Proxy = $script:ProxyUri
    }

    $response = Invoke-WebRequest @params

    # Handle redirect manually (we need to maintain proxy)
    if ($response.StatusCode -eq 301 -or $response.StatusCode -eq 302 -or $response.StatusCode -eq 307 -or $response.StatusCode -eq 308) {
        $loc = $response.Headers["Location"]
        if ($loc) {
            return Get-WebContent -Url $loc -TimeoutSec $TimeoutSec
        }
    }

    return $response.Content
}

function Save-WebFile {
    param([string]$Url, [string]$DestPath, [int]$Retries = 3)

    $params = @{
        Uri = $Url
        OutFile = $DestPath
        UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
        Headers = @{
            "Referer" = "https://www.lemon8-app.com/"
            "Accept" = "image/webp,image/*,*/*;q=0.8"
        }
        TimeoutSec = 60
        UseBasicParsing = $true
        MaximumRedirection = 0
        ErrorAction = "Stop"
    }

    if ($script:ProxyUri) {
        $params.Proxy = $script:ProxyUri
    }

    $lastError = $null
    for ($i = $Retries; $i -ge 0; $i--) {
        try {
            $response = Invoke-WebRequest @params

            # Handle redirect
            if ($response.StatusCode -eq 301 -or $response.StatusCode -eq 302 -or $response.StatusCode -eq 307 -or $response.StatusCode -eq 308) {
                $loc = $response.Headers["Location"]
                if ($loc) {
                    if (Test-Path $DestPath) { Remove-Item $DestPath -Force }
                    return Save-WebFile -Url $loc -DestPath $DestPath -Retries $i
                }
            }

            return $true
        }
        catch {
            $lastError = $_
            if (Test-Path $DestPath) { Remove-Item $DestPath -Force -ErrorAction SilentlyContinue }
            if ($i -gt 0) {
                Write-Host " (retry $i...)" -NoNewline
                Start-Sleep -Seconds 1.5
            }
        }
    }
    throw $lastError
}

# ==================== Helpers ====================

function Safe-FolderName {
    param([string]$Name)
    $invalid = [IO.Path]::GetInvalidFileNameChars()
    $safe = ($Name.ToCharArray() | ForEach-Object { if ($invalid -contains $_) { "_" } else { $_ } }) -join ""
    $safe = $safe -replace '\s+', '_'
    if ($safe.Length -gt 80) { $safe = $safe.Substring(0, 80) }
    return $safe.Trim()
}

function Ensure-Dir {
    param([string]$Dir)
    if (-not (Test-Path $Dir)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
}

# ==================== URL Parser ====================

function Parse-Lemon8Url {
    param([string]$Url)

    if ($Url -match "lemon8-app\.com/@([^/]+)/(\d+)") {
        # Save matches before second regex overwrites $Matches
        $username = $Matches[1]
        $articleId = $Matches[2]
        $region = "th"
        if ($Url -match "region=(\w+)") {
            $region = $Matches[1]
        }
        return @{
            Username   = $username
            ArticleId  = $articleId
            Region     = $region
            Url        = $Url.Trim()
        }
    }
    throw "Cannot parse URL: $Url"
}

# ==================== Data Extractor ====================

function Extract-ArticleData {
    param([string]$Html)

    if ($Html -notmatch '<script type="application/json" data-ttark="__remixContext">([^<]+)</script>') {
        throw "Cannot find __remixContext in page"
    }

    $encoded = $Matches[1]
    $decoded = [Uri]::UnescapeDataString($encoded)
    $data = $decoded | ConvertFrom-Json

    $ld = $data.state.loaderData.'routes/$user_link_name_.$article_id'
    if (-not $ld) {
        throw "Cannot find article route in page data"
    }

    $articleKey = $ld.PSObject.Properties.Name | Where-Object { $_ -like '$ArticleDetail*' } | Select-Object -First 1
    if (-not $articleKey) {
        throw "Cannot find article detail data"
    }

    $article = $ld.$articleKey

    return @{
        Title        = if ($article.title) { $article.title } else { "untitled" }
        Author       = if ($article.author.nickName) { $article.author.nickName } else { "unknown" }
        ArticleClass = if ($article.articleClass) { $article.articleClass } else { "Unknown" }
        ImageList    = if ($article.imageList) { $article.imageList } else { @() }
        LargeImage   = if ($article.largeImage) { $article.largeImage } else { $null }
        Content      = if ($article.content) { $article.content } else { "" }
    }
}

# ==================== CDN URL Helper ====================

function Get-AltCdnUrls {
    param([string]$Url)

    $urls = @($Url)

    if ($Url -match "tiktokcdn\.com") {
        # Alternative CDN domain
        $alt = $Url -replace "p16-lemon8-(sign|cross-sign)-sg\.tiktokcdn\.com", "p16-sign-sg.lemon8cdn.com"
        if ($alt -ne $Url) {
            $urls += $alt
        }
    }

    return $urls | Select-Object -Unique
}

# ==================== Main ====================

function Process-Post {
    param($Url, $OutputRoot)

    $info = Parse-Lemon8Url -Url $Url
    $folderName = Safe-FolderName "$($info.Username)_$($info.ArticleId)"
    $postDir = Join-Path $OutputRoot $folderName

    Write-Host ""
    Write-Host ("=" * 55)
    Write-Host "[$($info.Username)] $($info.ArticleId)"
    Write-Host "   URL: $Url"

    # 1. Fetch page
    Write-Host "   Fetching page..."
    try {
        $html = Get-WebContent -Url $Url
        Write-Host "   OK ($([Math]::Round($html.Length / 1024, 0)) KB)"
    }
    catch {
        Write-Host "   ERROR: $_" -ForegroundColor Red
        if (-not $script:ProxyUri) {
            Write-Host "   HINT: Use -Proxy http://127.0.0.1:PORT if behind firewall" -ForegroundColor Yellow
        }
        return @{ Ok = $false; Error = $_.Exception.Message; Username = $info.Username }
    }

    # 2. Parse data
    try {
        $article = Extract-ArticleData -Html $html
        Write-Host "   Title: $($article.Title)"
        Write-Host "   Type : $($article.ArticleClass)"
    }
    catch {
        Write-Host "   ERROR: $_" -ForegroundColor Red
        return @{ Ok = $false; Error = $_.Exception.Message; Username = $info.Username }
    }

    # 3. Collect image URLs
    $imageUrls = @()

    if ($article.ArticleClass -eq "Gallery" -and $article.ImageList.Count -gt 0) {
        Write-Host "   Images: $($article.ImageList.Count)"
        $idx = 0
        foreach ($img in $article.ImageList) {
            # Try to get hi-res version (remove watermark template)
            $hiRes = $img.url -replace '~tplv-[^/]+-wap-logo[^:]+', '~tplv-sdweummd6v-origin'
            $imageUrls += @{
                Url    = $hiRes
                AltUrls = @($img.url, $hiRes) | Where-Object { $_ } | Select-Object -Unique
                Index  = $idx
                Width  = $img.width
                Height = $img.height
                Type   = "gallery"
            }
            $idx++
        }
    }
    elseif ($article.ArticleClass -eq "Video" -and $article.LargeImage) {
        Write-Host "   Video post, downloading cover"
        $hiRes = $article.LargeImage.url -replace '~tplv-[^/]+-text-logo[^:]+', '~tplv-sdweummd6v-origin'
        $imageUrls += @{
            Url    = $hiRes
            AltUrls = @($article.LargeImage.url, $hiRes) | Where-Object { $_ } | Select-Object -Unique
            Index  = 0
            Width  = $article.LargeImage.width
            Height = $article.LargeImage.height
            Type   = "video_cover"
        }
    }
    else {
        Write-Host "   No images (type: $($article.ArticleClass))"
        return @{ Ok = $true; ImageCount = 0; Username = $info.Username }
    }

    # 4. Create output dir
    Ensure-Dir $postDir

    # 5. Save metadata
    $meta = @{
        url = $Url
        username = $info.Username
        articleId = $info.ArticleId
        title = $article.Title
        author = $article.Author
        articleClass = $article.ArticleClass
        imageCount = $imageUrls.Count
        downloadedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffK")
        proxy = if ($script:ProxyUri) { $script:ProxyUri } else { "direct" }
        images = @($imageUrls | ForEach-Object {
            @{
                index = $_.Index
                width = $_.Width
                height = $_.Height
                url = $_.Url
                filename = "{0:D2}_{1}x{2}.webp" -f ($_.Index + 1), $_.Width, $_.Height
            }
        })
    }
    $meta | ConvertTo-Json -Depth 4 | Out-File -FilePath (Join-Path $postDir "meta.json") -Encoding UTF8

    # 6. Download images
    Write-Host "   Downloading $($imageUrls.Count) images..."
    $downloaded = 0
    $failed = 0

    foreach ($img in $imageUrls) {
        $filename = "{0:D2}_{1}x{2}.webp" -f ($img.Index + 1), $img.Width, $img.Height
        $destPath = Join-Path $postDir $filename

        # Skip existing
        if ((Test-Path $destPath) -and (Get-Item $destPath).Length -gt 0) {
            Write-Host "   SKIP [$($img.Index + 1)/$($imageUrls.Count)] $filename (exists)"
            $downloaded++
            continue
        }

        # Collect candidate URLs (original + hi-res + alt CDN)
        $candidates = @()
        foreach ($baseUrl in $img.AltUrls) {
            $candidates += Get-AltCdnUrls -Url $baseUrl
        }
        $candidates = $candidates | Select-Object -Unique

        $success = $false
        foreach ($candidate in $candidates) {
            try {
                $msg = "   DOWNLOAD [$($img.Index + 1)/$($imageUrls.Count)] $filename"
                if ($candidate -ne $candidates[0]) {
                    $msg += " (alt CDN)"
                }
                Write-Host "$msg ... " -NoNewline
                $null = Save-WebFile -Url $candidate -DestPath $destPath
                $size = [Math]::Round((Get-Item $destPath).Length / 1024, 0)
                Write-Host "OK ($size KB)"
                $downloaded++
                $success = $true
                break
            }
            catch {
                # Try next URL
            }
        }

        if (-not $success) {
            Write-Host "   FAIL [$($img.Index + 1)/$($imageUrls.Count)] $filename" -ForegroundColor Red
            $failed++
        }
    }

    Write-Host "   DONE: $downloaded ok, $failed failed -> $postDir"

    return [PSCustomObject]@{
        Ok = ($failed -eq 0)
        ImageCount = $downloaded
        Failed = $failed
        Folder = $postDir
        Username = $info.Username
        ArticleId = $info.ArticleId
    }
}

# ==================== Entry Point ====================

$OutputRoot = $OutputDir

# Read URLs
$urls = @()
if ($UrlFile.StartsWith("http")) {
    $urls = @($UrlFile)
}
else {
    if (-not (Test-Path $UrlFile)) {
        Write-Host "ERROR: File not found: $UrlFile" -ForegroundColor Red
        exit 1
    }
    $urls = @(Get-Content $UrlFile -Encoding UTF8 | Where-Object { $_ -and -not $_.StartsWith("#") } | ForEach-Object { $_.Trim() })
}

Write-Host "Output : $(if (Test-Path $OutputRoot) { (Resolve-Path $OutputRoot) } else { "$OutputRoot (will create)" })"
Write-Host "Proxy  : $(if ($script:ProxyUri) { $script:ProxyUri } else { 'direct (no proxy)' })"
Write-Host "URLs   : $($urls.Count)"
Write-Host ""

# Process all URLs
$results = @()
for ($i = 0; $i -lt $urls.Count; $i++) {
    try {
        $result = Process-Post -Url $urls[$i] -OutputRoot $OutputRoot
        $results += $result
    }
    catch {
        Write-Host "   FATAL ERROR: $_" -ForegroundColor Red
        $results += @{ Ok = $false; Error = $_.Exception.Message; Url = $urls[$i] }
    }
}

# Summary
Write-Host ""
Write-Host ("=" * 55)
Write-Host "SUMMARY"
$ok = 0; $fail = 0
foreach ($r in $results) {
    if ($r.Ok) { $ok++ } else { $fail++ }
}
$totalImages = 0
foreach ($r in $results) {
    if ($r.Ok) { $totalImages += $r.ImageCount }
}

Write-Host "   Success : $ok posts"
Write-Host "   Failed  : $fail posts"
Write-Host "   Images  : $totalImages"
Write-Host "   Output  : $(if (Test-Path $OutputRoot) { (Resolve-Path $OutputRoot) } else { $OutputRoot })"

if ($fail -gt 0) {
    Write-Host ""
    Write-Host "Failed posts:" -ForegroundColor Red
    foreach ($r in $results) {
        if (-not $r.Ok) {
            Write-Host "   - $($r.Username): $($r.Error)" -ForegroundColor Red
        }
    }
}

if (-not $script:ProxyUri -and $fail -gt 0) {
    Write-Host ""
    Write-Host "HINT: CDN may be blocked. Use proxy:" -ForegroundColor Yellow
    Write-Host "  .\download.ps1 -Proxy http://127.0.0.1:7897" -ForegroundColor Yellow
}
