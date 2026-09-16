import {
  FlushResult,
  HandoffResult,
  HostContext,
  InitResult,
  MonitorEvent,
  MonitorEventType,
  AcceptedHandoffResultValue,
  DiagnosticCapabilitiesValue,
  FlushResultValueImpl,
  ProviderCapabilitiesValue,
  ProviderCapabilities,
  ReadyInitResultValue,
  RejectedHandoffResultValue,
  RuntimeProvider
} from './MonitorTypes';
import { monitorJsonBytes } from './MonitorUtils';

/** G1 本地验收 Provider；只保存进程内有限样本，不代表云端已接收。 */
export default class LocalDiagnosticProvider implements RuntimeProvider {
  readonly id: string = 'harmony.local_diagnostic';
  readonly capabilities: ProviderCapabilities = new ProviderCapabilitiesValue(
    'harmony', [
      'view.lifecycle', 'view.load', 'lynx.performance', 'lynx.js_error', 'lynx.resource', 'monitor.diagnostic'
    ] as MonitorEventType[], true, true, false, false, 'core',
    new DiagnosticCapabilitiesValue('unsupported', 'unsupported', 'unsupported', 'unsupported'));

  private readonly events: MonitorEvent[] = [];
  private bytes: number = 0;
  private initialized: boolean = false;

  initialize(_context: HostContext): Promise<InitResult> {
    this.initialized = true;
    return Promise.resolve(new ReadyInitResultValue());
  }

  record(event: Readonly<MonitorEvent>): HandoffResult {
    if (!this.initialized) return new RejectedHandoffResultValue('not_ready');
    const eventValue = event as MonitorEvent;
    const eventBytes = monitorJsonBytes(eventValue);
    if (eventBytes > 32 * 1024) return new RejectedHandoffResultValue('invalid_event');
    while (this.events.length >= 128 || this.bytes + eventBytes > 512 * 1024) {
      const performanceIndex = this.events.findIndex((item: MonitorEvent) =>
        item.eventType === 'lynx.performance' || item.eventType === 'lynx.resource');
      const dropped = performanceIndex >= 0
        ? this.events.splice(performanceIndex, 1)[0]
        : this.events.shift();
      if (dropped === undefined) break;
      this.bytes -= monitorJsonBytes(dropped);
    }
    this.events.push(eventValue);
    this.bytes += eventBytes;
    return new AcceptedHandoffResultValue('recorded_locally');
  }

  flush(_timeoutMs: number): Promise<FlushResult> {
    return Promise.resolve(new FlushResultValueImpl('unsupported'));
  }

  dispose(): void {
    this.initialized = false;
    this.events.length = 0;
    this.bytes = 0;
  }

  snapshot(): MonitorEvent[] {
    return this.events.slice();
  }
}
