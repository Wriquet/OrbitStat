# OrbitStat

轻量级原生 macOS 菜单栏系统与电源监控工具（SwiftUI + AppKit），专为 Apple Silicon 打造，支持 macOS 26+ 官方 **Liquid Glass（液态玻璃）** 视觉风格（向下兼容 macOS 14+）。

A lightweight, native SwiftUI + AppKit macOS menu bar monitor for Apple Silicon (macOS 14+, native macOS 26+ Liquid Glass `.glassEffect(.regular)` with soft floating drop shadows), featuring ~15 MB idle memory footprint, ~0% idle CPU usage, and zero root privileges required.

---

## 核心特性 · Features

- **超轻量架构 / Ultra-Lightweight**: 纯原生 Swift 实现，零 Electron / WebView 依赖；面板采用按需懒加载与关闭即释放策略，后台常驻物理内存占用约 **15 MB**，空闲 CPU **~0%**。
- **官方液态玻璃界面 / Native Liquid Glass UI**: 基于 macOS 26+ 官方 `.glassEffect(.regular)` 磨砂液态玻璃外框、双层柔和悬浮投影、独立 `.glassEffect(.regular)` 悬浮模块卡片、原生 `Capsule` 胶囊控件与系统 SF Symbols 图标；macOS 14–15 自动回退至原生 `.regularMaterial` / `.ultraThinMaterial`。
- **免 Root 硬件采样 / Non-Root Hardware Telemetry**: 直接调用 IOKit HID/SMC、Mach `host_processor_info` / `host_statistics64`、`libproc` 与 `sysctl`，无需 `sudo` 或外部命令行子进程。

### 系统页 · System Tab
- **CPU 温度**: 读取 Apple Silicon IOHID 温度传感器（带 AppleSMC 回退），支持 °C / °F 切换与温度状态标签（正常 / 温热 / 偏高）。
- **CPU 占用**: 实时总占用率、60 采样点趋势曲线、用户 / 系统 / 空闲细分与 P-Core / E-Core 逐核占用条，一键跳转活动监视器（Activity Monitor）。
- **内存监控**: 对齐活动监视器口径的已用 / 总内存、内存压力等级（正常 / 注意 / 严重）、已压缩 / 缓存 / 交换空间、实时趋势曲线，以及可一键收起/展开的应用内存排行（按最外层 `.app` 聚合子进程并显示本地化名称与图标，支持右键在访达中显示或复制进程信息）。
- **运行时间**: 底部胶囊实时展示系统已运行时长（Uptime）。

### 电源页 · Power Tab
- **电池状态**: 实时电量、充放电状态、60 采样点电量曲线，以及基于进程 CPU 时间与唤醒统计的「显著耗能」应用列表。
- **电池温度与健康度**: 读取电池实时温度、最大容量健康度百分比（对齐 macOS 系统设置口径）与电池循环次数。
- **系统功耗**: 通过 AppleSMC `PSTR` / IOKit `PowerTelemetryData` 采集整机实时功率（W）及动态上限趋势图。
- **电源适配器**: 显示已连接适配器的额定最大功率与实时输入功率（未插电时自动优雅降级显示）。

### 设置与菜单栏 · Settings & Menu Bar
- 可配置刷新间隔（`1s` / `2s` / `3s` / `5s`）、温度单位（`°C` / `°F`）、内存列表显示数量（`5` / `10` / `15` / `20`）。
- 支持在菜单栏图标旁按需实时显示：CPU 占用、CPU 温度、电池电量、系统功耗。
- 支持模块化显示筛选（右上角筛选按钮）与开机自动启动（`SMAppService`）。

---

## 环境要求 · Requirements

- macOS 14.0+ (Sonoma / Sequoia / Tahoe)
- Apple Silicon (M1 / M2 / M3 / M4+)
- Swift 5.10+ / Xcode Command Line Tools

---

## 构建与运行 · Build & Run

```bash
# 克隆仓库 / Clone repository
git clone https://github.com/Wriquet/OrbitStat.git
cd OrbitStat

# 编译（严格模式）/ Build
swift build -Xswiftc -warnings-as-errors

# 运行单元测试 / Run unit tests
swift test

# 打包并签名 OrbitStat.app / Package & ad-hoc sign .app bundle
./scripts/build_app.sh

# 启动应用 / Launch menu bar app
open build/OrbitStat.app
```

---

## 项目结构 · Project Structure

```text
OrbitStat/
├── Package.swift
├── scripts/
│   └── build_app.sh                      # Release 构建、原生图标生成与签名脚本
├── Sources/OrbitStat/
│   ├── App/OrbitStatApp.swift            # 菜单栏入口、FloatingGlassPanel 与快照钩子
│   ├── Models/MetricsModels.swift        # 遥测数据模型、协议、配置与格式化工具
│   ├── Services/
│   │   ├── AppleSiliconThermal.swift     # Apple Silicon IOHID / AppleSMC 温度读取
│   │   ├── SystemMonitor.swift           # CPU、内存、进程聚合与运行时间采集
│   │   └── PowerMonitor.swift            # 电池、整机功耗、适配器与耗能应用采集
│   ├── State/MonitorStore.swift          # 状态管理、60 点历史缓存与轻量图标缓存
│   └── Views/
│       ├── RootPopoverView.swift         # 官方 .regular 液态玻璃主容器、悬浮阴影与导航栏
│       ├── SystemTabView.swift           # 系统监控页
│       ├── PowerTabView.swift            # 电源监控页
│       ├── SettingsView.swift            # 设置页
│       └── Components/SharedComponents.swift  # 通用液态玻璃组件与图表
└── Tests/OrbitStatTests/
    ├── SystemMonitorTests.swift
    └── PowerMonitorTests.swift
```

---

## License

[MIT](LICENSE) © 2026 Wriquet
