---
name: office-xlsx
description: 创建与修改 XLSX 工作簿、公式及图表。
---

以下工具路径相对于本技能目录，输入与输出使用目标项目的绝对路径。

用 ../../runtime/office/.venv/bin/python 的 openpyxl.load_workbook 读取现有文件。避免破坏公式和既有工作表；按明确单元格范围更新值、格式、验证、表和图表。保存后重新打开，核对工作表、范围和公式。需要计算结果时加载 office-recalculate，不把未计算的缓存值当作结果。
