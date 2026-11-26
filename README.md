# GGGaTools 0.3.6

悬浮球内有两个入口。

- **打开首页**在闲鱼上方悬浮打开 `https://aixiya.cn/`。
- **查询门店**把关键词作为 `q` 参数调用 `https://aixiya.cn/api/mendian/`，原样显示 UTF-8 纯文本。「复制」把完整结果写入剪贴板。

点「关闭」或窗外空白处收起，再点悬浮球恢复刚才的页面。两处各自保留浏览或查询状态。窗口顶部「菜单」切换入口。

## 网页更新

首页由站点提供。修改站点上的网页内容、样式或按钮后，点「刷新」即可查看更新。门店数据也可在服务端更新。悬浮球菜单和门店查询界面仍由 dylib 提供。

## 远程菜单文件

将 [server/api/gggatools/menu.json](server/api/gggatools/menu.json) 放到 `aixiya.cn` 网站根目录下的 `api/gggatools/menu.json`，使 `https://aixiya.cn/api/gggatools/menu.json` 可直接返回 UTF-8 JSON。服务器可设置 `Content-Type: application/json; charset=utf-8` 和 `Cache-Control: no-cache`。

`items` 是菜单顺序。每项保留一个唯一、稳定的 `id`，修改 `title` 可改名，调整数组顺序可排序，从数组移除一项可隐藏对应入口。`web` 用于打开网页。`api` 的首版配置约定为 GET 请求、一个用户输入参数、UTF-8 纯文本结果，适用于当前门店查询。同类按钮可复制对应项目并修改 ID、标题、地址和参数名。配置公开可访问，凭据应由服务端保管。

每次打开菜单都会重新读取服务器。读取失败时显示「重试」。新增项目请使用 HTTPS 地址。查询由用户点「查询」触发。

## 构建

用 GitHub Actions 构建，下载 `GGGaTools-0.3.6-iOS-arm64`。ESign 注入步骤见 [INSTALL.txt](INSTALL.txt)。
