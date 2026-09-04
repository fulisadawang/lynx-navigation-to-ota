/**
 * Lynx NativeModule 的统一返回 envelope。
 *
 * Android 基线要求每次调用都保留 callbackId/pluginId/methodName，成功和失败
 * 都是结构化 JSON；普通响应 save=false，事件/进度 retained 响应才使用 save=true。
 * Module 内部已有大量原生结果是 JSON 片段，因此同时提供 successJSON，避免把
 * 原生对象先反序列化再序列化造成数据形状变化。
 */
export default class LynxCapacitorEnvelope {
  public static success(
    callbackId: string,
    pluginId: string,
    methodName: string,
    data?: Object,
    save?: boolean,
  ): string {
    const dataJSON = data === undefined ? '{}' : JSON.stringify(data);
    return LynxCapacitorEnvelope.successJSON(callbackId, pluginId, methodName, dataJSON, save ?? false);
  }

  public static successJSON(
    callbackId: string,
    pluginId: string,
    methodName: string,
    dataJSON: string = '{}',
    save: boolean = false,
  ): string {
    const normalizedDataJSON = dataJSON.length === 0 ? '{}' : dataJSON;
    return '{"callbackId":' + JSON.stringify(callbackId) +
      ',"pluginId":' + JSON.stringify(pluginId) +
      ',"methodName":' + JSON.stringify(methodName) +
      ',"success":true,"data":' + normalizedDataJSON +
      ',"save":' + String(save) + '}';
  }

  public static failure(
    callbackId: string,
    pluginId: string,
    methodName: string,
    code: string,
    message: string,
  ): string {
    return '{"callbackId":' + JSON.stringify(callbackId) +
      ',"pluginId":' + JSON.stringify(pluginId) +
      ',"methodName":' + JSON.stringify(methodName) +
      ',"success":false,"error":{"code":' + JSON.stringify(code) +
      ',"message":' + JSON.stringify(message) +
      '},"save":false}';
  }
}
