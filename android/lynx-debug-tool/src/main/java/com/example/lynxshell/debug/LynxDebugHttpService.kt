package com.example.lynxshell.debug

import com.lynx.jsbridge.network.HttpRequest
import com.lynx.jsbridge.network.HttpResponse
import com.lynx.jsbridge.network.HttpStreamingDelegate
import com.lynx.service.http.LynxHttpService
import com.lynx.tasm.service.ILynxHttpService
import com.lynx.tasm.service.LynxHttpRequestCallback

/** Debug-only HTTP 观察层；业务请求仍由官方 LynxHttpService 执行。 */
internal object LynxDebugHttpService : ILynxHttpService {
    override fun request(request: HttpRequest, callback: LynxHttpRequestCallback) {
        val id = NetworkRequestStore.begin(request)
        LynxHttpService.request(request, callbackWrapper(id, callback))
    }

    override fun requestStreaming(
        request: HttpRequest,
        callback: LynxHttpRequestCallback,
        delegate: HttpStreamingDelegate,
    ) {
        val id = NetworkRequestStore.begin(request)
        LynxHttpService.requestStreaming(request, callbackWrapper(id, callback), delegate)
    }

    private fun callbackWrapper(id: String, callback: LynxHttpRequestCallback): LynxHttpRequestCallback =
        object : LynxHttpRequestCallback() {
            override fun invoke(response: HttpResponse) {
                NetworkRequestStore.finish(id, response)
                callback.invoke(response)
            }
        }
}
