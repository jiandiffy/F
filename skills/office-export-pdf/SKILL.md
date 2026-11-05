---
name: office-export-pdf
description: 将 DOCX、PPTX 或 XLSX 导出为可阅读的 PDF。
---

以下工具路径相对于本技能目录，输入与输出使用目标项目的绝对路径。

运行 ../../runtime/office/.venv/bin/python ../../runtime/office/office.py pdf <文件> --output <目录>。使用独立 LibreOffice 配置，不覆盖源文件。用 pypdf 核对页数并提取文本，再使用 office-render 检查全部页面。依赖不可用时报告原因，不提供空白替代文件。
