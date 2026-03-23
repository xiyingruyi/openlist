# OpenList macOS 一键菜单脚本

这是一个给 macOS 使用的 OpenList 一键菜单脚本。

安装完成后，只需要在终端输入：

```bash
openlist
```

就可以打开菜单，使用图形化的编号选项来管理 OpenList。

适合不想记命令、后续还想换电脑继续一键安装的人使用。

## 功能

- 安装 OpenList
- 更新 OpenList
- 彻底卸载 OpenList
- 查看运行状态
- 一键打开网页控制台
- 密码管理
- 启动 OpenList
- 停止 OpenList
- 重启 OpenList
- 查看实时运行日志
- 设置开机自启
- 取消开机自启
- 退出脚本

## 一键安装

现在可以直接使用你新的 GitHub 仓库地址，其他电脑可直接执行：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/xiyingruyi/openlist/main/install_openlist_mac.sh)"
```

运行完成后，终端输入：

```bash
openlist
```

即可打开菜单。

## 使用方法

首次安装：

1. 先执行上面的一键安装命令
2. 终端输入 `openlist`
3. 在菜单中选择 `1. 安装 OpenList`
4. 安装完成后选择 `7. 启动 OpenList`
5. 首次启动时脚本会显示默认管理员账号 `admin` 和初始密码
6. 你也可以按提示立刻设置成自己的新密码
7. 再选择 `5. 一键打开网页控制台`

以后日常使用：

1. 打开终端
2. 输入 `openlist`
3. 按菜单编号操作

## 脚本会做什么

- 菜单脚本安装到 `~/.openlist-manager/openlist-menu.sh`
- OpenList 官方程序下载到 `~/.openlist-manager/app/openlist`
- 数据目录使用 `~/Library/Application Support/OpenList/data`
- 日志目录使用 `~/Library/Logs/OpenList`
- 开机自启使用 macOS 的 `LaunchAgents`
- 首次启动时会尝试显示 OpenList 生成的初始管理员密码

## 卸载

终端输入：

```bash
openlist
```

然后在菜单中选择：

```text
3. 彻底卸载 (程序、数据及本脚本本身)
```

这会删除：

- OpenList 程序
- OpenList 数据
- 日志文件
- 开机自启配置
- `openlist` 菜单入口
- 脚本本身

## 发布到 GitHub

推荐仓库内至少包含这两个文件：

- `install_openlist_mac.sh`
- `README.md`

上传到 GitHub 后，别人就可以通过 `curl + bash` 一键安装。

当前仓库的一键安装命令就是：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/xiyingruyi/openlist/main/install_openlist_mac.sh)"
```

如果你更习惯使用 `refs/heads/main` 形式，也可以：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/xiyingruyi/openlist/refs/heads/main/install_openlist_mac.sh)"
```

## 说明

这个脚本面向 macOS。

它使用的是 OpenList 官方 GitHub Releases 下载源，菜单里的安装、更新、启动、密码重置等能力，都是围绕 OpenList 官方程序命令组织出来的。

## 官方参考

- [OpenList 官方仓库](https://github.com/OpenListTeam/OpenList)
- [OpenList 官方发布页](https://github.com/OpenListTeam/OpenList/releases)
- [OpenList 官方文档](https://doc.openlist.team/)
