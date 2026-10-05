import fs from '@ohos.file.fs';
import cryptoFramework from '@ohos.security.cryptoFramework';

/** 使用系统异步文件/摘要 API；每次只读取 64 KiB，不在 ArkUI 线程同步扫描整个 Bundle。 */
export async function hashOtaFile(path: string, maximumBytes: number = 20 * 1024 * 1024): Promise<string> {
  const file = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
  try {
    const digest = cryptoFramework.createMd('SHA256');
    let position = 0;
    while (true) {
      const chunk = new ArrayBuffer(64 * 1024);
      const read = await fs.read(file.fd, chunk, { length: chunk.byteLength });
      if (read === 0) break;
      position += read;
      if (position > maximumBytes) throw new Error('OTA 文件超过声明字节预算');
      await digest.update({ data: new Uint8Array(chunk, 0, read) });
    }
    const result = await digest.digest();
    let hex = '';
    result.data.forEach((value: number) => { hex += value.toString(16).padStart(2, '0'); });
    return `sha256:${hex}`;
  } finally { await fs.close(file); }
}
