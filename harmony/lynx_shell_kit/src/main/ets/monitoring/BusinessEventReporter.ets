import { LynxContext } from '@lynx/lynx';
import ShellMessageHub from '../common/ShellMessageHub';
import BusinessEventInput, {
  BusinessEventReasonCode,
  BusinessQueueAdmission,
  RejectedBusinessAdmissionValue
} from './BusinessEventInput';
import LynxMonitor from './LynxMonitor';

export interface NativeBusinessEventResult {
  readonly code: number;
  readonly message: string;
  readonly data: BusinessQueueAdmission;
}

class NativeBusinessEventResultValue implements NativeBusinessEventResult {
  readonly code: number;
  readonly message: string;
  readonly data: BusinessQueueAdmission;

  constructor(admission: BusinessQueueAdmission) {
    this.data = admission;
    if (admission.stage === 'queued') {
      this.code = 0;
      this.message = '业务事件已进入原生监控队列';
      return;
    }
    const reason = admission.reasonCode;
    this.code = reason === 'invalid_argument' || reason === 'event_too_large' ? 1001 :
      reason === 'page_context_unavailable' ? 1002 : reason === 'internal_error' ? 1500 : 1004;
    this.message = NativeBusinessEventResultValue.rejectionMessage(reason);
  }

  private static rejectionMessage(reason: BusinessEventReasonCode): string {
    switch (reason) {
      case 'invalid_argument': return '业务事件参数无效';
      case 'event_too_large': return '业务事件超过监控单事件总预算';
      case 'page_context_unavailable': return '发送页面已销毁或监控上下文不可用';
      case 'not_configured': return '宿主尚未启用监控或配置 Provider';
      case 'not_ready': return '监控初始化失败或当前不可接收事件';
      case 'monitor_closed': return '监控实例已关闭';
      case 'event_unsupported': return '监控 Provider 不支持业务事件';
      case 'queue_rejected': return '监控队列无法接收本次业务事件';
      case 'internal_error': return '业务事件接收发生原生内部异常';
    }
  }
}

/** 只负责真实发送 Context 的解析和回执转换；Provider 交付由监控 Core 执行。 */
export default class BusinessEventReporter {
  static report(context: LynxContext, group: string, name: string, attributesJSON: string): NativeBusinessEventResult {
    try {
      const input = BusinessEventInput.parse(group, name, attributesJSON);
      if (input instanceof RejectedBusinessAdmissionValue) {
        return new NativeBusinessEventResultValue(input);
      }
      const entryID = ShellMessageHub.pageId(context);
      if (entryID === null) {
        return new NativeBusinessEventResultValue(new RejectedBusinessAdmissionValue('page_context_unavailable'));
      }
      const monitor = LynxMonitor.shared();
      const binding = monitor.contextBinding(context, entryID);
      if (binding !== null) {
        return new NativeBusinessEventResultValue(monitor.recordBusinessEvent(binding, input));
      }
      const runtimeRejection = monitor.businessRuntimeRejection();
      return new NativeBusinessEventResultValue(new RejectedBusinessAdmissionValue(
        runtimeRejection ?? 'page_context_unavailable'));
    } catch (_error) {
      return new NativeBusinessEventResultValue(new RejectedBusinessAdmissionValue('internal_error'));
    }
  }

  private constructor() {
  }
}
