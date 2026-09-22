# Lynx 通过反射创建 NativeModule；仅 Debug Module 的消费者需要保留该入口。
-keep public class com.example.lynxshell.debug.LynxDebugModule { *; }
