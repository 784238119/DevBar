# DevBar 开发与发布流程

## 分支职责

- `main`：稳定发布分支，只接受 Pull Request 合并，禁止直接推送。
- `dev-<版本号>`：对应下一个计划版本的开发分支，例如 `dev-0.2.2`。

不要使用长期不带版本号的 `dev` 分支，否则多个版本的改动容易混在一起，也无法从分支名判断发布目标。

## 开发流程

1. 从最新 `main` 创建下一版本分支：

   ```bash
   git switch main
   git pull --ff-only origin main
   git switch -c dev-0.2.2
   git push -u origin dev-0.2.2
   ```

2. 功能、修复及对应测试提交到当前 `dev-<版本号>`。
3. 验证测试、Release 构建、DMG 和 Sparkle appcast。
4. 从 `dev-<版本号>` 向 `main` 创建 Pull Request。
5. 解决所有审查讨论后，使用 merge commit 合并；不要直接推送 `main`。
6. 以合并后的 `main` 提交创建版本 tag 和 GitHub Release。
7. 发布完成后，从最新 `main` 创建下一个 `dev-<版本号>` 分支。

## 发布边界

- 未通过测试或没有可下载 DMG 的版本不得合并到 `main`。
- appcast 中的新版本必须在对应 GitHub Release 资产可下载后才对外生效。
- Sparkle 私钥只保存在安全的钥匙串或 CI Secret 中，禁止提交到仓库。
