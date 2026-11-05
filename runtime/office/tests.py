from pathlib import Path
from docx import Document
from pptx import Presentation
from pptx.util import Inches
from openpyxl import Workbook, load_workbook
from pypdf import PdfReader
import tempfile, subprocess, sys, json
out=Path(tempfile.mkdtemp(prefix='f-office-acceptance-'))
doc=Document();doc.add_heading('F office verification',0);doc.add_paragraph('Preserve real document content.');doc.add_table(rows=2,cols=2).cell(0,0).text='table';doc.save(out/'document.docx')
ppt=Presentation();slide=ppt.slides.add_slide(ppt.slide_layouts[5]);slide.shapes.title.text='F slide verification';slide.shapes.add_textbox(Inches(1),Inches(2),Inches(6),Inches(1)).text='Editable slide content';ppt.save(out/'slides.pptx')
book=Workbook();sheet=book.active;sheet['A1']=3;sheet['A2']=4;sheet['A3']='=SUM(A1:A2)';book.save(out/'workbook.xlsx')
script=Path(__file__).resolve().with_name('office.py')
for name in ['document.docx','slides.pptx','workbook.xlsx']:
 subprocess.run([sys.executable,str(script),'render',str(out/name),'--output',str(out/name.split('.')[0])],check=True)
 pdf=out/name.split('.')[0]/(Path(name).stem+'.pdf');assert len(PdfReader(pdf).pages)>0;assert list(pdf.parent.glob('*.png'))
subprocess.run([sys.executable,str(script),'recalculate',str(out/'workbook.xlsx'),'--output',str(out/'calculated')],check=True)
assert load_workbook(out/'calculated/workbook.xlsx',data_only=True).active['A3'].value==7
report={'passed':True,'directory':str(out),'cases':['docx create/reopen/render/pdf','pptx create/reopen/render/pdf','xlsx create/formula/recalculate/render/pdf']};(out/'report.json').write_text(json.dumps(report));print(json.dumps(report))
