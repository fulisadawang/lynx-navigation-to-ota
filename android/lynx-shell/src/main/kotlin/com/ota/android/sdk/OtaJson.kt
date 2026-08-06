package com.ota.android.sdk

object OtaJson {
  @JvmStatic
  fun parse(raw: String): Any? = Parser(raw).parse()

  @JvmStatic
  fun stringify(value: Any?): String {
    val builder = StringBuilder()
    writeValue(builder, value)
    return builder.toString()
  }

  @JvmStatic
  @Suppress("UNCHECKED_CAST")
  fun asObject(value: Any?, name: String): Map<String, Any?> {
    if (value is Map<*, *>) {
      return value as Map<String, Any?>
    }
    throw IllegalArgumentException("$name 不是 JSON 对象")
  }

  @JvmStatic
  @Suppress("UNCHECKED_CAST")
  fun asArray(value: Any?, name: String): List<Any?> {
    if (value is List<*>) {
      return value as List<Any?>
    }
    throw IllegalArgumentException("$name 不是 JSON 数组")
  }

  private fun writeValue(builder: StringBuilder, value: Any?) {
    when (value) {
      null -> builder.append("null")
      is String -> writeString(builder, value)
      is Number, is Boolean -> builder.append(value)
      is Map<*, *> -> {
        builder.append('{')
        var first = true
        for ((key, item) in value) {
          if (item == null) {
            continue
          }
          if (!first) {
            builder.append(',')
          }
          writeString(builder, key.toString())
          builder.append(':')
          writeValue(builder, item)
          first = false
        }
        builder.append('}')
      }

      is Iterable<*> -> {
        builder.append('[')
        var first = true
        for (item in value) {
          if (!first) {
            builder.append(',')
          }
          writeValue(builder, item)
          first = false
        }
        builder.append(']')
      }

      else -> writeString(builder, value.toString())
    }
  }

  private fun writeString(builder: StringBuilder, value: String) {
    builder.append('"')
    for (character in value) {
      when (character) {
        '"' -> builder.append("\\\"")
        '\\' -> builder.append("\\\\")
        '\b' -> builder.append("\\b")
        '\u000C' -> builder.append("\\f")
        '\n' -> builder.append("\\n")
        '\r' -> builder.append("\\r")
        '\t' -> builder.append("\\t")
        else -> {
          if (character < ' ') {
            builder.append(String.format("\\u%04x", character.code))
          } else {
            builder.append(character)
          }
        }
      }
    }
    builder.append('"')
  }

  private class Parser(private val raw: String) {
    private var index = 0

    fun parse(): Any? {
      skipWhitespace()
      val value = parseValue()
      skipWhitespace()
      if (index != raw.length) {
        throw error("JSON 末尾存在多余内容")
      }
      return value
    }

    private fun parseValue(): Any? {
      skipWhitespace()
      if (index >= raw.length) {
        throw error("JSON 内容意外结束")
      }
      return when (val character = raw[index]) {
        '{' -> parseObject()
        '[' -> parseArray()
        '"' -> parseString()
        't' -> parseLiteral("true", true)
        'f' -> parseLiteral("false", false)
        'n' -> parseLiteral("null", null)
        else -> {
          if (character == '-' || character.isDigit()) {
            parseNumber()
          } else {
            throw error("无法解析 JSON 值")
          }
        }
      }
    }

    private fun parseObject(): Map<String, Any?> {
      expect('{')
      val obj = LinkedHashMap<String, Any?>()
      skipWhitespace()
      if (peek('}')) {
        expect('}')
        return obj
      }
      while (true) {
        skipWhitespace()
        val key = parseString()
        skipWhitespace()
        expect(':')
        obj[key] = parseValue()
        skipWhitespace()
        if (peek('}')) {
          expect('}')
          return obj
        }
        expect(',')
      }
    }

    private fun parseArray(): List<Any?> {
      expect('[')
      val array = ArrayList<Any?>()
      skipWhitespace()
      if (peek(']')) {
        expect(']')
        return array
      }
      while (true) {
        array.add(parseValue())
        skipWhitespace()
        if (peek(']')) {
          expect(']')
          return array
        }
        expect(',')
      }
    }

    private fun parseString(): String {
      expect('"')
      val builder = StringBuilder()
      while (index < raw.length) {
        val character = raw[index++]
        if (character == '"') {
          return builder.toString()
        }
        if (character != '\\') {
          builder.append(character)
          continue
        }
        if (index >= raw.length) {
          throw error("字符串转义意外结束")
        }
        when (val escaped = raw[index++]) {
          '"' -> builder.append('"')
          '\\' -> builder.append('\\')
          '/' -> builder.append('/')
          'b' -> builder.append('\b')
          'f' -> builder.append('\u000C')
          'n' -> builder.append('\n')
          'r' -> builder.append('\r')
          't' -> builder.append('\t')
          'u' -> {
            if (index + 4 > raw.length) {
              throw error("unicode 转义长度不足")
            }
            val hex = raw.substring(index, index + 4)
            builder.append(hex.toInt(16).toChar())
            index += 4
          }

          else -> throw error("不支持的字符串转义")
        }
      }
      throw error("字符串未闭合")
    }

    private fun parseNumber(): Any {
      val start = index
      if (peek('-')) {
        index += 1
      }
      while (index < raw.length && raw[index].isDigit()) {
        index += 1
      }
      var decimal = false
      if (peek('.')) {
        decimal = true
        index += 1
        while (index < raw.length && raw[index].isDigit()) {
          index += 1
        }
      }
      if (index < raw.length && (raw[index] == 'e' || raw[index] == 'E')) {
        decimal = true
        index += 1
        if (index < raw.length && (raw[index] == '+' || raw[index] == '-')) {
          index += 1
        }
        while (index < raw.length && raw[index].isDigit()) {
          index += 1
        }
      }
      val number = raw.substring(start, index)
      return if (decimal) number.toDouble() else number.toLong()
    }

    private fun parseLiteral(literal: String, value: Any?): Any? {
      if (!raw.startsWith(literal, index)) {
        throw error("JSON 字面量不合法")
      }
      index += literal.length
      return value
    }

    private fun expect(expected: Char) {
      skipWhitespace()
      if (index >= raw.length || raw[index] != expected) {
        throw error("期望字符 $expected")
      }
      index += 1
    }

    private fun peek(expected: Char): Boolean = index < raw.length && raw[index] == expected

    private fun skipWhitespace() {
      while (index < raw.length && raw[index].isWhitespace()) {
        index += 1
      }
    }

    private fun error(message: String): IllegalArgumentException {
      return IllegalArgumentException("$message，位置=$index")
    }
  }
}
