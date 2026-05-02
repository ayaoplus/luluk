#!/usr/bin/env bash
# generate_icons.sh
#
# 从单张高分辨率 PNG 生成 macOS 应用图标全套尺寸 + .icns
# 用 macOS 自带的 sips 和 iconutil（无外部依赖）
#
# 用法：
#   ./scripts/generate_icons.sh assets/logo.png
#
# 输出：
#   assets/AppIcon.iconset/        全套 PNG（16/32/64/128/256/512/1024 + @2x）
#   assets/AppIcon.icns            macOS 应用图标包
#
# Xcode 集成：
#   把 assets/AppIcon.iconset 里的 png 文件拖入 iina/Assets.xcassets/AppIcon.appiconset/
#   或直接把 AppIcon.icns 替换 IINA 原图标

set -euo pipefail

INPUT="${1:-assets/logo.png}"
OUTDIR="$(dirname "$INPUT")/AppIcon.iconset"
ICNS="$(dirname "$INPUT")/AppIcon.icns"

if [[ ! -f "$INPUT" ]]; then
    echo "❌ 输入文件不存在: $INPUT"
    echo "用法: $0 path/to/logo.png"
    exit 1
fi

# 检查输入图片至少 1024x1024（macOS 图标最大尺寸）
DIMS=$(sips -g pixelWidth -g pixelHeight "$INPUT" | awk '/pixel/ {print $2}' | tr '\n' 'x' | sed 's/x$//')
W=$(echo "$DIMS" | cut -dx -f1)
H=$(echo "$DIMS" | cut -dx -f2)
SHORT=$((W < H ? W : H))
if (( SHORT < 1024 )); then
    echo "⚠️  输入图片 ${W}x${H}，建议至少 1024x1024 以保证图标清晰"
    echo "    继续会从小图放大，质量会损失"
    read -p "    继续？(y/N) " yn
    [[ "$yn" =~ ^[Yy]$ ]] || exit 1
fi

mkdir -p "$OUTDIR"

# Apple 标准 App 图标尺寸表
# https://developer.apple.com/design/human-interface-guidelines/app-icons
declare -a SIZES=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)

echo "🎨 从 $INPUT 生成图标..."
for entry in "${SIZES[@]}"; do
    SIZE="${entry%%:*}"
    NAME="${entry##*:}"
    OUT="$OUTDIR/$NAME"
    sips -z "$SIZE" "$SIZE" "$INPUT" --out "$OUT" >/dev/null
    echo "  ✓ ${SIZE}x${SIZE} → $NAME"
done

echo ""
echo "📦 打包成 .icns..."
iconutil -c icns "$OUTDIR" -o "$ICNS"
echo "  ✓ $ICNS ($(du -h "$ICNS" | cut -f1))"

echo ""
echo "✅ 完成！"
echo ""
echo "下一步："
echo "  1. 打开 Xcode → iina/Assets.xcassets/AppIcon.appiconset"
echo "  2. 删除 IINA 原图标全套尺寸"
echo "  3. 拖入 $OUTDIR 里的 PNG 到对应槽位"
echo "  4. 或者直接把 $ICNS 拖去替换"
