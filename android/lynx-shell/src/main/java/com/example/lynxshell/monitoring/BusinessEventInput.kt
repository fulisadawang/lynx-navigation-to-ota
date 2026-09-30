package com.example.lynxshell.monitoring

internal data class BusinessEventInput(val payload: BusinessPayload)
internal class BusinessEventInputException(val rejection: BusinessEventRejection) : IllegalArgumentException(rejection.message)

/** 三个原始字符串共用已有单事件预算，先拒绝超限输入再解析；不改写业务分组或名称。 */
internal fun parseBusinessEventInput(group: String, name: String, attributesJSON: String): BusinessEventInput {
    var bytes = 0
    for (value in listOf(group, name, attributesJSON)) {
        bytes += utf8Bytes(value, MAX_EVENT_BYTES - bytes)
        if (bytes > MAX_EVENT_BYTES) throw BusinessEventInputException(BusinessEventRejection.EVENT_TOO_LARGE)
    }
    if (group.isBlank() || name.isBlank()) throw BusinessEventInputException(BusinessEventRejection.INVALID_ARGUMENT)
    return BusinessEventInput(BusinessPayload(group, name, BusinessAttributesParser(attributesJSON).parse()))
}

/** Android JSONTokener 会接受非 JSON 语法；本入口只解析合同允许的扁平 JSON 基本类型。 */
private class BusinessAttributesParser(private val input: String) {
    private var offset = 0

    fun parse(): Map<String, BusinessEventValue> {
        val attributes = linkedMapOf<String, BusinessEventValue>()
        expect('{')
        skipWhitespace()
        if (!take('}')) {
            while (true) {
                val key = string()
                if (key.isEmpty()) invalid()
                expect(':')
                skipWhitespace()
                val value = when (input.getOrNull(offset) ?: invalid()) {
                    '"' -> BusinessEventValue.Text(string())
                    't' -> { literal("true"); BusinessEventValue.Flag(true) }
                    'f' -> { literal("false"); BusinessEventValue.Flag(false) }
                    '-', in '0'..'9' -> BusinessEventValue.Numeric(number())
                    else -> invalid()
                }
                attributes[key] = value
                skipWhitespace()
                if (take('}')) break
                expect(',')
            }
        }
        skipWhitespace()
        if (offset != input.length) invalid()
        return attributes
    }

    private fun string(): String {
        expect('"')
        val decoded = StringBuilder()
        while (offset < input.length) {
            val value = input[offset++]
            when (value) {
                '"' -> return decoded.toString()
                '\\' -> {
                    when (val escape = input.getOrNull(offset++) ?: invalid()) {
                        '"', '\\', '/' -> decoded.append(escape)
                        'b' -> decoded.append('\b')
                        'f' -> decoded.append('\u000c')
                        'n' -> decoded.append('\n')
                        'r' -> decoded.append('\r')
                        't' -> decoded.append('\t')
                        'u' -> {
                            var code = 0
                            repeat(4) {
                                val digit = when (val hex = input.getOrNull(offset++) ?: invalid()) {
                                    in '0'..'9' -> hex - '0'
                                    in 'a'..'f' -> hex - 'a' + 10
                                    in 'A'..'F' -> hex - 'A' + 10
                                    else -> invalid()
                                }
                                code = code * 16 + digit
                            }
                            decoded.append(code.toChar())
                        }
                        else -> invalid()
                    }
                }
                else -> { if (value < ' ') invalid(); decoded.append(value) }
            }
        }
        invalid()
    }

    private fun number(): Double {
        val start = offset
        take('-')
        if (!take('0')) {
            if ((input.getOrNull(offset) ?: invalid()) !in '1'..'9') invalid()
            digits()
        }
        if (take('.')) digits()
        if (take('e') || take('E')) {
            if (!take('+')) take('-')
            digits()
        }
        val value = input.substring(start, offset).toDoubleOrNull() ?: invalid()
        if (!value.isFinite()) invalid()
        return value
    }

    private fun digits() {
        val start = offset
        while (offset < input.length && input[offset] in '0'..'9') offset++
        if (offset == start) invalid()
    }

    private fun literal(value: String) {
        if (!input.startsWith(value, offset)) invalid()
        offset += value.length
    }

    private fun expect(value: Char) { skipWhitespace(); if (!take(value)) invalid() }
    private fun take(value: Char): Boolean = if (input.getOrNull(offset) == value) { offset++; true } else false
    private fun skipWhitespace() {
        while (offset < input.length) {
            when (input[offset]) {
                ' ', '\t', '\r', '\n' -> offset++
                else -> return
            }
        }
    }
    private fun invalid(): Nothing = throw BusinessEventInputException(BusinessEventRejection.INVALID_ARGUMENT)
}
