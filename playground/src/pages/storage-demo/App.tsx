import { useState, useCallback } from '@lynx-js/react'
import { setItem, getItem } from '../../lib/storage.js'
import { ThemeProvider, useTheme } from '../../lib/theme.js'
import { DemoPage } from '../../components/DemoPage/index.js'
import { FormField } from '../../components/FormField/index.js'
import { ResultCard } from '../../components/ResultCard/index.js'

import './App.css'

interface LogEntry {
  id: number
  type: 'setItem' | 'getItem'
  request: Record<string, unknown>
  response?: { code?: number; msg?: string; data?: unknown }
  timestamp: string
}

function StorageDemoContent() {
  const { resolved } = useTheme()
  const isDark = resolved === 'dark'

  const dk = (base: string) => `${base} ${isDark ? `${base}--dark` : `${base}--light`}`

  // setItem fields
  const [setKey, setSetKey] = useState('tiktok')
  const [setData, setSetData] = useState('sparkling')
  const [setBiz, setSetBiz] = useState('')
  const [setValidDuration, setSetValidDuration] = useState('')

  // setItem result
  const [setResultCode, setSetResultCode] = useState<number | undefined>(undefined)
  const [setResultMsg, setSetResultMsg] = useState<string | undefined>(undefined)
  const [setResultData, setSetResultData] = useState<unknown>(undefined)

  // getItem fields
  const [getKey, setGetKey] = useState('tiktok')
  const [getBiz, setGetBiz] = useState('')

  // getItem result
  const [getResultCode, setGetResultCode] = useState<number | undefined>(undefined)
  const [getResultMsg, setGetResultMsg] = useState<string | undefined>(undefined)
  const [getResultData, setGetResultData] = useState<unknown>(undefined)

  // Operation log
  const [logs, setLogs] = useState<LogEntry[]>([])
  const [logId, setLogId] = useState(0)

  const addLog = useCallback(
    (entry: Omit<LogEntry, 'id' | 'timestamp'>) => {
      const now = new Date()
      const ts = `${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}:${String(now.getSeconds()).padStart(2, '0')}`
      const newId = logId + 1
      setLogId(newId)
      setLogs((prev) => [{ ...entry, id: newId, timestamp: ts }, ...prev].slice(0, 20))
    },
    [logId],
  )

  // setItem handler
  const handleSetItem = () => {
    'background only'
    setSetResultCode(undefined)
    setSetResultMsg(undefined)
    setSetResultData(undefined)

    const params: { key: string; data: string; biz?: string; validDuration?: number } = {
      key: setKey,
      data: setData,
    }
    if (setBiz) params.biz = setBiz
    if (setValidDuration) {
      const dur = Number(setValidDuration)
      if (!isNaN(dur) && dur > 0) params.validDuration = dur
    }

    const reqLog: Record<string, unknown> = { ...params }

    setItem(params, (res: { code: number; msg?: string; data?: unknown }) => {
      setSetResultCode(res.code)
      setSetResultMsg(res.msg || (res.code === 1 ? '成功' : '失败'))
      setSetResultData(res.data)
      addLog({ type: 'setItem', request: reqLog, response: res })
    })
  }

  // getItem handler
  const handleGetItem = () => {
    'background only'
    setGetResultCode(undefined)
    setGetResultMsg(undefined)
    setGetResultData(undefined)

    const params: { key: string; biz?: string } = { key: getKey }
    if (getBiz) params.biz = getBiz

    const reqLog: Record<string, unknown> = { ...params }

    getItem(params, (res: { code: number; msg?: string; data?: { data?: unknown } }) => {
      setGetResultCode(res.code)
      setGetResultMsg(res.msg || (res.code === 1 ? '成功' : '失败'))
      setGetResultData(res.data)
      addLog({ type: 'getItem', request: reqLog, response: res })
    })
  }

  const clearLogs = () => {
    'background only'
    setLogs([])
  }

  return (
    <DemoPage title="本地存储">
      {/* setItem Panel */}
      <view className={dk('sto-section')}>
        <text className={dk('sto-section-title')}>setItem</text>
        <text className={dk('sto-section-desc')}>
          保存一个键值对。原生方法：storage.setItem
        </text>

        <view className="default-hint">
          <text className="default-badge">默认值</text>
          <text className={dk('default-text')}>key=tiktok, data=sparkling</text>
        </view>

        <FormField
          type="input"
          label="key"
          description="存储键（必填）"
          value={setKey}
          placeholder="e.g. username"
          onInput={setSetKey}
        />
        <FormField
          type="input"
          label="data"
          description="要保存的值（必填）"
          value={setData}
          placeholder='e.g. John or {"name":"John"}'
          onInput={setSetData}
        />
        <FormField
          type="input"
          label="biz"
          description="业务命名空间（选填）"
          value={setBiz}
          placeholder="e.g. demo"
          onInput={setSetBiz}
        />
        <FormField
          type="input"
          label="validDuration"
          description="有效期秒数（选填）"
          value={setValidDuration}
          placeholder="e.g. 3600"
          onInput={setSetValidDuration}
        />

        <view className={dk('sto-btn')} bindtap={handleSetItem}>
          <text className="sto-btn-text">保存</text>
        </view>

        <ResultCard label="setItem 返回结果" code={setResultCode} msg={setResultMsg} data={setResultData} />
      </view>

      {/* getItem Panel */}
      <view className={dk('sto-section')}>
        <text className={dk('sto-section-title')}>getItem</text>
        <text className={dk('sto-section-desc')}>
          按 key 读取已保存的值。原生方法：storage.getItem
        </text>

        <view className="default-hint">
          <text className="default-badge">默认值</text>
          <text className={dk('default-text')}>key=tiktok</text>
        </view>

        <FormField
          type="input"
          label="key"
          description="要读取的存储键（必填）"
          value={getKey}
          placeholder="e.g. username"
          onInput={setGetKey}
        />
        <FormField
          type="input"
          label="biz"
          description="业务命名空间（选填）"
          value={getBiz}
          placeholder="e.g. demo"
          onInput={setGetBiz}
        />

        <view className={dk('sto-btn')} bindtap={handleGetItem}>
          <text className="sto-btn-text">读取</text>
        </view>

        <ResultCard label="getItem 返回结果" code={getResultCode} msg={getResultMsg} data={getResultData} />
      </view>

      {/* Operation Log */}
      <view className={dk('sto-section')}>
        <view className="sto-log-header">
          <text className={dk('sto-section-title')}>操作日志</text>
          {logs.length > 0 ? (
            <view className={dk('sto-clear-btn')} bindtap={clearLogs}>
              <text className={dk('sto-clear-btn-text')}>清空</text>
            </view>
          ) : null}
        </view>
        <text className={dk('sto-section-desc')}>
          展示存储请求参数和返回结果，最新操作排在最前。
        </text>

        {logs.length === 0 ? (
          <view className={dk('sto-log-empty')}>
            <text className={dk('sto-log-empty-text')}>
              暂无操作，请先执行上方的 setItem 或 getItem。
            </text>
          </view>
        ) : null}

        {logs.map((log) => (
          <view className={dk('sto-log-entry')} key={String(log.id)}>
            <view className="sto-log-entry-header">
              <text className={log.type === 'setItem' ? 'sto-log-badge sto-log-badge--set' : 'sto-log-badge sto-log-badge--get'}>
                {log.type}
              </text>
              <text className={dk('sto-log-time')}>{log.timestamp}</text>
            </view>
            <text className={dk('sto-log-label')}>请求：</text>
            <text className={dk('sto-log-json')}>
              {JSON.stringify(log.request, null, 2)}
            </text>
            {log.response ? (
              <view className="sto-log-response">
                <text className={dk('sto-log-label')}>返回：</text>
                <text className={dk('sto-log-json')}>
                  {JSON.stringify(log.response, null, 2)}
                </text>
              </view>
            ) : null}
          </view>
        ))}
      </view>
    </DemoPage>
  )
}

export function App() {
  return (
    <ThemeProvider>
      <StorageDemoContent />
    </ThemeProvider>
  )
}
