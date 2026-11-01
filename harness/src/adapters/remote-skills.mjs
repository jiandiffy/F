import path from 'node:path';
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";

/** Minimal filesystem seam required by DSH's skill provider, over the authenticated SSH world. */
export function remoteSkillFileSystem(remote, run) {
  return {
    async resolve(input) { return { displayPath: path.posix.resolve(remote.cwd, input) }; },
    processPath(target) { return target.displayPath; },
    async stat(target, signal) {
      const p=quote(target.displayPath);
      const type=(await run(`if [ -d ${p} ]; then printf directory; elif [ -f ${p} ]; then printf file; elif [ -e ${p} ]; then printf other; fi`,signal)).toString();
      return type ? { type } : undefined;
    },
    async listDir(target) {
      const p=quote(target.displayPath);
      const data=await run(`if [ ! -d ${p} ]; then printf '\\0F_NOT_DIRECTORY\\0'; exit; fi; cd ${p} || exit 1; for p in .[!.]* ..?* *; do [ -e "$p" ] || [ -L "$p" ] || continue; if [ -d "$p" ]; then k=directory; elif [ -f "$p" ]; then k=file; else k=other; fi; printf '%s\\0%s\\0' "$p" "$k"; done`);
      const fields=data.toString().split('\0');
      if(fields[0]==='' && fields[1]==='F_NOT_DIRECTORY') throw Object.assign(new Error('Remote skill directory is missing'),{code:'FS_NOT_FOUND'});
      const entries=[];
      for(let i=0;i<fields.length-1;i+=2) entries.push({name:fields[i],type:fields[i+1],target:{displayPath:path.posix.join(target.displayPath,fields[i])}});
      return entries;
    },
    async readText(target, signal) {
      const data=await run(`cat < ${quote(target.displayPath)}`,signal);
      try { return new TextDecoder('utf-8',{fatal:true}).decode(data); }
      catch(error) { throw Object.assign(new Error('Remote skill is not UTF-8 text',{cause:error}),{code:'FS_NOT_TEXT'}); }
    },
  };
}
