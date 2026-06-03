# aitool_standalone

GitHub Actions 自動打包離線工具集。本地不需要任何 `npm install` / 環境設定，所有建置都在 CI 上完成。

## 套件清單

| 套件 | 說明 | 類型 |
|------|------|------|
| [rg](https://github.com/BurntSushi/ripgrep) | 快速全文搜尋工具（ripgrep），musl 靜態二進位 | binary |
| [rtk](https://github.com/rtk-ai/rtk) | AI CLI 工具，musl 靜態二進位 | binary |
| [opencode](https://github.com/anomalyco/opencode) | AI coding agent CLI，GitHub Release 二進位 | binary |
| [node](https://github.com/nodejs/node) | Node.js LTS runtime，完整 Linux x64 runtime | custom |
| [qmd](https://github.com/tobi/qmd) | 本地 CLI 語意搜尋引擎（docs / notes / code） | custom |
| [playwright](https://github.com/microsoft/playwright) | 含瀏覽器的獨立 Playwright 執行環境 | custom |

## 使用方式

### 自動建置（每週日 00:00 UTC）

Scheduled workflow 會自動建置所有套件，並將成品上傳為 GitHub Actions artifact（保留 90 天）。

### 套件 bundle 使用方式

解壓縮 `aitool_standalone-<YYYYMMDD>.tar.gz` 後：

- `bash` / `sh`：在 bundle 根目錄執行 `source setup.sh`
- `csh` / `tcsh`：優先先 `cd` 到 bundle 根目錄再執行 `source setup.csh`
- 若要從其他目錄 `source`，先設定 `AITOOL_BUNDLE_DIR=/path/to/bundle`

## 新增套件

編輯 `packages.yml`：

```yaml
packages:
  # 標準類型（binary / node / go / python / rust）
  - name: my-tool
    type: binary
    repo: owner/repo
    asset_pattern: my-tool-{VERSION}-linux-amd64.tar.gz

  # GitHub Release 二進位（不含版本號的檔名）
  - name: opencode
    type: binary
    repo: anomalyco/opencode
    asset_pattern: opencode-linux-x64.tar.gz

  # 完整 runtime 的自訂腳本
  - name: node
    type: custom
    script: scripts/build-node.sh

  # 自訂腳本
  - name: my-tool
    type: custom
    script: scripts/build-my-tool.sh
```

**標準類型欄位**

| 欄位 | 說明 |
|------|------|
| `type` | `binary` / `node` / `go` / `python` / `rust` |
| `repo` | GitHub `owner/repo` |
| `asset_pattern` | binary 類型的 release asset 檔名，支援 `{VERSION}` 佔位符 |
| `version` | 指定版本，省略則抓 latest release |

**自訂腳本規範**

- 輸出成品放在 `dist/` 目錄
- 必須在 `dist/BUILD_INFO.txt` 寫入版本資訊：
  ```
  name=<套件名>
  version=<版本號>
  license=<SPDX 識別符>
  ```

## 專案結構

```
aitool_standalone/
├── packages.yml                    # 套件定義
├── scripts/
│   ├── build-node.sh               # Node.js 自訂建置
│   ├── build.sh                    # 標準類型通用建置腳本
│   ├── build-playwright.sh         # Playwright 自訂建置
│   └── build-qmd.sh                # qmd 自訂建置
└── .github/workflows/
  └── scheduled-build.yml         # 每週自動建置全部套件
```

## Artifacts

每次建置後可在 Actions run 頁面下載：

- `<name>-standalone-x86_64-linux` — 各套件獨立成品
- `aitool_standalone-bundle-<YYYYMMDD>.tar.gz` — 全套件合併包（僅 scheduled build）

bundle 內同時提供 `setup.sh` 與 `setup.csh`，分別給 `bash` / `sh` 與 `csh` / `tcsh` 使用。
`setup.csh` 會優先使用目前目錄，若不在 bundle 根目錄，請先設定 `AITOOL_BUNDLE_DIR`。

Build summary 會列出本次打包的所有套件與版本。
