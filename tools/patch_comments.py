# -*- coding: utf-8 -*-
"""按行号替换 .m 文件中的注释行, 严格保留 CRLF 行尾与原缩进。

安全约束(任一不满足即整体中止, 不写任何文件):
  1. 目标行在替换前必须是整行注释(去掉首部空白后以 % 开头);
  2. 新内容必须同样是整行注释;
  3. 新内容不得含 CR/LF;
  4. 行号必须在文件范围内。

这样可以保证永远不会碰到代码、error 消息字符串或标识符。
"""
import os


def _is_comment_line(text):
    return text.lstrip().startswith('%')


def apply_patch(patch, repo_root=None):
    """patch: {相对路径: {行号(int): 新注释文本}}"""
    if repo_root is None:
        repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    staged = {}
    total = 0

    # 第一遍: 全部校验, 任何一处不合法就整体中止, 不落盘
    for rel_path, edits in patch.items():
        abs_path = os.path.join(repo_root, rel_path)
        with open(abs_path, 'rb') as fh:
            raw = fh.read()
        newline = b'\r\n' if b'\r\n' in raw else b'\n'
        lines = raw.split(newline)

        for lineno, new_text in edits.items():
            idx = int(lineno) - 1
            if idx < 0 or idx >= len(lines):
                raise SystemExit('行号越界: %s:%s' % (rel_path, lineno))
            old_text = lines[idx].decode('utf-8')
            if not _is_comment_line(old_text):
                raise SystemExit('目标不是整行注释: %s:%s -> %r'
                                 % (rel_path, lineno, old_text))
            if not _is_comment_line(new_text):
                raise SystemExit('新内容不是整行注释: %s:%s -> %r'
                                 % (rel_path, lineno, new_text))
            if '\r' in new_text or '\n' in new_text:
                raise SystemExit('新内容含换行: %s:%s' % (rel_path, lineno))
            lines[idx] = new_text.encode('utf-8')
            total += 1

        staged[abs_path] = newline.join(lines)

    # 第二遍: 全部通过后才落盘
    for abs_path, content in staged.items():
        with open(abs_path, 'wb') as fh:
            fh.write(content)

    print('已替换 %d 行注释, 涉及 %d 个文件' % (total, len(staged)))
    return total
