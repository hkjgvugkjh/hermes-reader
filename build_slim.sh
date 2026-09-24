#!/bin/bash
# 精简编译脚本：排除 TTS/sano 模型资源（~84MB），减小 APK 体积便于远程传输
# 用法: ./build_slim.sh [install|install-local]
#   install:      传输到 Mac (10.10.164.90) 并安装到设备
#   install-local: 直接安装到本机连接的设备（需 adb 可用）

set -e

cd "$(dirname "$0")"

echo "=== [1/5] 备份并修改 pubspec.yaml，排除模型资源 ==="
cp pubspec.yaml pubspec.yaml.bak
sed -i 's|^    - assets/tts/|    # SLIM_BUILD: - assets/tts/|' pubspec.yaml
sed -i 's|^    - assets/sano/|    # SLIM_BUILD: - assets/sano/|' pubspec.yaml

echo "=== [2/5] 清除构建缓存 ==="
rm -rf build

echo "=== [3/5] 构建精简版 APK ==="
flutter build apk --debug 2>&1 | tail -5

APK="build/app/outputs/flutter-apk/app-debug.apk"
SIZE=$(du -h "$APK" | cut -f1)
echo "=== [4/5] 构建完成: $APK ($SIZE) ==="

echo "=== [5/5] 恢复 pubspec.yaml ==="
mv pubspec.yaml.bak pubspec.yaml

if [ "$1" = "install" ]; then
    echo "=== 传输到 Mac (10.10.164.90) ==="
    ssh tomac@10.10.164.90 "rm -f /tmp/app-debug.apk"
    cat "$APK" | ssh tomac@10.10.164.90 "cat > /tmp/app-debug.apk"
    echo "=== 安装到设备 ==="
    ssh tomac@10.10.164.90 "/Users/tomac/Library/Android/sdk/platform-tools/adb install -r /tmp/app-debug.apk"
elif [ "$1" = "install-local" ]; then
    echo "=== 安装到本机设备 ==="
    if ! command -v adb &> /dev/null; then
        echo "错误: adb 未找到，请确保 Android SDK 已安装并在 PATH 中"
        exit 1
    fi
    DEVICES=$(adb devices | grep -w "device$" | wc -l)
    if [ "$DEVICES" -eq 0 ]; then
        echo "错误: 未检测到已连接的设备"
        exit 1
    fi
    adb install -r "$APK"
fi

echo "=== 完成 ==="
