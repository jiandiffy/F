"""Create isolated cbc/cbi instances of the pinned upstream pi-codebuddy-sdk."""
from pathlib import Path
import shutil, json
import runpy
patch_tool_replay=runpy.run_path(str(Path(__file__).with_name('patch-codebuddy-tool-replay.py')))['patch']
root=Path(__file__).resolve().parents[1]
source=root/'node_modules/pi-codebuddy-sdk'
if not (source/'src/index.ts').exists():
 raise SystemExit('请先按照 package-lock.json 安装 pi-codebuddy-sdk，再重建提供方。')
for region,environment in [('cbc','internal'),('cbi','public')]:
 product=json.loads((root/'node_modules/@tencent-ai/codebuddy-code/product.json').read_text())
 if region=='cbc':
  def merge(base, overlay):
   for key,value in overlay.items():
    if isinstance(value,dict) and isinstance(base.get(key),dict): merge(base[key],value)
    else: base[key]=value
  merge(product,json.loads((root/'node_modules/@tencent-ai/codebuddy-code/product.internal.json').read_text()))
 product['authentication']['id']='fy-pi-'+region
 product_path=root/'codebuddy'/region/'product.json'
 product_path.parent.mkdir(parents=True,exist_ok=True)
 product_path.write_text(json.dumps(product,indent=2)+'\n')
 product_path.chmod(0o600)
 dest=root/'vendor'/('pi-codebuddy-sdk-'+region)
 if dest.exists(): shutil.rmtree(dest)
 shutil.copytree(source/'src',dest/'src')
 shutil.copy2(source/'LICENSE',dest/'LICENSE')
 for path in (dest/'src').glob('*.ts'):
  text=path.read_text()
  text=text.replace('"codebuddy-sdk"',f'"codebuddy-sdk-{region}"')
  text=text.replace('Symbol.for("codebuddy-sdk:',f'Symbol.for("codebuddy-sdk-{region}:')
  text=text.replace('join(homedir(), ".pi", "agent",', 'join(process.env.PI_CODING_AGENT_DIR!,')
  text=text.replace('codebuddy-sdk-models.json',f'codebuddy-sdk-{region}-models.json')
  text=text.replace('codebuddy-sdk-learned-windows.json',f'codebuddy-sdk-{region}-learned-windows.json')
  text=text.replace('codebuddy-sdk.log',f'codebuddy-sdk-{region}.log')
  text=text.replace('codebuddy-sdk-diag.log',f'codebuddy-sdk-{region}-diag.log')
  if path.name=='convert.ts': text=text.replace('PROVIDER_ID = "codebuddy"',f'PROVIDER_ID = "{region}"')
  if path.name=='index.ts':
   text=text.replace('PROVIDER_NAME = "CodeBuddy"',f'PROVIDER_NAME = "{region}"')
  if path.name=='config.ts':
   text='import network from '+repr(str(root/'scripts/network.cjs'))+';\n'+text
   start=text.index('export function loadConfig(cwd: string): Config {')
   text=text[:start]+f'''export function loadConfig(cwd: string): Config {{
 return {{
  askCodebuddy: {{ enabled: false }},
  provider: {{
   appendSystemPrompt: true, strictMcpConfig: true,
   executable: {str(root/'runtime/node/bin/node')!r},
   pathToCodebuddyCode: {str(root/'node_modules/@tencent-ai/codebuddy-code/bin/codebuddy')!r},
   isolatedEnv: true,
   codebuddyConfigDir: {str(root/'codebuddy'/region)!r},
  }}
 }};
}}
'''
   text=text.replace('const env = { ...base, DISABLE_AUTO_COMPACT: "1" };',f'''const env = {{ ...network.networkEnv("{region}", base), DISABLE_AUTO_COMPACT: "1", DISABLE_AUTOUPDATER: "1", CODEBUDDY_INTERNET_ENVIRONMENT: "{environment}", ACC_PRODUCT_CONFIG_PATH: "{root}/codebuddy/{region}/product.json" }};
 delete (env as any).CODEBUDDY_API_KEY;
 delete (env as any).CODEBUDDY_BASE_URL;''')
  path.write_text(text)
 patch_tool_replay(dest/'src')
 print('Built',region)
