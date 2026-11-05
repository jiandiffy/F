---
name: office-recalculate
description: 重新计算 XLSX 公式并保留计算后的工作簿。
---

以下工具路径相对于本技能目录，输入与输出使用目标项目的绝对路径。

运行 ../../runtime/office/.venv/bin/python ../../runtime/office/office.py recalculate <文件> --output <新目录>。工具用独立 LibreOffice 配置转换为 XLSX，再以 openpyxl 检查缓存结果中的错误值。确认输出路径和原件不同，核对关键单元格后交付。
