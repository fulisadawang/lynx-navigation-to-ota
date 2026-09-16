# LynxView 监控归档工具

这个目录只处理显式传入的 G1 本地归档，不读取其他工作区，不连接业务 Server，也不包含 ARMS、Bugly 等 G2 Provider。

校验构建清单：

~~~bash
node scripts/lynx-monitor-artifacts/cli.mjs \
  check --manifest playground/.artifacts/lynx-monitor/<buildId>/manifest.json
~~~

还原一条错误事件：

~~~bash
node scripts/lynx-monitor-artifacts/cli.mjs \
  resolve \
  --event /tmp/lynx-monitor-event.json \
  --manifest playground/.artifacts/lynx-monitor/<buildId>/manifest.json \
  --output /tmp/lynx-monitor-result.json
~~~

发布命令当前会返回 NOT_CONFIGURED，不会把本地 archive 当成云端上传成功。生产 Debug Metadata 归档由 Playground 配置在官方清理阶段前捕获，推荐使用 CI=1 pnpm build。

执行工具自测：

~~~bash
node scripts/lynx-monitor-artifacts/selftest.mjs
~~~
