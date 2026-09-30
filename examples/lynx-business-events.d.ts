/** 三端原生业务事件接口；页面对象封装由 lynx-native-bridge 提供。 */
export interface BusinessEventReceipt {
  stage: 'queued';
  eventId: string;
  monitorState: 'initializing' | 'ready';
}

export type BusinessEventRejectionReason =
  | 'invalid_argument' | 'event_too_large' | 'page_context_unavailable'
  | 'not_configured' | 'not_ready' | 'monitor_closed' | 'event_unsupported'
  | 'queue_rejected' | 'internal_error';

export type BusinessEventNativeResult =
  | { code: 0; message: string; data: BusinessEventReceipt }
  | {
    code: 1001 | 1002 | 1004 | 1500;
    message: string;
    data: { stage: 'rejected'; reasonCode: BusinessEventRejectionReason };
  };
