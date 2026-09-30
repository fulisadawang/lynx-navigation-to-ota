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
      'view.lifecycle', 'view.load', 'lynx.performance', 'lynx.js_error', 'lynx.resource', 'monitor.diagnostic',
      'business.event'
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
    if (eventValue.eventType === 'business.event') {
      const candidates: number[] = [];
      let remainingCount = this.events.length;
      let remainingBytes = this.bytes;
      for (let index = 0; index < this.events.length &&
        (remainingCount >= 128 || remainingBytes + eventBytes > 512 * 1024); index++) {
        const candidate = this.events[index];
        if (candidate.eventType === 'lynx.performance' || candidate.eventType === 'lynx.resource') {
          candidates.push(index);
          remainingCount -= 1;
          remainingBytes -= monitorJsonBytes(candidate);
        }
      }
      if (remainingCount >= 128 || remainingBytes + eventBytes > 512 * 1024) {
        return new RejectedHandoffResultValue('provider_error');
      }
      for (let index = candidates.length - 1; index >= 0; index--) this.events.splice(candidates[index], 1);
      this.bytes = remainingBytes;
    }
    while (this.events.length >= 128 || this.bytes + eventBytes > 512 * 1024) {
      const performanceIndex = this.events.findIndex((item: MonitorEvent) =>
        item.eventType === 'lynx.performance' || item.eventType === 'lynx.resource');
      const businessIndex = performanceIndex >= 0 ? -1 : this.events.findIndex((item: MonitorEvent) =>
        item.eventType === 'business.event');
      const dropped = performanceIndex >= 0
        ? this.events.splice(performanceIndex, 1)[0]
        : businessIndex >= 0 ? this.events.splice(businessIndex, 1)[0] : this.events.shift();
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
