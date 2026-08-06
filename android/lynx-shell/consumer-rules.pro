# 手写 Native Module 由 Lynx Runtime 按注册信息创建，业务开启 R8 时必须保留。
-keep class com.example.lynxshell.bridge.** { *; }

# XElementBehaviors 通过反射查找注解处理器生成的 BehaviorGenerator。
-keep class com.lynx.xelement.BehaviorGenerator { *; }
-keep class com.lynx.xelement.svg.BehaviorGenerator { *; }
