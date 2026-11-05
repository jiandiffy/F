---
name: office-docx
description: 创建与修改 DOCX，并保留原文档内容和格式。
---

以下工具路径相对于本技能目录，输入与输出使用目标项目的绝对路径。

读取文档段落、表格、页眉页脚及样式。用 ../../runtime/office/.venv/bin/python 的 docx.Document 载入原件或新建，使用样式和段落控制分页。图片设置实际尺寸。保存到用户指定位置，重新打开核对段落和表格；用 office-render 检查每页。
