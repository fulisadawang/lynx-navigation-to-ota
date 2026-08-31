import router from '@ohos.router';
import {
  LynxRouter,
  OtaStorageAppSnapshot,
  OtaStorageReleaseSnapshot,
  OtaStorageSnapshot
} from '@lynx/lynx-shell-kit';

/** Demo-only 原生只读 Store v3 浏览器；不会扫描任意目录或触发 OTA。 */
@Entry
@Component
struct OtaStorageInspector {
  @State private content: string = '正在读取 OTA Store 快照…';

  aboutToAppear(): void {
    this.refresh();
  }

  private refresh(): void {
    this.content = '正在读取 OTA Store 快照…';
    LynxRouter.otaStorageSnapshot()
      .then((snapshot) => {
        this.content = snapshot === null ? '当前没有安装 OTA runtime。' : this.renderSnapshot(snapshot);
      })
      .catch((error: Error) => {
        this.content = `OTA Store 快照读取失败：${error.message}`;
      });
  }

  private renderSnapshot(snapshot: OtaStorageSnapshot): string {
    const lines: string[] = [
      'OTA Store v3 磁盘浏览器（只读）',
      '',
      `root: ${snapshot.rootPath}`,
      `apps: ${snapshot.apps.length}`,
      `files: ${snapshot.fileCount}`,
      `disk: ${this.formatBytes(snapshot.totalBytes)}`,
      'mode: read-only',
      '────────────────────────'
    ];
    snapshot.apps.forEach((app: OtaStorageAppSnapshot) => {
      lines.push(`App ID ${app.appId}`);
      if (app.state === undefined) {
        lines.push('state: —');
      } else {
        lines.push(`current: ${app.state.currentReleaseId} (${app.state.currentKind})`);
        lines.push(`previous: ${app.state.previousReleaseId ?? '—'}${app.state.previousKind === undefined ? '' : ` (${app.state.previousKind})`}`);
      }
      lines.push(`CAS objects: ${app.objectCount ?? 0} / ${this.formatBytes(app.objectBytes ?? 0)}`);
      lines.push(`Manifests: ${this.formatBytes(app.manifestBytes ?? 0)}`);
      lines.push(`disk: ${this.formatBytes(app.totalBytes)} / ${app.fileCount} files`);
      app.releases.forEach((release: OtaStorageReleaseSnapshot) => {
        lines.push(`  ${release.releaseId} [${release.roles.join(' · ')}] manifest=${release.manifestValid ? 'valid' : 'invalid'} ${this.formatBytes(release.totalBytes)}`);
        lines.push(`    manifestId=${release.manifestId ?? '—'} bundles=${release.bundleCount ?? 0} objects=${release.objectIds?.length ?? 0}`);
        release.files.forEach((file) => lines.push(`    ├─ ${file.relativePath} ${this.formatBytes(file.byteCount)}`));
        if (release.truncated) lines.push('    … 文件树已截断');
      });
      app.staging.forEach((transaction) => {
        lines.push(`  staging/${transaction.transactionName} ${this.formatBytes(transaction.totalBytes)}`);
        transaction.files.forEach((file) => lines.push(`    ├─ ${file.relativePath} ${this.formatBytes(file.byteCount)}`));
      });
      lines.push('────────────────────────');
    });
    return lines.join('\n');
  }

  private formatBytes(bytes: number): string {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  build() {
    Column() {
      Row() {
        Button('返回')
          .height(44)
          .fontSize(14)
          .onClick(() => router.back())
        Blank()
        Button('刷新')
          .height(44)
          .fontSize(14)
          .onClick(() => this.refresh())
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Scroll() {
        Text(this.content)
          .width('100%')
          .fontSize(12)
          .fontColor($r('app.color.shell_text_primary'))
          .fontFamily('monospace')
          .lineHeight(18)
      }
      .layoutWeight(1)
      .padding({ left: 16, right: 16, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.shell_background'))
  }
}
