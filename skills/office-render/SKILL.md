---
name: office-render
description: 将 Office 文件渲染为 PDF 和逐页图片进行检查。
---

以下工具路径相对于本技能目录，输入与输出使用目标项目的绝对路径。

运行 ../../runtime/office/.venv/bin/python ../../runtime/office/office.py render <文件> --output <临时目录>。工具查找 LibreOffice 和 pdftoppm，失败时保留诊断并报告缺失依赖。查看每页 PNG，修复裁切、重叠、表格越界和空白页后重渲染。
