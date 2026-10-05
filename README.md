# flutter_flutter OHOS 镜像

- `oh-3.44.9-dev`：https://gitcode.com/CPF-Flutter/flutter_flutter.git 同名分支的 1:1 镜像（每日自动同步，禁止直接提交；分叉即同步失败告警）。
- `ohos/media-kit-patches`：media-kit 审查通过的 OHOS patch 分支（framework TargetPlatform.ohos 平台 parity + HCPP 契约文档/测试），基于钉定基线，rebase 由 media-kit 侧流程管理。
- `infra`（默认分支）：仅存放同步 workflow 与说明。

本地回退同步：media-kit 仓 `tool/ohos/sync-flutter-mirror.sh`。
