# บอก R8 ว่าไม่ต้องแจ้งเตือนถ้าหาคลาสภาษาจีน/ญี่ปุ่น/เกาหลีไม่เจอ 
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# ป้องกันไม่ให้ลบคลาสสำคัญของ ML Kit ออกโดยไม่ตั้งใจ
-keep class com.google.mlkit.vision.text.** { *; }
-keep class com.google.mlkit.common.** { *; }