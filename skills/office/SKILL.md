---
name: office
description: 创建、编辑、渲染和导出 Word、PowerPoint 与 Excel 文件。
---

以下工具路径相对于本技能目录，输入与输出使用目标项目的绝对路径。

先确认格式、目标路径及是否沿用现有文件。按格式加载 office-docx、office-pptx 或 office-xlsx。使用 ../../runtime/office/.venv/bin/python 的 python-docx、python-pptx、openpyxl 库。渲染后检查分页、溢出、字体与图表，再交付。公式使用 office-recalculate，PDF 使用 office-export-pdf。不得把仅改扩展名的文件当作格式转换。
