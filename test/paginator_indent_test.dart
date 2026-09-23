import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_reader/reader/services/text_break_utils.dart';

/// 回归：justify + 换行布局下，段首全角空格缩进必须可见（非零宽、
/// 正文从 ~2em 处开始）。
///
/// 背景：SkParagraph 在 `TextAlign.justify` 且文本换行时会把每行行首空白
/// （U+3000/NBSP/EM SPACE 等一切 White_Space=Yes 字符）折叠成零宽，段首
/// 缩进因此在真机上完全消失。修复是把行首 U+3000 等长替换为 U+3164。
void main() {
  const style = TextStyle(fontSize: 17.0, height: 1.0, color: Colors.black);

  ({double left, double width, double height}) measure(String text) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: TextAlign.justify,
      textDirection: TextDirection.ltr,
      textHeightBehavior: const TextHeightBehavior(
        applyHeightToFirstAscent: true,
        applyHeightToLastDescent: true,
      ),
      textScaler: TextScaler.linear(1.0),
    )..layout(maxWidth: 305.6);
    final b = tp.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: 1)).first.toRect();
    return (left: b.left, width: b.right - b.left, height: tp.height);
  }

  test('untranslation collapses leading U+3000 under justify wrap (baseline)', () {
    final m = measure('　　小说是写给人看的。小说的内容是人。');
    expect(m.width, 0.0, reason: '基线：未修复时行首 U+3000 被 justify 折叠成零宽');
  });

  test('uncollapsed indent keeps 1em width and shifts body to 2em', () {
    final fixed = uncollapseLeadingIndents('　　小说是写给人看的。小说的内容是人。');
    final m = measure(fixed);
    expect(m.width, closeTo(17.0, 0.5), reason: 'U+3164 占位宽度应为 1em(17px)');
    final b2 = measure(fixed);
    expect(b2.left, 0.0);
  });

  test('replacement is 1:1 length-preserving and idempotent', () {
    const src = '简介：\n　　大周皇子　行首之后的全角空格不动。\n　　第二段';
    final out = uncollapseLeadingIndents(src);
    expect(out.length, src.length, reason: '等长替换，偏移系不变');
    expect(uncollapseLeadingIndents(out), out, reason: '幂等');

    // 只有行首（文本开头 / \n 后）的 U+3000 被替换
    final line2 = out.split('\n')[1];
    expect(line2.startsWith('\u3164\u3164'), isTrue, reason: '第二段行首替换');
    expect(out.split('\n')[2].startsWith('\u3164\u3164'), isTrue, reason: '第三段行首替换');
    expect(line2.contains('\u3000'), isTrue, reason: '行中的全角空格不受影响');
    expect(out.contains('　　大周皇子'), isFalse);
    expect(out.contains('大周皇子　行首之后'), isTrue);
  });

  test('no-op text passes through unchanged', () {
    const plain = '没有任何全角空格的普通文本。\n第二行';
    expect(uncollapseLeadingIndents(plain), same(plain));
  });

  test('visual: indent renders ~2em before body under justify wrap', () {
    // 渲染等价性：第 3 个字符（正文首字）的 x 应 ≈ 2em
    final fixed = uncollapseLeadingIndents('　　小说是写给人看的。小说的内容是人。');
    final tp = TextPainter(
      text: TextSpan(text: fixed, style: style),
      textAlign: TextAlign.justify,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.linear(1.0),
    )..layout(maxWidth: 305.6);
    final body = tp.getBoxesForSelection(const TextSelection(baseOffset: 2, extentOffset: 3)).first.toRect();
    expect(body.left, closeTo(34.0, 1.0), reason: '正文首字应从 2em(34px) 处开始');
  });
}
