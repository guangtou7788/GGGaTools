# GGGaTools

iOS App 内悬浮按钮注入测试，版本 0.1.0。

黄色「嘎」按钮支持拖动，点击显示测试信息。用于先确认 dylib 加载和 UIKit 悬浮交互，再接入门店查询。

## 快速开始

1. 将本目录内容上传至 GitHub 仓库根目录，包含 `.github/workflows/build.yml`。
2. 打开 **Actions → Build GGGaTools**，等待成功后下载 **GGGaTools-iOS-arm64**。
3. 解压取得 `GGGaTools.dylib`，通过轻松签注入目标 IPA，重签名安装。
4. 打开 App 等待约 2 秒，测试按钮显示、拖动、点击、页面切换和聊天输入。

完整操作和排查见 [INSTALL.txt](INSTALL.txt)。无法上传隐藏目录时，可按说明复制 [GitHub-workflow-copy.txt](GitHub-workflow-copy.txt) 创建工作流。

## 构建

```bash
bash build.sh
```

需要 macOS、Xcode 和 iPhoneOS SDK。使用系统 clang，输出 iOS 13+ / arm64 dylib，不依赖 Theos、Substrate、第三方 SDK 或 GitHub Secrets。产物经临时签名，注入时需要随目标 App 重新签名。

## 实现和范围

- 使用 constructor 在主线程启动，在前台普通 App 窗口添加透明视图；不替换宿主方法。
- 按钮外的触摸透传；监听 App 和 Scene 激活，并每 2 秒在前台检查按钮。
- 没有网络请求，不读取剪贴板；用户点“复制测试信息”时写入版本与 App 标识。
- 仅显示在被注入 App 内；不提供系统全局悬浮窗，不适用于模拟器或 App 扩展。
- 不保证所有 App 兼容；需要可重签名的 IPA 和有效签名材料。

当前交付为源代码。已做结构与脚本语法检查，未进行 Xcode 编译、轻松签注入或真机验证；以你的 Actions 日志和真机结果为准。

## 参考

- [Apple UIWindowScene](https://developer.apple.com/documentation/uikit/uiwindowscene)
- [GitHub 构建产物下载说明](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts)
