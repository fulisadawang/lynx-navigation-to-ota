import { BusinessEventValue, BusinessPayload, BusinessPayloadValue } from './MonitorTypes';
import { monitorSanitize, monitorUtf8Bytes } from './MonitorUtils';

export type BusinessEventReasonCode = 'invalid_argument' | 'event_too_large' | 'page_context_unavailable' |
  'not_configured' | 'not_ready' | 'monitor_closed' | 'event_unsupported' | 'queue_rejected' | 'internal_error';
export type BusinessMonitorState = 'initializing' | 'ready';

export interface QueuedBusinessAdmission {
  readonly stage: 'queued';
  readonly eventId: string;
  readonly monitorState: BusinessMonitorState;
}

export interface RejectedBusinessAdmission {
  readonly stage: 'rejected';
  readonly reasonCode: BusinessEventReasonCode;
}

export type BusinessQueueAdmission = QueuedBusinessAdmission | RejectedBusinessAdmission;

export class QueuedBusinessAdmissionValue implements QueuedBusinessAdmission {
  readonly stage: 'queued' = 'queued';
  readonly eventId: string;
  readonly monitorState: BusinessMonitorState;

  constructor(eventId: string, monitorState: BusinessMonitorState) {
    this.eventId = eventId;
    this.monitorState = monitorState;
  }
}

export class RejectedBusinessAdmissionValue implements RejectedBusinessAdmission {
  readonly stage: 'rejected' = 'rejected';
  readonly reasonCode: BusinessEventReasonCode;

  constructor(reasonCode: BusinessEventReasonCode) {
    this.reasonCode = reasonCode;
  }
}

/** 原生输入边界只校验传输类型和总预算，业务分组、名称和字段名保留原文。 */
export default class BusinessEventInput {
  readonly group: string;
  readonly name: string;
  private readonly attributes: Readonly<Record<string, BusinessEventValue>>;

  private constructor(group: string, name: string, attributes: Readonly<Record<string, BusinessEventValue>>) {
    this.group = group;
    this.name = name;
    this.attributes = attributes;
  }

  static parse(group: string, name: string, attributesJSON: string): BusinessEventInput | RejectedBusinessAdmissionValue {
    if (typeof group !== 'string' || typeof name !== 'string' || typeof attributesJSON !== 'string') {
      return new RejectedBusinessAdmissionValue('invalid_argument');
    }
    if (group.length + name.length + attributesJSON.length > 32 * 1024 ||
      monitorUtf8Bytes(group) + monitorUtf8Bytes(name) + monitorUtf8Bytes(attributesJSON) > 32 * 1024) {
      return new RejectedBusinessAdmissionValue('event_too_large');
    }
    if (group.trim().length === 0 || name.trim().length === 0) {
      return new RejectedBusinessAdmissionValue('invalid_argument');
    }
    let parsed: Object;
    try {
      parsed = JSON.parse(attributesJSON) as Object;
    } catch (_error) {
      return new RejectedBusinessAdmissionValue('invalid_argument');
    }
    if (parsed === null || Array.isArray(parsed) || typeof parsed !== 'object') {
      return new RejectedBusinessAdmissionValue('invalid_argument');
    }
    const attributes = parsed as Record<string, Object>;
    const keys = Object.keys(attributes);
    for (let index = 0; index < keys.length; index++) {
      const key = keys[index];
      const value = attributes[key];
      if (key.length === 0 || (typeof value !== 'string' && typeof value !== 'boolean' &&
        (typeof value !== 'number' || !Number.isFinite(value)))) {
        return new RejectedBusinessAdmissionValue('invalid_argument');
      }
    }
    return new BusinessEventInput(group, name,
      Object.freeze(attributes as Record<string, BusinessEventValue>));
  }

  sanitizedPayload(): BusinessPayload {
    // JSON 副本保留 __proto__ 等合法自有字段；仅清理字符串 value，不截断或重命名业务字段。
    const attributes = JSON.parse(JSON.stringify(this.attributes)) as Record<string, BusinessEventValue>;
    Object.keys(attributes).forEach((key: string) => {
      const value = attributes[key];
      if (typeof value === 'string') attributes[key] = monitorSanitize(value);
    });
    return Object.freeze(new BusinessPayloadValue(this.name, Object.freeze(attributes)));
  }
}
