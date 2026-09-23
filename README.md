<div align="center">

# 闲着 · Xianzhe

把当前应用的图标抠成有厚度的实体，丢到桌面上给它打光。

蜡烛用着用着会烧完，太阳四分钟走完一天。

[![Release](https://img.shields.io/github/v/release/zhuangli410-commits/xianzhe?style=flat-square&label=release&color=D4A24E)](https://github.com/zhuangli410-commits/xianzhe/releases)
![platform](https://img.shields.io/badge/platform-macOS_14%2B_arm64-000000?style=flat-square&logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-F05138?style=flat-square&logo=swift&logoColor=white)
![Metal](https://img.shields.io/badge/Metal_光线求交-000000?style=flat-square&logo=apple&logoColor=white)

<img src="outputs/闲着-1.0-三维布光.png" width="680" alt="摄影棚中的三维布光" />

</div>

---


## 玩什么

- 在模拟桌面拖动图标位置，调整大小、转速、抠图、材质、厚度与颜色。
- 在摄影棚内切换“画面与材质 / 三维布光”，最多放四盏灯。拖动灯具改变位置，按住 Option 拖动改变高度；每盏灯可单独调亮度和颜色。
- 手电筒和摄影灯有方向。按住“调向”按钮拖动，灯具朝向、照明范围和影子一起改变。手电筒、蜡烛等是几何模型，不是 emoji 贴图。
- 蜡烛会闪烁、逐渐变短并燃尽；火柴更快燃尽，可重新点燃。太阳在四分钟的**演示周期**中东升西落，夜间换成较暗的月亮。这是玩具时间，不是现实天文时间。
- 桌面悬浮图标与摄影棚同步。自动画质会依据绘制耗时、内存压力、温度和低电量状态退让；硬件支持且只有一盏灯时可使用 Metal 光线求交计算影子。
- 应用显示在程序坞，也保留菜单栏入口。内容展厅已从 1.0 删除。

## 下载与运行

下载 [Mac 安装包](https://github.com/zhuangli410-commits/xianzhe/releases/download/v1.0.0/xianzhe-1.0.0-macOS-arm64.zip)（[发布页与校验文件](https://github.com/zhuangli410-commits/xianzhe/releases/tag/v1.0.0)），解压后打开“闲着.app”。本地构建需 macOS 和 Xcode Command Line Tools：

```sh
./outputs/IdleIcon/build.sh
open outputs/闲着.app
```

目标为 Apple Silicon（arm64）、macOS 14 及以上。本机在 Apple M5 / 32 GiB 上做了短时功能与 GPU 检查；其他机型、长时间使用、多显示器和真实睡眠尚未验证。应用只有本地临时签名，未做 Apple 开发者签名与公证；在其他 Mac 上安装可能受到系统安全检查限制。

## 当前边界

光源行为是适合观看的实时近似，不是完整路径追踪或天文模拟。桌面影子落在软件自己的虚拟承影面上，不读取其他应用窗口的三维形状。删除内容展厅后，1.0 **没有主动填满空余内存的玩法**；“尽可能利用闲置内存”仍是后续目标，不能把当前 GPU 绘制或旧版内存实验说成已实现几十 GB 的物理内存占用。

## 开发与检查

```sh
./outputs/IdleIcon/test.sh
./outputs/IdleIcon/test-appearance.sh
./outputs/IdleIcon/test-performance.sh
./outputs/IdleIcon/test-ray.sh
```

检查记录见[开发进度](outputs/开发进度.md)与[测试记录](outputs/IdleIcon/测试记录.md)。[第一版操作手册](outputs/第一版开发操作手册.md)保留需求与阶段边界；本机可用 `outputs/打开逐项批注.command` 打开分区批注页，批注只写到本机，不在 GitHub 发布。

---

<div align="center">
<sub><a href="https://github.com/zhuangli410-commits">李卓扬 Aktive</a> · <a href="https://li-zhuoyang-ai-product-builder.zhuangli410.chatgpt.site">作品集</a> · 有想知道的事，<a href="https://gongfu.youjixiezuo.top/#ask">问 SG Agent</a></sub>
</div>
