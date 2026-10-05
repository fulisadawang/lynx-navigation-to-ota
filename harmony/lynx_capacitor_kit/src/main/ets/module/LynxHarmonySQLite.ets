import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { LynxHarmonyNativeOwner } from './LynxHarmonyNativeOwner';
import { LynxHarmonyNativeIO, lynxUTF8Bytes, LYNX_INLINE_BYTES, LYNX_RESULT_BYTES } from './LynxHarmonyNativeIO';

interface SQLiteSpecification { readonly: boolean; encrypted: boolean; version: number; }
interface SQLiteQuery { columns: Array<string>; values: Array<Array<Object>>; }
interface DatabaseQueue { serial: Promise<void>; waiting: number; }

/** 只保留三端公共目录的八个方法；不让未声明的迁移/导出分支绕过预算。 */
export class LynxHarmonySQLite {
  private static queues: Map<string, DatabaseQueue> = new Map();
  private stores: Map<string, relationalStore.RdbStore> = new Map();
  private specifications: Map<string, SQLiteSpecification> = new Map();
  private databaseKeys: Map<string, string> = new Map();
  private readonly owner: LynxHarmonyNativeOwner;
  private readonly context: () => common.UIAbilityContext;
  constructor(owner: LynxHarmonyNativeOwner, context: () => common.UIAbilityContext) { this.owner = owner; this.context = context; }

  public destroy(): void {
    this.stores.forEach((store: relationalStore.RdbStore, name: string): void => {
      const key = this.databaseKeys.get(name);
      const queue = key === undefined ? undefined : LynxHarmonySQLite.queues.get(key);
      // 回执已取消，真实query/execute/rollback仍须完成，再关闭所属连接。
      const ended = queue === undefined ? Promise.resolve() : queue.serial;
      ended.then((): void => {
        try { store.close(); } catch (error) { console.error('LynxCapacitor', 'SQLite close failed: ' + String(error)); }
      });
    });
    this.stores.clear();
    this.specifications.clear();
    this.databaseKeys.clear();
  }

  public dispatch(method: string, options: Record<string, Object>): Promise<Object> {
    this.owner.checkActive();
    if (method === 'isAvailable') return Promise.resolve({ result: true });
    if (method === 'echo') return Promise.resolve({ value: options['value'] ?? null });
    const name = String(options['database'] ?? '').trim();
    if (!/^[A-Za-z0-9_-]{1,128}$/.test(name)) return Promise.reject(new Error('INVALID_ARGUMENT: database 必须是不含路径的数据库名称'));
    const key = this.context().databaseDir + '/' + name;
    this.databaseKeys.set(name, key);
    let queue = LynxHarmonySQLite.queues.get(key);
    if (queue === undefined) { queue = { serial: Promise.resolve(), waiting: 0 }; LynxHarmonySQLite.queues.set(key, queue); }
    if (queue.waiting >= 16) return Promise.reject(new Error('BUSY: 数据库等待队列已满'));
    queue.waiting += 1;
    const current = queue;
    const previous = current.serial;
    let signal: () => void = (): void => {};
    let started = false;
    const ended = new Promise<void>((resolve): void => { signal = resolve; });
    const operation = previous.then((): Promise<Object> => LynxHarmonyNativeIO.run(this.owner, async (): Promise<Object> => {
      started = true;
      try { return await this.perform(name, method, options); }
      finally { signal(); }
    })).catch((error: Object): Object => { if (!started) signal(); throw error; });
    // owner 取消的 Bridge 终态不能提前解锁数据库；必须等真实 native 操作/回滚结束。
    current.serial = previous.then((): Promise<void> => ended).finally((): void => {
      current.waiting -= 1;
      if (current.waiting === 0 && LynxHarmonySQLite.queues.get(key) === current) LynxHarmonySQLite.queues.delete(key);
    });
    return operation;
  }

  private async perform(name: string, method: string, options: Record<string, Object>): Promise<Object> {
    this.owner.checkActive();
    if (method === 'createConnection') {
      if (options['encrypted'] === true) throw new Error('UNSUPPORTED: 没有配置 SQLCipher-compatible provider');
      const version = Number(options['version'] ?? 1);
      if (!Number.isSafeInteger(version) || version < 1) throw new Error('INVALID_ARGUMENT: version 必须为正整数');
      const existing = this.stores.get(name);
      if (existing !== undefined) {
        if (this.specifications.get(name)?.readonly === true) throw new Error('CONNECTION_READ_ONLY: 数据库以只读方式打开');
        existing.version = version;
        return { database: name, version: existing.version, created: false };
      }
      this.specifications.set(name, { readonly: options['readonly'] === true, encrypted: false, version: version });
      try {
        const opened = await this.perform(name, 'open', options) as Record<string, Object>;
        return { database: name, version: opened['version'], created: true };
      } catch (error) { this.specifications.delete(name); throw error; }
    }
    if (method === 'open') {
      const existing = this.stores.get(name);
      if (existing !== undefined) return { database: name, opened: true, version: existing.version };
      const specification = this.specifications.get(name);
      if (specification === undefined) throw new Error('CONNECTION_NOT_FOUND: 请先创建数据库连接');
      if (specification.encrypted) throw new Error('UNSUPPORTED: 没有配置 SQLCipher-compatible provider');
      if (!Number.isSafeInteger(specification.version) || specification.version < 1) throw new Error('INVALID_ARGUMENT: version 必须为正整数');
      const config: relationalStore.StoreConfig = { name: name + 'SQLite.db', securityLevel: relationalStore.SecurityLevel.S1, encrypt: false, isReadOnly: specification.readonly };
      const store = await relationalStore.getRdbStore(this.context(), config);
      try {
        this.owner.checkActive();
        // readonly 由 API12 起的原生只读打开保障，不能靠 SQL 字符串分类模拟。
        if (!specification.readonly && store.version < specification.version) store.version = specification.version;
        this.owner.checkActive();
        this.specifications.set(name, specification);
        this.stores.set(name, store);
      } catch (error) { store.close(); throw error; }
      return { database: name, opened: true, version: store.version };
    }
    const store = this.stores.get(name);
    if (store === undefined) throw new Error('CONNECTION_NOT_FOUND: 数据库连接不存在');
    if (method === 'close') { store.close(); this.stores.delete(name); this.specifications.delete(name); return { database: name, closed: true }; }
    if (method === 'query') {
      const statement = String(options['statement'] ?? options['statements'] ?? '').trim();
      if (statement.length === 0) throw new Error('INVALID_ARGUMENT: statement 不能为空');
      const result = await this.query(store, statement, this.values(options));
      this.owner.checkActive();
      return result;
    }
    if (method !== 'run' && method !== 'execute') throw new Error('UNIMPLEMENTED: CapacitorSQLite.' + method);
    if (this.specifications.get(name)?.readonly === true) throw new Error('CONNECTION_READ_ONLY: 数据库以只读方式打开');
    const statements = splitSQLiteStatements(String(method === 'execute' ? options['statements'] ?? options['statement'] ?? '' : options['statement'] ?? options['statements'] ?? ''));
    if (statements.length === 0 || (method === 'run' && statements.length !== 1)) throw new Error('INVALID_ARGUMENT: run 只允许一条 SQL，execute 至少需要一条 SQL');
    const boundValues = this.values(options);
    if (statements.length > 1 && boundValues.length > 0) throw new Error('INVALID_ARGUMENT: 多条 SQL 不能共用绑定 values');
    const useTransaction = options['transaction'] !== false;
    let previousTotal = await this.scalar(store, 'SELECT total_changes()');
    let changed = 0;
    this.owner.checkActive();
    if (useTransaction) store.beginTransaction();
    try {
      for (const statement of statements) {
        this.owner.checkActive();
        await store.executeSql(statement, boundValues);
        this.owner.checkActive();
        const total = await this.scalar(store, 'SELECT total_changes()');
        const direct = await this.scalar(store, 'SELECT changes()');
        if (total > previousTotal) changed += direct;
        previousTotal = total;
      }
      const lastId = await this.scalar(store, 'SELECT last_insert_rowid()');
      this.owner.checkActive();
      if (useTransaction) store.commit();
      const changes: Record<string, Object> = { database: name, changes: { changes: changed, lastId: lastId } };
      if (method === 'execute') changes['statements'] = statements.length;
      return changes;
    } catch (error) {
      if (useTransaction) {
        try { store.rollBack(); } catch (rollbackError) { console.error('LynxCapacitor', 'SQLite rollback failed: ' + String(rollbackError)); }
      }
      throw error;
    }
  }

  private values(options: Record<string, Object>): Array<relationalStore.ValueType> {
    const raw = options['values'];
    if (raw === undefined || raw === null) return [];
    if (!Array.isArray(raw)) throw new Error('INVALID_ARGUMENT: values 必须为数组');
    return (raw as Array<Object>).map((value: Object): relationalStore.ValueType => {
      if (value === null || typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') return value as relationalStore.ValueType;
      if (Array.isArray(value)) {
        const bytes = value as Array<number>;
        if (bytes.length > LYNX_INLINE_BYTES || bytes.some((byte: number): boolean => !Number.isInteger(byte) || byte < 0 || byte > 255)) throw new Error('INVALID_ARGUMENT: BLOB 必须为预算内的字节数组');
        return new Uint8Array(bytes);
      }
      throw new Error('INVALID_ARGUMENT: 不支持的 SQLite 参数类型');
    });
  }

  private async scalar(store: relationalStore.RdbStore, statement: string): Promise<number> {
    const result = await store.querySql(statement);
    try { this.owner.checkActive(); return result.goToFirstRow() ? result.getLong(0) : 0; }
    finally { result.close(); }
  }

  private async query(store: relationalStore.RdbStore, statement: string, values: Array<relationalStore.ValueType>): Promise<SQLiteQuery> {
    const result = await store.querySql(statement, values);
    try {
      this.owner.checkActive();
      const columns = result.columnNames;
      const rows: Array<Array<Object>> = [];
      let bytes = lynxUTF8Bytes(JSON.stringify(columns)) + 32;
      if (result.goToFirstRow()) do {
        this.owner.checkActive();
        const row: Array<Object> = [];
        for (let index = 0; index < columns.length; index += 1) {
          const native = result.isColumnNull(index) ? null : result.getValue(index);
          let value: Object;
          // getValue/isColumnNull 从 API12 可用，避免最低 API13 调用 API18 的 ColumnType。
          if (native instanceof Uint8Array) {
            if (native.byteLength > LYNX_INLINE_BYTES) throw new Error('RESULT_TOO_LARGE: 单个 BLOB 超过 512 KiB');
            value = await LynxHarmonyNativeIO.directTask('encodeBytes', [native]);
            this.owner.checkActive();
          } else if (native === null || typeof native === 'string' || typeof native === 'number' || typeof native === 'boolean') value = native as Object;
          else throw new Error('UNSUPPORTED: SQLite 特殊原生值不属于公共 JSON 契约');
          const cellBytes = lynxUTF8Bytes(JSON.stringify(value));
          if (!(native instanceof Uint8Array) && cellBytes > LYNX_INLINE_BYTES) throw new Error('RESULT_TOO_LARGE: 单个字段超过 512 KiB');
          bytes += cellBytes + 1;
          if (bytes > LYNX_RESULT_BYTES) throw new Error('RESULT_TOO_LARGE: 查询结果超过 2 MiB，请使用 LIMIT/分页');
          row.push(value);
        }
        bytes += 2;
        if (bytes > LYNX_RESULT_BYTES) throw new Error('RESULT_TOO_LARGE: 查询结果超过 2 MiB，请使用 LIMIT/分页');
        rows.push(row);
        // 低系统没有 ResultSet 异步批量读取；有界遍历主动让出事件循环，不阻塞整屏输入。
        if (rows.length % 64 === 0) await new Promise<void>((resolve): void => { setTimeout(resolve, 0); });
      } while (result.goToNextRow());
      this.owner.checkActive();
      return { columns: columns, values: rows };
    } finally { result.close(); }
  }
}

/** 分句识别引用、注释与 CREATE TRIGGER BEGIN/END；字符串中的分号不会被拆开。 */
export function splitSQLiteStatements(sql: string): Array<string> {
  const result: Array<string> = [];
  let start = 0;
  let quote = '';
  let lineComment = false;
  let blockComment = false;
  let trigger = false;
  let triggerDepth = 0;
  let caseDepth = 0;
  let tokens: Array<string> = [];
  for (let index = 0; index < sql.length; index += 1) {
    const current = sql[index];
    const next = index + 1 < sql.length ? sql[index + 1] : '';
    if (lineComment) { if (current === '\n') lineComment = false; continue; }
    if (blockComment) { if (current === '*' && next === '/') { blockComment = false; index += 1; } continue; }
    if (quote.length > 0) {
      if (current === quote) { if (next === quote && quote !== ']') index += 1; else quote = ''; }
      continue;
    }
    if (current === '-' && next === '-') { lineComment = true; index += 1; continue; }
    if (current === '/' && next === '*') { blockComment = true; index += 1; continue; }
    if (current === "'" || current === '"' || current === '`' || current === '[') { quote = current === '[' ? ']' : current; continue; }
    if (/[A-Za-z_]/.test(current)) {
      let end = index + 1;
      while (end < sql.length && /[A-Za-z0-9_]/.test(sql[end])) end += 1;
      const token = sql.substring(index, end).toUpperCase();
      tokens.push(token);
      if (tokens.length <= 4 && tokens[0] === 'CREATE' && token === 'TRIGGER') trigger = true;
      if (trigger && token === 'BEGIN') triggerDepth += 1;
      else if (trigger && token === 'CASE') caseDepth += 1;
      else if (trigger && token === 'END') { if (caseDepth > 0) caseDepth -= 1; else if (triggerDepth > 0) triggerDepth -= 1; }
      index = end - 1;
      continue;
    }
    if (current === ';' && triggerDepth === 0) {
      const statement = sql.substring(start, index).trim();
      if (statement.length > 0 && tokens.length > 0) result.push(statement);
      start = index + 1; tokens = []; trigger = false; caseDepth = 0;
    }
  }
  if (quote.length > 0 || blockComment || triggerDepth > 0) throw new Error('INVALID_ARGUMENT: SQL 引用、注释或 trigger 未闭合');
  const finalStatement = sql.substring(start).trim();
  if (finalStatement.length > 0 && tokens.length > 0) result.push(finalStatement);
  return result;
}
